# Returns Domain Specification

## Purpose

Item-level sale returns with destination routing (inventario, merma, garantia, desecho), distinct from full-sale cancellation. Owns `returns` / `return_items` / `return_item_batches` tables, the `return_sale_item_transaction()` RPC, and the admin-only `return-sale-item` Edge Function. Reverses inventory per destination and writes a cash reversal movement for cash-paid portions, all atomically.

## Requirements

### Requirement: RR1 — Returns Schema

The system MUST define three tables in migration 00011: `returns` (header), `return_items` (line items), `return_item_batches` (lot traceability).

| Table | Required Columns |
|-------|------------------|
| `returns` | `id` (UUID PK), `company_id`, `branch_id`, `sale_id` (FK→sales), `type` CHECK `IN ('total','partial')`, `status` CHECK `IN ('pending','approved','completed','rejected')`, `total_amount` NUMERIC(12,2), `reason` TEXT, `authorized_by` UUID, logical deletion (`is_active`,`deleted_at`,`deleted_by`), audit (`created_at`,`updated_at`,`created_by`,`updated_by`). Unique `(company_id, id)`. |
| `return_items` | `id`, `company_id`, `return_id` (composite FK→returns), `sale_item_id` (FK→sale_items), `variant_id`, `qty` NUMERIC(12,3) >0, `destination` CHECK `IN ('inventario','merma','garantia','desecho')`, `unit_price` NUMERIC(12,2), `subtotal` NUMERIC(12,2). |
| `return_item_batches` | `id`, `company_id`, `return_item_id` (composite FK→return_items), `original_batch_id` (FK→sale_item_batches), `variant_id`, `qty` >0. |

RLS MUST be enabled on all three. Physical DELETE prohibited.

- GIVEN admin inserts a return → THEN `returns` row with `status='pending'|'approved'` and `type` matching items is created
- GIVEN any actor attempts physical DELETE → THEN rejected (logical deletion only)

### Requirement: RR2 — Return Creation RPC

The system MUST provide `return_sale_item_transaction()` SECURITY DEFINER RPC (`SET search_path=public`, REVOKE ALL FROM PUBLIC+anon, GRANT EXECUTE TO authenticated) that atomically: (1) creates `returns` header + `return_items` + `return_item_batches`, (2) reverses inventory per destination, (3) creates cash reversal movement for cash-paid portions.

The RPC MUST validate: sale exists and `status != 'cancelled'`; per item `qty <= sale_item.qty - SUM(previously returned qty for that sale_item)`; each `return_item_batches.original_batch_id` exists in `sale_item_batches` for that sale_item and matches `variant_id`; if any destination refunds cash, an open cash session exists for the branch.

- GIVEN valid partial return, qty=2, sold=5, none previously returned → WHEN RPC invoked by admin → THEN 1 return header + items + batches created, inventory reversed, transaction commits
- GIVEN qty=3 but sold=5 and previously-returned=3 → WHEN RPC invoked → THEN rejected (returnable remaining = 2), no rows written
- GIVEN `original_batch_id` not in `sale_item_batches` for that sale_item → WHEN RPC invoked → THEN rejected before any write
- GIVEN sale `status='cancelled'` → WHEN RPC invoked → THEN rejected
- GIVEN any validation fails mid-transaction → THEN full rollback, no partial state

### Requirement: RR3 — Destination Routing

The system MUST route each `return_item.destination` to the correct inventory operation.

| Destination | Operation |
|-------------|-----------|
| `inventario` | Restock original lot via `adjust_inventory_stock()` (positive `sale_return` movement per lot) |
| `merma` | Single negative `stock_movements` row, `movement_type='waste_return'` (no intermediate restock) |
| `garantia` | Single negative `stock_movements` row, `movement_type='warranty_return'` |
| `desecho` | Single negative `stock_movements` row, `movement_type='disposal_return'` |

Non-inventario destinations MUST NOT create intermediate positive restock rows.

- GIVEN destination='inventario', 2 units from Lot A → WHEN RPC → THEN Lot A `remaining_qty` +2 via `adjust_inventory_stock`, single `sale_return` movement
- GIVEN destination='merma', 3 units → WHEN RPC → THEN exactly one `stock_movements` row `movement_type='waste_return'`, `delta_qty=-3`, no lot restock
- GIVEN destination='garantia' → WHEN RPC → THEN one `warranty_return` negative movement
- GIVEN destination='desecho' → WHEN RPC → THEN one `disposal_return` negative movement

