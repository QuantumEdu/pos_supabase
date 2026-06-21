# Tasks: Inventory Domain Implementation

## Review Workload Forecast

| Field | Value |
|-------|-------|
| Estimated changed lines | 900-1400 |
| 400-line budget risk | High |
| Chained PRs recommended | Yes |
| Suggested split | PR 1 schema/RLS -> PR 2 RPCs/pgTAP -> PR 3 shared schemas/EFs/Deno -> PR 4 verification |
| Delivery strategy | force-chained |
| Chain strategy | feature-branch-chain |

Decision needed before apply: No
Chained PRs recommended: Yes
Chain strategy: feature-branch-chain
400-line budget risk: High

### Suggested Work Units

| Unit | Goal | Likely PR | Notes |
|------|------|-----------|-------|
| 1 | Inventory schema, RLS, views | PR 1 | Base = feature/tracker branch; include constraint/RLS pgTAP. |
| 2 | Inventory RPCs | PR 2 | Base = PR 1 branch; include RPC pgTAP. |
| 3 | Shared TS schemas/handler and EFs | PR 3 | Base = PR 2 branch; include Deno tests. |
| 4 | Full verification and cleanup | PR 4 | Base = PR 3 branch; no broad refactors. |

## Phase 1: Schema, RLS, and Views

- [x] 1.1 Create `supabase/migrations/00005_inventory_domain.sql` with `stock_lots`, `stock_movements`, composite FKs to catalog tables, indexes, audit fields, and CHECK constraints; verify via `supabase/tests/test_inventory_constraints.sql`.
- [x] 1.2 Add append-only protection for `stock_movements` and block direct non-RPC stock edits; verify UPDATE/DELETE and `remaining_qty` mutation failures in `supabase/tests/test_inventory_constraints.sql`.
- [x] 1.3 Add RLS policies for admin mutation, cashier branch-scoped read-only, company isolation, and service_role bypass; verify in `supabase/tests/test_inventory_rls.sql`.
- [x] 1.4 Add `v_stock_available` physical quantity only and `v_stock_expiring` all active lots sorted FEFO with NULL expiration last; verify view scenarios in pgTAP.

## Phase 2: SQL RPCs

- [x] 2.1 Add hardened RPCs in `00005_inventory_domain.sql`: `receive_purchase_lot`, `record_sale_return`, `record_waste`, and `record_expiration`; verify grants, `search_path`, lot status, and movement rows in `supabase/tests/test_inventory_rpcs.sql`.
- [x] 2.2 Add `record_sale_deduction` with FEFO multi-lot `SELECT FOR UPDATE`, no partial deduction, and negative movement rows; verify multi-lot and insufficient-stock scenarios.
- [x] 2.3 Add `adjust_inventory` with ADJ lot creation for increases, FEFO decreases, required reason, and `cost_per_unit` remaining NULL when omitted; verify adjustment scenarios.
- [x] 2.4 Add `reconcile_inventory` as drift-report-only plus V1 rejection for transfer/reservation operations; verify no auto-fix and NOT_SUPPORTED cases.

## Phase 3: Edge Functions and Deno Tests

- [x] 3.1 Create `supabase/functions/_shared/inventory_schemas.ts` and `supabase/functions/_shared/inventory_handler.ts` following catalog shared patterns; verify schema success/failure cases in Deno tests.
- [x] 3.2 Create inventory EFs under `supabase/functions/inventory/{receive-purchase,record-sale-deduction,record-sale-return,adjust-stock}/index.ts`; verify admin success, cashier/unauthenticated rejection, and `EFResult` shape.
- [x] 3.3 Create inventory EFs under `supabase/functions/inventory/{record-waste,record-expiration,reserve-stock,release-reservation}/index.ts`; verify V1.5 stubs return NOT_SUPPORTED.
- [x] 3.4 Add Deno tests in `supabase/functions/_test/inventory_receive_purchase.test.ts`, `inventory_sale_deduction.test.ts`, and `inventory_adjust_stock.test.ts`.

## Phase 4: Verification

- [x] 4.1 Run `supabase db reset` and `supabase test db`; fix only inventory-domain failures.
- [x] 4.2 Run `deno test supabase/functions/_test/`; fix only inventory EF/schema failures.
- [x] 4.3 Confirm no implementation of `stock_reservations`, transfer RPCs, cost aggregation views, or dashboard expiration filtering was added.
