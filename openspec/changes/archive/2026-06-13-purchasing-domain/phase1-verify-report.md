# Phase 1 Verification Report — Purchasing Domain
**Status**: PASS
**Date**: 2026-06-13

## Commands

### npm run db:reset
```
Resetting local database...
Recreating database...
Initialising schema...
Seeding globals from roles.sql...
Applying migration 00001_companies_branches_profiles.sql...
Applying migration 00002_rls_helpers.sql...
Applying migration 00003_rls_policies.sql...
Applying migration 00004_catalog_domain.sql...
Applying migration 00005_inventory_domain.sql...
Applying migration 00006_purchasing_domain.sql...
Seeding data from supabase/seed.sql...
Restarting containers...
Finished supabase db reset on branch main.
```
Status: **OK** — all 6 migrations applied without error.

### npm run test:db
```
Files=8, Tests=320, 1 wallclock secs
Result: PASS
```

## Purchasing Test Results

| Test File | Tests | Passed | Failed | Status |
|-----------|-------|--------|--------|--------|
| `test_catalog_constraints.sql` | 24 | 24 | 0 | PASS |
| `test_catalog_rls.sql` | 58 | 58 | 0 | PASS |
| `test_catalog_rpcs.sql` | 82 | 82 | 0 | PASS |
| `test_inventory_constraints.sql` | 15 | 15 | 0 | PASS |
| `test_inventory_rls.sql` | 21 | 21 | 0 | PASS |
| `test_inventory_rpcs.sql` | 34 | 34 | 0 | PASS |
| `test_purchasing_constraints.sql` | 29 | 29 | 0 | PASS |
| `test_purchasing_rls.sql` | 57 | 57 | 0 | PASS |

## Fixes Applied

### Fix 1: `set_updated_at()` uses `clock_timestamp()` instead of `now()`
**File**: `supabase/migrations/00001_companies_branches_profiles.sql:139`

`NEW.updated_at = now()` → `NEW.updated_at = clock_timestamp()`

**Rationale**: pgTAP runs in a single transaction; `now()` is transaction-stable and returns the same value as `created_at`, so `updated_at > created_at` always fails. `clock_timestamp()` returns the actual wall-clock time and advances between statements, fixing all 5 purchasing constraint tests (25-29). This is a shared latent bug — all domains using `set_updated_at()` were affected, but only the purchasing tests assert `updated_at > created_at`.

### Fix 2: `service_role` INSERT grants on `suppliers` and `purchase_order_items`
**File**: `supabase/migrations/00006_purchasing_domain.sql:519,527`

Added:
- `GRANT INSERT ON public.suppliers TO service_role;`
- `GRANT INSERT ON public.purchase_order_items TO service_role;`

**Rationale**: RLS policies on these tables use `USING (TRUE)` with `service_role`, but the table-level grants only had `SELECT`. Tests 56-57 (`lives_ok` INSERT as service_role) failed with `42501: permission denied`. The other 3 purchasing tables already had their service_role INSERT grants from the `FOR ALL` RLS policy, but the grants section was missing them for suppliers and purchase_order_items.

## Summary

Purchasing domain Phase 1: **PASS** — all 320 tests across 8 test files pass. Two migration-level bugs were fixed:
1. `set_updated_at()` now uses `clock_timestamp()` (transaction-independent timestamp)
2. `service_role` now has INSERT grants on `suppliers` and `purchase_order_items`

Zero remaining failures. No transient/EOF issues encountered.
