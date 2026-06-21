# Proposal: Inventory Domain Implementation

## Intent

Implement the inventory domain as the source of truth for stock management in the POS system. Constitution §1 mandates that stock quantities are NEVER edited directly — all changes go through movements. Constitution §2 requires distinguishing physical vs. available stock. Constitution §15–§19 require lot tracking, FEFO strategy, and auditable adjustments. No inventory tables, RPCs, or Edge Functions exist yet; this change introduces them.

## Scope

### In Scope
- `stock_lots` table with FEFO-ordered expiration tracking, auto-generated lot codes, and per-lot costing
- `stock_movements` append-only table with 7 V1 movement types (purchase_receipt, sale, sale_return, adjustment_increase, adjustment_decrease, waste, expiration) + 2 V1.5 stubs (transfer_in, transfer_out)
- `v_stock_available` view computing physical − committed per (variant, branch)
- `v_stock_expiring` view for FEFO lot ordering
- 8 Edge Functions following catalog 8-step pattern, each backed by a SECURITY DEFINER RPC
- RLS policies: admin full mutation, cashier read-only, service_role bypass
- Adjustment RPCs that target total inventory (not forced per-lot); system resolves/creates lots per FEFO and traceability rules
- pgTAP tests (constraints, RLS, RPCs) + Deno.test EF tests

### Out of Scope
- `stock_reservations` table and reservation RPCs (deferred to customers/orders domain)
- Inter-branch transfers — enum values only, no RPC/EF implementation
- Expiration alert views/dashboard (deferred to dashboard-reports domain)
- Cost aggregation views (weighted average COGS)
- Purchasing domain (purchase orders, suppliers)

## Capabilities

### New Capabilities
- `inventory-domain`: lot-based inventory with movements, FEFO strategy, branch-scoped stock, and Edge Function mutations

### Modified Capabilities
- None — project-architecture R4 is already complete; inventory-domain implements it

## Approach

Approach A (Unified Stock Lots + Movements) from exploration. Two core tables + a reservation placeholder: `stock_lots` tracks per-batch inventory (lot_code, expiration_date, remaining_qty, cost_per_unit, status), `stock_movements` is append-only audit log. Adjustments apply to total inventory; the RPC auto-resolves lots via FEFO for decreases and creates adjustment lots for increases, preserving full traceability without forcing manual lot selection. `lot_code` auto-generates (`LOT-{branch_short}-{YYYYMMDD}-{seq}`) when absent. `remaining_qty` on `stock_lots` is a denormalized cache updated atomically within each movement RPC transaction; a reconciliation RPC validates consistency. Transfer types are enum stubs only. One migration (`00005_inventory_domain.sql`), 8 Edge Functions, RLS per catalog patterns, pgTAP + Deno.test coverage.

## Affected Areas

| Area | Impact | Description |
|------|--------|-------------|
| `supabase/migrations/00005_inventory_domain.sql` | New | Tables, indexes, views, triggers, RPCs, RLS policies |
| `supabase/functions/inventory/` | New | 8 Edge Functions (receive-purchase, record-sale-deduction, record-sale-return, adjust-stock, record-waste, record-expiration, reserve-stock, release-reservation) — reserve/release deferred |
| `supabase/functions/_shared/inventory_schemas.ts` | New | Zod validation schemas |
| `supabase/tests/test_inventory_*.sql` | New | pgTAP constraint, RLS, RPC tests |
| `supabase/functions/_test/` | New | Deno.test EF auth/schema tests |

## Risks

| Risk | Likelihood | Mitigation |
|------|------------|------------|
| `remaining_qty` drift from movement SUM | Medium | Atomic updates in RPC transactions + reconciliation RPC |
| Concurrent sales competing for same lot | Medium | `SELECT FOR UPDATE` within sale-deduction transaction |
| Transfer stubs confuse developers | Low | Migration comments + spec notes marking V1.5; RPC validation rejects transfer types in V1 |
| FEFO deduction spans multiple lots | Medium | Single-transaction loop in `record_sale_deduction` RPC, `FOR UPDATE` on each lot |
| Adjustment without lot breaks traceability | Medium | Adjustment RPC auto-creates "adjustment lot" when no lot is specified; guarantees FEFO resolution for decreases |

## Rollback Plan

Drop migration `00005_inventory_domain.sql` and all `supabase/functions/inventory/` functions. Since all inventory entities are new (no catalog table modifications), rollback is a clean removal. `supabase db reset` restores pre-inventory state. No downstream domains depend on inventory yet (purchasing is domain #3 per R10).

## Dependencies

- Catalog domain (change #2) must be archived — provides `product_variants`, `units`, and composite FK pattern
- `00004_catalog_domain.sql` migration must be applied
- RLS helpers (`get_company_id()`, `is_admin()`, `is_cashier()`, `get_user_branch_id()`) from `00002_rls_helpers.sql`

## Success Criteria

- [ ] All 3 inventory tables created with correct constraints, indexes, and composite FKs
- [ ] RLS policies enforce company isolation; cashier cannot mutate inventory
- [ ] All 8 RPCs: `SECURITY DEFINER`, `SET search_path = public`, `REVOKE ALL FROM PUBLIC+anon`, `GRANT EXECUTE TO authenticated`
- [ ] FEFO deduction works across multiple lots in single transaction
- [ ] Adjustment RPC creates lots when needed; no direct stock edits possible
- [ ] `v_stock_available` and `v_stock_expiring` return correct aggregates
- [ ] pgTAP and Deno.test suites pass
- [ ] `lot_code` auto-generates when null; uniqueness enforced per (company, branch, variant)