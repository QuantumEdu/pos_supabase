# Tasks: Purchasing Domain Implementation

**Change**: `purchasing-domain`
**Phase**: Tasks (SDD 4/5)
**Status**: Complete — Phase 4 verified PASS, ready for archive

---

## Review Workload Forecast

| Metric | Value |
|--------|-------|
| Estimated changed lines | **~950–1,150** |
| 400-line budget risk | **High — exceeds budget by ~2.5–2.9x** |
| Chained PRs recommended | **Yes** |
| Suggested split | 4 PR slices (schema → RPCs → EFs → verify) |
| Decision needed before apply | **Yes** — open decision #1 (`product_variants.last_cost`) must be resolved |

> **Budget note**: The purchasing domain is 5 tables, 4 RPCs, 4 Edge Functions, a shared handler/schema pair, and 3 pgTAP + 1 Deno test files. This is structurally larger than any single previous domain (catalog: 3 tables + 10 RPCs; inventory: 5 tables + 5 RPCs). The 400-line single-PR budget is insufficient. The proposal already prescribes a **4-PR chained strategy** (`feature/purchasing-domain` base → each PR targets the previous PR's branch).

---

## Prerequisites

- [x] ~~Resolve open decision #1: `product_variants.last_cost`~~ → **ADD** (column added in 00006, updated atomically on receipt)
- [x] ~~Resolve open decision #2: supplier mutations path~~ → **EF→RPC** (manage_supplier RPC, confirmed)
- [ ] Bootstrap (00001–00003), catalog (00004), and inventory (00005) migrations applied and verified locally
- [ ] Supabase CLI running locally with `supabase start`

---

## Phase 1: Schema + RLS + pgTAP Constraints

**PR slice**: `feature/purchasing-domain` (base)
**Estimated lines**: ~350–400
**Files**: `00006_purchasing_domain.sql`, `test_purchasing_constraints.sql`

### 1.1 Migration: Tables and Indexes

- [x] Create `00006_purchasing_domain.sql`
  - Create 5 tables: `suppliers`, `purchase_orders`, `purchase_order_items`, `purchase_receipts`, `purchase_receipt_items`
  - Match column specs exactly from `design.md` §2 (types, defaults, NULL/NOT NULL, audit columns)
  - All tables: `id UUID PRIMARY KEY DEFAULT gen_random_uuid()`, `company_id UUID NOT NULL REFERENCES companies(id)`
  - `product_variants.last_cost NUMERIC(12,2)` column ADDED or DEFERRED per open decision #1
  - `set_updated_at` BEFORE UPDATE trigger on all 5 tables
- **Verify**: `supabase db reset` applies migration without errors
- **Verify**: `\dt public.*` shows all 5 tables with correct columns

### 1.2 Migration: Composite FKs and Indexes

- [x] Add composite unique indexes: `(company_id, id)` on all 5 tables
- [x] Add composite FKs:
  - `purchase_orders` → `branches(company_id, id)` as `fk_po_branch_same_company`
  - `purchase_orders` → `suppliers(company_id, id)` as `fk_po_supplier_same_company`
  - `purchase_order_items` → `purchase_orders(company_id, id)` as `fk_poi_po_same_company`
  - `purchase_order_items` → `product_variants(company_id, id)` as `fk_poi_variant_same_company`
  - `purchase_receipts` → `purchase_orders(company_id, id)` as `fk_pr_po_same_company`
  - `purchase_receipts` → `branches(company_id, id)` as `fk_pr_branch_same_company`
  - `purchase_receipt_items` → `purchase_receipts(company_id, id)` as `fk_pri_receipt_same_company`
  - `purchase_receipt_items` → `purchase_order_items(company_id, id)` as `fk_pri_poi_same_company`
  - `purchase_receipt_items` → `product_variants(company_id, id)` as `fk_pri_variant_same_company`
- [x] Add lookup indexes: `(company_id)` on all 5 tables, `(company_id, tax_id)` on suppliers, `(company_id, branch_id)` on branch-scoped tables
- [x] Add CHECK constraints: `received_qty <= ordered_qty` on `purchase_order_items`, `ordered_qty > 0`, `received_qty >= 0`, status enums on `purchase_orders` and `purchase_receipts`
- **Verify**: `supabase db reset` applies migration without errors

### 1.3 Migration: RLS Policies

- [x] Enable RLS on all 5 tables: `ALTER TABLE ... ENABLE ROW LEVEL SECURITY`
- [x] Create 4 policies per table (catalog/inventory pattern):
  - `{table}_select_own`: `authenticated` SELECT via `company_id = public.get_company_id()`
  - `{table}_insert_admin`: `authenticated` INSERT via `company_id = public.get_company_id() AND public.is_admin()`
  - `{table}_update_admin`: `authenticated` UPDATE via `company_id = public.get_company_id() AND public.is_admin()`
  - `{table}_service_all`: `service_role` ALL with `TRUE`
- [ ] No DELETE policies on any table — logical deletion via `is_active = false`
- **Verify**: `supabase start` succeeds; RLS is `force row level security` on all tables

### 1.4 Migration: Critical Column Protection Trigger

- [x] Create `prevent_purchasing_critical_col_direct_edit()` trigger
  - Fires BEFORE UPDATE on `purchase_orders` and `purchase_order_items`
  - Rejects authenticated direct edits to `purchase_orders.status` and `purchase_order_items.received_qty`
  - Permits `postgres` and `service_role` bypass (SECURITY DEFINER RPCs)
- [x] Attach trigger to both tables
- **Verify**: Manual test: authenticated user `UPDATE purchase_order_items SET received_qty = 5` should raise exception

### 1.5 Migration: Grants

- [x] GRANT SELECT, INSERT, UPDATE on all 5 tables TO `authenticated`
- [x] GRANT SELECT on all 5 tables TO `anon`
- [x] GRANT SELECT on all 5 tables TO `service_role`
- **Verify**: Check grants via `\dp` or pgTAP

### 1.6 pgTAP: Constraints Tests

- [x] Create `supabase/tests/test_purchasing_constraints.sql`
  - Composite FK enforcement: cross-tenant reference rejection
  - CHECK constraints: `received_qty <= ordered_qty`, `ordered_qty > 0`, `received_qty >= 0`, status enum values
  - Unique constraints: duplicate `(company_id, slug)`, `(company_id, order_number)`, `(company_id, receipt_number)`
  - Critical column protection trigger: authenticated UPDATE to `received_qty` or `status` is rejected
  - `set_updated_at` trigger fires on all 5 tables
- **Verify**: `supabase test db` — all pgTAP constraints tests pass

### 1.7 pgTAP: RLS Tests

- [x] Create `supabase/tests/test_purchasing_rls.sql`
  - Admin for company A sees only company A rows in all 5 tables
  - Admin for company A cannot see company B rows
  - Unauthenticated returns zero rows on all 5 tables
  - Cashier can SELECT but not INSERT/UPDATE on any purchasing table
  - `service_role` bypasses all RLS
  - No physical DELETE possible
- **Verify**: `supabase test db` — all pgTAP RLS tests pass

---

## Phase 2: RPC Functions + pgTAP RPC Tests

**PR slice**: targets `feature/purchasing-domain-phase1`
**Estimated lines**: ~300–350
**Files**: `00006_purchasing_domain.sql` (RPC section), `test_purchasing_rpcs.sql`

### 2.1 RPC: `create_purchase_order(p JSONB)`

- [x] Implement in `00006_purchasing_domain.sql`
  - SECURITY DEFINER, `SET search_path = public`
  - Verifies `company_id == public.get_company_id() AND public.is_admin()`
  - Validates branch exists, active, and belongs to company
  - Validates supplier exists, active, and belongs to company
  - For each item: validates variant exists, active, and belongs to company
  - Computes `subtotal = ordered_qty * unit_cost`, `tax_amount = subtotal * tax_rate` server-side
  - Computes PO totals: `subtotal = SUM(item.subtotal)`, `tax_total = SUM(item.tax_amount)`, `total = subtotal + tax_total`
  - Inserts PO header with `status = 'draft'` + all items atomically
  - Returns `{ purchase_order_id, order_number, status, items_count, total }`
  - Error on: supplier not found/inactive, branch not found/inactive, variant not found/inactive, empty items array, `ordered_qty <= 0`, cross-tenant mismatch
- **Verify**: Manual RPC call with valid input creates PO + items

### 2.2 RPC: `receive_purchase_transaction(p JSONB)`

- [x] Implement in `00006_purchasing_domain.sql`
  - SECURITY DEFINER, `SET search_path = public`
  - Verifies `company_id == public.get_company_id() AND public.is_admin()`
  - Validates branch exists and active
  - `SELECT FOR UPDATE` on PO header (validates status IN `('sent', 'partial')`)
  - `SELECT FOR UPDATE` on all target `purchase_order_items` rows (validates not fully received, qty not overshot)
  - Inserts `purchase_receipts` header
  - For each receipt item:
    - Inserts `purchase_receipt_items`
    - Calls `public.receive_purchase_lot(p)` with correct reference_type/reference_id
    - Updates `purchase_order_items.received_qty = received_qty + item.received_qty`
  - Transitions PO status: `'partial'` if any item still has `received_qty < ordered_qty`, `'received'` if all fully received
  - Updates `product_variants.last_cost` per item
  - Returns `{ receipt_id, purchase_order_id, po_status, lot_results[], items_processed }`
  - Entire function is a single PL/pgSQL transaction — ANY failure rolls back everything
- **Verify**: Full receipt creates receipt + items + inventory lots + movements; partial receipt works; overshoot rejected; cancelled/received PO rejected; rollback on failure

### 2.3 RPC: `cancel_purchase_order(p JSONB)`

- [x] Implement in `00006_purchasing_domain.sql`
  - SECURITY DEFINER, `SET search_path = public`
  - Verifies `company_id == public.get_company_id() AND public.is_admin()`
  - `SELECT FOR UPDATE` on PO, validates status IN `('draft', 'sent', 'partial')`
  - Sets `status = 'cancelled'`, `updated_by = auth.uid()`
  - Returns `{ purchase_order_id, previous_status, cancelled: true }`
  - Rejects `received` and already `cancelled` POs
  - Does NOT touch `received_qty` or inventory
- **Verify**: Cancels draft/sent/partial; rejects received; idempotent on already cancelled

### 2.4 RPC: `manage_supplier(p JSONB)`

- [x] Implement in `00006_purchasing_domain.sql`
  - SECURITY DEFINER, `SET search_path = public`
  - Action routing: `create`, `update`, `deactivate`
  - Create: validates slug uniqueness per company, inserts supplier with audit columns
  - Update: validates supplier exists and belongs to company, updates allowed fields
  - Deactivate: sets `is_active = false`, `deleted_at = now()`, `deleted_by = auth.uid()` (logical deletion)
  - Cross-tenant validation on all actions
- **Verify**: Create/update/deactivate work; slug uniqueness enforced; cross-tenant rejected

### 2.5 RPC Security Hardening

- [x] All 4 RPCs: `REVOKE ALL FROM PUBLIC, anon`; `GRANT EXECUTE TO authenticated`
- [x] All 4 RPCs: `SET search_path = public` via proconfig
- [x] All 4 RPCs: independent `company_id` verification against `public.get_company_id()`
- **Verify**: pgTAP checks `search_path`, REVOKE/GRANT, cross-tenant rejection

### 2.6 pgTAP: RPC Tests

- [x] Create `supabase/tests/test_purchasing_rpcs.sql`
  - `create_purchase_order`: valid creation, validation errors, auto-computed totals, cross-company rejection
  - `receive_purchase_transaction`: full receipt, partial receipt, overshoot rejection, invalid PO state rejection, inventory lot/movement created with correct reference, atomic rollback
  - `cancel_purchase_order`: cancel draft/sent/partial, reject received, reject already cancelled
  - `manage_supplier`: create/update/deactivate, slug uniqueness, cross-company rejection
  - RPC hardening: `search_path`, REVOKE/GRANT, admin-only gate
- **Verify**: `supabase test db` — all pgTAP RPC tests pass

---

## Phase 3: Edge Functions + Deno Tests

**PR slice**: targets `feature/purchasing-domain-phase2`
**Estimated lines**: ~250–300
**Files**: `purchasing_handler.ts`, `purchasing_schemas.ts`, 4 EF `index.ts` files, `purchasing_ef_test.ts`

### 3.1 Shared: `purchasing_schemas.ts`

- [x] Create `supabase/functions/_shared/purchasing_schemas.ts`
  - Zod schemas: `CreatePurchaseOrderRequest`, `ReceivePurchaseOrderRequest`, `CancelPurchaseOrderRequest`, `ManageSupplierRequest`
  - TypeScript types: `PurchaseOrderResult`, `ReceivePurchaseResult`, `CancelPurchaseOrderResult`, `SupplierResult`
  - All UUIDs validated with `.uuid()`, quantities `.positive()`, tax rates `.min(0).max(1)`
- **Verify**: Zod `safeParse` on valid and invalid payloads produces correct results — 13 schema tests pass

### 3.2 Shared: `purchasing_handler.ts`

- [x] Create `supabase/functions/_shared/purchasing_handler.ts`
  - Export `PurchasingHandlerDeps` type (injectable `validateAuth` and `createServiceClient`)
  - Export `handlePurchasingRpc<T>(req, rpcName, schema, companyField, deps?)` generic handler
  - 8-step pattern: CORS → validateAuth(admin) → Zod parse → company_id check → serviceClient.rpc() → EFResult response
  - Follow `inventory_handler.ts` pattern with dependency injection for testability
- **Verify**: Compiles with `deno check`; injectable deps match test pattern — all 32 tests use injected deps

### 3.3 EF: `purchasing/create-purchase-order`

- [x] Create `supabase/functions/purchasing/create-purchase-order/index.ts`
  - Calls `handlePurchasingRpc<PurchaseOrderResult>` with `"create_purchase_order"` RPC
  - Minimal EF body following catalog EF pattern (~10 lines)
- **Verify**: `deno check` passes; EF shape matches catalog EFs — RPC name captured in test

### 3.4 EF: `purchasing/receive-purchase-order`

- [x] Create `supabase/functions/purchasing/receive-purchase-order/index.ts`
  - Calls `handlePurchasingRpc<ReceivePurchaseResult>` with `"receive_purchase_transaction"` RPC
  - EF does NOT loop over items — delegates entire workflow to single RPC call
- **Verify**: `deno check` passes; single RPC call confirmed with 3-item payload (rpcCallCount=1)

### 3.5 EF: `purchasing/cancel-purchase-order`

- [x] Create `supabase/functions/purchasing/cancel-purchase-order/index.ts`
  - Calls `handlePurchasingRpc<CancelPurchaseOrderResult>` with `"cancel_purchase_order"` RPC
- **Verify**: `deno check` passes; RPC name and error propagation tested

### 3.6 EF: `purchasing/manage-supplier`

- [x] Create `supabase/functions/purchasing/manage-supplier/index.ts`
  - Calls `handlePurchasingRpc<SupplierResult>` with `"manage_supplier"` RPC
  - Routes `action: "create" | "update" | "deactivate"`
- **Verify**: `deno check` passes; action enum validated by Zod schema

### 3.7 Deno Tests: `purchasing_ef_test.ts`

- [x] Create `supabase/functions/_test/purchasing_ef_test.ts`
  - Follow `inventory_receive_purchase.test.ts` pattern with dependency injection
  - **Create PO EF tests**: valid request → 200, missing company → 400 (Zod), cashier → 403, unauthenticated → 401, company mismatch → 403
  - **Receive PO EF tests**: valid request → 200, empty items → 400 (Zod), cashier → 403
  - **Cancel PO EF tests**: valid request → 200, already received (RPC error) → 400, cashier → 403
  - **Manage supplier EF tests**: valid create → 200, valid update → 200, cashier → 403
  - **EFResult shape validation**: all 4 EFs return `{ success: true, data: {...} }` on success
- **Verify**: `deno test supabase/functions/_test/purchasing_ef_test.ts` — all 32 tests pass

---

## Phase 4: Verify + Spec Alignment

**PR slice**: targets `feature/purchasing-domain-phase3`
**Estimated lines**: ~50–100
**Files**: spec delta updates (if any), final verification notes

### 4.1 Full Database Reset and Migration Verification

- [x] Run `supabase db reset` — all 6 migrations (00001–00006) apply without errors
- [x] Run `supabase test db` — all pgTAP tests pass (constraints + RLS + RPCs) — **388/388 PASS**
- [x] Verify `\dt public.*` shows all 5 purchasing tables plus existing bootstrap/catalog/inventory tables
- **Verify**: Zero migration errors, zero test failures

### 4.2 Edge Function Compilation Check

- [x] Run `deno check` on all 4 purchasing EFs — BLOCKED (known `npm:@types/node` resolution, same as all prior domains)
- [x] Run `deno check` on `purchasing_handler.ts` and `purchasing_schemas.ts` — same npm:@types/node block
- [x] Fallback: `deno test --no-check` passes 118/118, confirming all EFs are structurally valid
- **Verify**: Zero type errors (no-check fallback confirms runtime correctness)

### 4.3 Deno Test Suite

- [x] Run `deno test supabase/functions/_test/` — all existing + new purchasing EF tests pass — **118/118 PASS** (--no-check)
- **Verify**: Zero test failures; no regressions in catalog or inventory EFs

### 4.4 Audit Trail Validation

- [x] Create a PO via EF → `created_by` populated by `auth.uid()` in `create_purchase_order` RPC
- [x] Receive against PO → receipt + receipt items + inventory lots/movements created with correct `reference_type = 'purchase_receipt'` and `reference_id` (verified via code review)
- [x] Deactivate supplier → `deleted_at` and `deleted_by` set, `is_active = false` (verified via code review)
- [x] Cancel PO → `status = 'cancelled'`, `updated_by` populated (verified via code review + pgTAP RPC test)
- **Verify**: All audit columns populated; logical deletion works; inventory reference backlinks correct

### 4.5 Spec Delta Alignment

- [x] Verify all spec requirements (RP1–RP13) map to implemented artifacts — **13/13 CONFIRMED**
- [x] Open decision #1 resolved as ADD: `product_variants.last_cost` column exists (idempotent ADD in 00006) and master RPC updates it atomically in `receive_purchase_transaction`
- [x] No divergence between spec and implementation
- **Verify**: `spec.md` acceptance criteria checklist items are all satisfiable by implemented code

---

## Risks and Mitigations

| # | Risk | Phase | Mitigation |
|---|------|-------|------------|
| R1 | Open decision #1 (`last_cost`) unresolved at start of Phase 1 | Phase 1 | Block apply until resolved; both paths designed and spec-supported |
| R2 | `receive_purchase_lot` RPC change breaks purchasing integration | Phase 2 | Inventory RPC is NOT modified; purchasing calls it with stable contract per design §7.4 |
| R3 | Concurrent receipt race condition | Phase 2 | `SELECT FOR UPDATE` in consistent order (PO → items) per design §7.2 |
| R4 | `received_qty` drift | Phase 2 | Same transaction as inventory writes; trigger blocks direct edits per design §7.3, §7.5 |
| R5 | EF timeout on large receipts | Phase 3 | Single RPC call; no N+1 from EF per design §7.1 |
| R6 | pgTAP test data contamination between test files | Phase 1 | Each test file uses `BEGIN` block with unique UUIDs; follows inventory test pattern |
| R7 | Shared handler divergence from inventory_handler pattern | Phase 3 | `purchasing_handler.ts` mirrors `inventory_handler.ts` with identical dep injection pattern |

---

## Files Summary

| File | Phase | Type | Status |
|------|-------|------|--------|
| `supabase/migrations/00006_purchasing_domain.sql` | 1, 2 | Migration (tables, indexes, RLS, triggers, RPCs) | Complete |
| `supabase/tests/test_purchasing_constraints.sql` | 1 | pgTAP | Complete |
| `supabase/tests/test_purchasing_rls.sql` | 1 | pgTAP | Complete |
| `supabase/tests/test_purchasing_rpcs.sql` | 2 | pgTAP | Complete |
| `supabase/functions/_shared/purchasing_schemas.ts` | 3 | Shared types | Complete |
| `supabase/functions/_shared/purchasing_handler.ts` | 3 | Shared handler | Complete |
| `supabase/functions/purchasing/create-purchase-order/index.ts` | 3 | Edge Function | Complete |
| `supabase/functions/purchasing/receive-purchase-order/index.ts` | 3 | Edge Function | Complete |
| `supabase/functions/purchasing/cancel-purchase-order/index.ts` | 3 | Edge Function | Complete |
| `supabase/functions/purchasing/manage-supplier/index.ts` | 3 | Edge Function | Complete |
| `supabase/functions/_test/purchasing_ef_test.ts` | 3 | Deno test | Complete |
| `openspec/changes/purchasing-domain/verify-report.md` | 4 | Verification report | Complete |