### Requirement: RR4 — Cash Reversal

When the sale had cash payments, the RPC MUST append a `cash_movements` row with `movement_type='sale_return_refund'`, amount = cash-paid portion of returned subtotal (NOT credit portion). The movement MUST reference the open cash session for the branch and `reference_type='return'`, `reference_id=<return id>`. If no cash was paid, no cash movement is created. The refund MUST NOT reduce credit balances in V1 (deferred to V1.5).

- GIVEN sale paid fully in cash, return subtotal=100 → WHEN RPC → THEN one `sale_return_refund` cash_movement amount=100 against open session
- GIVEN sale paid fully on credit → WHEN RPC → THEN no `cash_movements` row created
- GIVEN sale paid 60 cash + 40 credit, return subtotal=50 → WHEN RPC THEN refund=50 only if 50<=cash-paid; otherwise refund limited to cash-paid portion (V1: no mixed-payment proportional logic — refund cash portion only, reject if exceeds cash paid)
- GIVEN no open cash session for branch → WHEN cash refund required → THEN RPC rejected before any write

### Requirement: RR5 — Authorization and RLS

All writes (INSERT/UPDATE) on `returns`, `return_items`, `return_item_batches` MUST be admin-only via `is_admin` policy. SELECT MUST be company/branch-scoped for all authenticated users. No DELETE policy SHALL exist (logical deletion only).

- GIVEN admin → WHEN INSERT → THEN allowed through SECURITY DEFINER RPC; direct authenticated INSERT → rejected
- GIVEN cashier in branch B1 → WHEN SELECT returns → THEN only own-company, own-branch rows returned
- GIVEN admin in company A → WHEN SELECT → THEN all company A rows across branches; company B rows invisible
- GIVEN any authenticated user → WHEN DELETE → THEN rejected (no DELETE policy)

### Requirement: RR6 — return-sale-item Edge Function

The `return-sale-item` Edge Function MUST follow the 8-step critical-op pattern (project-architecture R2): validate user → company → branch → role (admin-only) → input (Zod schema) → invoke `return_sale_item_transaction()` RPC → audit → return `EFResult`. Non-admin callers MUST receive `FORBIDDEN`. The EF MUST NOT call operational tables directly.

- GIVEN admin with valid token, company, branch, Zod-valid input → WHEN EF invoked → THEN RPC called, `EFResult` returned with return id
- GIVEN cashier (non-admin) → WHEN EF invoked → THEN `FORBIDDEN` returned, no RPC call
- GIVEN invalid Zod input → WHEN EF invoked → THEN validation error before RPC

### Requirement: RR7 — CHECK Constraint Extensions

Migration 00011 MUST extend CHECK constraints additively (no existing values removed):
- `stock_movements.movement_type` adds `waste_return`, `warranty_return`, `disposal_return`
- `cash_movements.movement_type` adds `sale_return_refund`

Extensions MUST be additive-only to avoid blocking concurrent writes on existing tables.

- GIVEN migration 00011 applied → THEN `stock_movements.movement_type` accepts the 3 new values; all existing types still accepted
- GIVEN migration 00011 applied → THEN `cash_movements.movement_type` accepts `sale_return_refund`; existing types unaffected

### Requirement: RR8 — Test Coverage

The change MUST include pgTAP tests: schema/constraints (CHECK extensions, FKs, unique), RPC atomicity (rollback on failure), destination routing (one movement per non-inventario destination; restock via adjust for inventario), cash reversal (cash-only, credit-skips, open-session-required), RLS isolation (company/branch, admin-only writes, no DELETE).

`Deno.test` MUST cover the EF 8-step flow: auth validation, Zod schema, non-admin rejection, successful RPC invocation, `EFResult` shape.

- GIVEN `supabase test db` → THEN all returns-domain pgTAP pass (schema, atomicity, routing, cash, RLS)
- GIVEN `deno test` → THEN all `return-sale-item` EF tests pass (8-step, rejects, success)

## Non-Goals

- Credit balance reduction on partial credit returns (V1.5)
- Mixed-payment proportional refund logic (V1.5)
- Multi-step approval workflow beyond admin-only (V1)
- Customer-facing return API (V1 admin-only)
- Refund method selection (cash back vs store credit vs card)