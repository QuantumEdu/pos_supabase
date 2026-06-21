# Phase 2 Verification Report — Purchasing Domain RPCs (Post-Warnings Fix)

**Date**: 2026-06-13
**Phase**: Phase 2 — W1-W4 warnings addressed
**Status**: PASS

---

## Command Results

### `npm run db:reset`
```
Resetting local database...
Applying migration 00001_companies_branches_profiles.sql...
Applying migration 00002_rls_helpers.sql...
Applying migration 00003_rls_policies.sql...
Applying migration 00004_catalog_domain.sql...
Applying migration 00005_inventory_domain.sql...
Applying migration 00006_purchasing_domain.sql...
Seeding data from supabase/seed.sql...
Finished supabase db reset on branch main.
```

### `npm run test:db`
```
All tests successful.
Files=9, Tests=388, 1 wallclock secs
Result: PASS
```

| Test File | Status |
|-----------|--------|
| test_catalog_constraints.sql | ok |
| test_catalog_rls.sql | ok |
| test_catalog_rpcs.sql | ok |
| test_inventory_constraints.sql | ok |
| test_inventory_rls.sql | ok |
| test_inventory_rpcs.sql | ok |
| test_purchasing_constraints.sql | ok |
| test_purchasing_rls.sql | ok |
| test_purchasing_rpcs.sql | ok (68/68) |

---

## Warnings Addressed

### W1: Locking Design Deviation
- **Fixed**: Replaced per-item `SELECT FOR UPDATE` loop in `receive_purchase_transaction` with a batched lock of all target `purchase_order_items` in deterministic `ORDER BY id`. The PO header `FOR UPDATE` remains as the primary mutex serializing concurrent receipts; item-level batched lock ensures all items are valid before any writes proceed.
- **File**: `supabase/migrations/00006_purchasing_domain.sql`

### W2: Trigger Test False-Positive Risk
- **Fixed**: Tightened critical-column protection assertions in `test_purchasing_constraints.sql` to assert exact exception messages (`'Direct received_qty edits on purchase_order_items are prohibited; use purchasing RPCs'` and `'Direct status edits on purchase_orders are prohibited; use purchasing RPCs'`) instead of accepting any exception (`NULL` matchers).
- **File**: `supabase/tests/test_purchasing_constraints.sql`

### W3: Missing Double-Cancel Coverage
- **Fixed**: Added pgTAP RPC test (test 16b) proving `cancel_purchase_order` rejects already-cancelled POs with an exception.
- **File**: `supabase/tests/test_purchasing_rpcs.sql`

### W4: Subtotal/Tax Override Ambiguity
- **Fixed**: Removed client-provided `subtotal`/`tax_amount` override blocks from `create_purchase_order` RPC. All item and PO totals are now strictly computed server-side from `ordered_qty * unit_cost` and `subtotal * tax_rate`.
- **Files**: `supabase/migrations/00006_purchasing_domain.sql`, `supabase/tests/test_purchasing_rpcs.sql` (added PO subtotal, tax_total, and item-level verification assertions)

### Optional (Low-Risk)
- Added test 13b: `receive_purchase_transaction` rejects zero received_qty
- Added test 16c: `receive_purchase_transaction` rejects cancelled PO
- Removed duplicate `v_items := p->'items';` dead code (line 598)

---

## Files Changed

| File | Action | Tests |
|------|--------|-------|
| `supabase/migrations/00006_purchasing_domain.sql` | W1 batched lock + W4 override removal + dead code removal | — |
| `supabase/tests/test_purchasing_constraints.sql` | W2 tightened trigger assertions | 29 |
| `supabase/tests/test_purchasing_rpcs.sql` | W3 double-cancel + W4 verification + optional edge-case tests | 68 (+7) |
| `openspec/changes/purchasing-domain/phase2-verify-report.md` | This report | — |

---

## Remaining Risks
- None. Phase 2 is fully verified with 388 total tests passing (381 from prior run + 7 new).

## Next Recommended Action
Proceed with Phase 3: Edge Functions + Deno Tests.
- Files: `purchasing_handler.ts`, `purchasing_schemas.ts`, 4 EF `index.ts` files, `purchasing_ef_test.ts`
