# Inventory Domain Specification

## Purpose

Lot-based inventory for multi-tenant POS. Movement-only mutations; FEFO for perishables; branch-scoped.

## Requirements

### RI1: Movement-Only Mutations

Stock quantities MUST NOT be edited directly. Every stock change MUST produce a `stock_movements` row. Direct UPDATE on `stock_lots.remaining_qty` outside SECURITY DEFINER RPCs is PROHIBITED.

- GIVEN any stock change → WHEN committed → THEN `stock_movements` row with matching delta exists
- GIVEN any role → WHEN attempting direct UPDATE on `stock_lots.remaining_qty` → THEN blocked

### RI2: Stock Lots

`stock_lots` tracks per-batch inventory: variant, branch, lot_code, expiration_date, received_qty, remaining_qty, cost_per_unit, status (`active`|`expired`|`depleted`). `remaining_qty` is denormalized cache updated atomically within RPCs. Unique: `(company_id, branch_id, variant_id, lot_code)`. Composite FKs following catalog pattern.

- GIVEN receipt of 50 units → WHEN `receive_purchase_lot` RPC called → THEN lot created, `received_qty=50`, `remaining_qty=50`, `status=active`
- GIVEN lot `remaining_qty=0` → WHEN movement RPC processes → THEN `status=depleted`

### RI3: Stock Movements Append-Only

`stock_movements` is append-only: no UPDATE, no DELETE. V1 types: `purchase_receipt`, `sale`, `sale_return`, `adjustment_increase`, `adjustment_decrease`, `waste`, `expiration`. V1.5 stubs: `transfer_in`, `transfer_out`. `delta_qty` positive for increases, negative for decreases. `created_by` NOT NULL.

- GIVEN movement recorded → THEN `delta_qty` sign matches type direction, `created_by` populated
- GIVEN existing movement → WHEN UPDATE or DELETE → THEN rejected

### RI4: FEFO Deduction

`record_sale_deduction` MUST select lots by FEFO order (earliest `expiration_date` first; NULL last) and deduct atomically in one transaction with `SELECT FOR UPDATE` per lot. If quantity exceeds one lot, the RPC MUST span multiple lots.

- GIVEN 15 units requested, Lot A (expires sooner) has 10, Lot B has 20 → WHEN deduction → THEN 10 from A, 5 from B; two movement rows atomically
- GIVEN no available stock → WHEN deduction attempted → THEN rejected, no partial deduction

### RI5: Lot Code Auto-Generation

`lot_code` nullable. When omitted, RPC MUST auto-generate as `LOT-{branch_short}-{YYYYMMDD}-{seq}`. Collision retries with new suffix.

- GIVEN receive-purchase without lot_code → WHEN RPC invoked → THEN auto-generated and unique
- GIVEN collision → WHEN retry → THEN new seq suffix until unique

### RI6: Inventory Adjustments

Adjustments target total inventory per variant+branch. Increases: RPC creates adjustment lot (`ADJ-...`). Decreases: RPC resolves lots via FEFO atomically. `reason` NOT NULL.

- GIVEN adjustment_increase of 5 → WHEN RPC invoked → THEN adjustment lot created, movement with reason recorded
- GIVEN adjustment_decrease of 8 → WHEN RPC invoked → THEN FEFO lots deducted; `reason` NOT NULL

### RI7: Computed Stock Views

`v_stock_available`: `physical_qty = SUM(remaining_qty)` of active lots per (variant, branch). `v_stock_expiring`: active lots by `expiration_date ASC`. V1 excludes committed/available split (reservations deferred).

- GIVEN 3 active lots (qty 10, 5, 8) → WHEN querying `v_stock_available` → THEN `physical_qty = 23`
- GIVEN lots with expirations → WHEN querying `v_stock_expiring` → THEN earliest-first; NULL last

### RI8: EF/RPC Mutation Boundary

All mutations via EF → SECURITY DEFINER RPC (8-step pattern). Reads MAY use SDK + RLS. RPCs: `SET search_path = public`, REVOKE ALL FROM PUBLIC+anon, GRANT EXECUTE TO authenticated. Admin-only mutations; cashier read-only.

- GIVEN admin → WHEN calling mutation EF → THEN 8-step validated, `EFResult` returned; cashier → `FORBIDDEN`
- GIVEN user → WHEN querying views via SDK → THEN own-company rows only

### RI9: RLS Isolation

All inventory tables: `company_id = get_company_id()` SELECT. Admin reads own-company rows, but base-table mutations remain denied and MUST flow through approved EF/SECURITY DEFINER RPC paths. Cashier: branch-scoped read-only. service_role: ALL bypass. No DELETE policies.

- GIVEN company A user → WHEN querying → THEN only company A rows; authenticated base-table INSERT (including admin and cashier) → rejected; service_role bypass remains allowed

### RI10: V1 Scope Exclusions

`stock_reservations`, reservation RPCs, inter-branch transfers deferred. `transfer_in`/`transfer_out` are enum stubs only; RPC validation MUST reject them in V1.

- GIVEN V1 → WHEN transfer type submitted → THEN rejected: "not supported in V1"; reservation → same

### RI11: Test Specifications

pgTAP: RLS isolation, unique lot_code, CHECK constraints (movement type, non-negative remaining_qty), RPC hardening, FEFO multi-lot. Deno.test: EF auth, EFResult shape, Zod schemas.

- GIVEN `supabase test db` → THEN all pgTAP pass
- GIVEN `deno test` → THEN all EF tests pass
