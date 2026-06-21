# Verify Report: Customers Demand Domain — PR 2 (Phase 3 + Phase 4)

**Date:** 2026-06-13  
**PR:** 2 of 2 (feature-branch-chain)  
**Scope:** RLS isolation tests, migration audit, final verification

---

## Test Results

| Test File | Tests | Result |
|-----------|-------|--------|
| `test_catalog_constraints.sql` | 22 | PASS |
| `test_catalog_rls.sql` | 58 | PASS |
| `test_catalog_rpcs.sql` | 14 | PASS |
| `test_customers_demand_constraints.sql` | 26 | PASS |
| `test_customers_demand_rls.sql` | 50 | PASS |
| `test_inventory_constraints.sql` | 22 | PASS |
| `test_inventory_rls.sql` | 21 | PASS |
| `test_inventory_rpcs.sql` | 40 | PASS |
| `test_purchasing_constraints.sql` | 37 | PASS |
| `test_purchasing_rls.sql` | 57 | PASS |
| `test_purchasing_rpcs.sql` | 88 | PASS |
| **Total** | **464** | **464/464 PASS** |

---

## Phase 3: RLS Isolation Test Coverage

### 3.1 Admin Cross-Tenant Isolation (tests 1–8)
- Admin A sees only company A rows on all 4 tables (customers, customer_requests, preorders, preorder_items)
- Cross-tenant rows (company B) invisible: `count WHERE company_id != A = 0` verified on all 4 tables

### 3.2 Admin INSERT/UPDATE (tests 9–24)
- Admin can INSERT into own company on all 4 tables (`lives_ok`)
- Admin can UPDATE own-company rows on all 4 tables (`lives_ok`)
- Admin INSERT cross-company rejected on all 4 tables (`throws_ok`)
- Admin UPDATE cross-tenant silently blocked (0 rows affected), verified unchanged (`is()`)

### 3.3 Cashier SELECT Read-Only (tests 25–36)
- Cashier can SELECT own-company rows on all 4 tables
- Cashier INSERT fails (WITH CHECK policy violation) on all 4 tables (`throws_ok`)
- Cashier UPDATE silently blocked (USING clause filters to 0 rows); verified unchanged via `is()`

### 3.4 Cashier Branch Scoping (tests 27, 28, 37, 38)
- Cashier sees only assigned-branch preorders (branch A1)
- Other-branch preorders invisible (count = 0)
- preorder_items filtered to parent preorders on cashier's branch via EXISTS subquery JOIN

### 3.5 Unauthenticated + Service Role (tests 39–46)
- `anon` sees 0 rows on all 4 tables
- `service_role` sees all rows across both companies (RLS bypass)

### 3.6 No DELETE Policy (tests 47–50)
- DELETE blocked with SQLSTATE `42501` (insufficient privilege) on all 4 tables for authenticated role

---

## Migration Audit (4.3)

| Check | Result |
|-------|--------|
| References to `reserve_stock` | 0 — clean |
| References to `release_reservation` | 0 — clean |
| References to `stock_lots` | 0 — clean |
| References to `stock_movements` | 0 — clean |
| References to `stock_reservations` | 0 — clean |
| `CREATE OR REPLACE FUNCTION` (RPC) | 0 — clean |
| `SECURITY DEFINER` | 0 — clean |
| Edge Function directories (`customers/`, `customer-requests/`, `preorders/`, `preorder-items/`) | None exist |

---

## Migration Fix Applied

The `preorder_items_select_own` RLS policy was updated from simple `company_id = get_company_id()` to include cashier branch scoping via EXISTS subquery JOIN to `preorders`, matching the spec (RCD9) and aligning with the `preorders_select_own` policy pattern. Without this fix, cashiers could see preorder_items from all branches.

**Change:** `supabase/migrations/00007_customers_demand_domain.sql` lines 351–371

---

## Files Changed

| File | Change |
|------|--------|
| `supabase/migrations/00007_customers_demand_domain.sql` | Fixed `preorder_items_select_own` policy — added branch scoping via EXISTS JOIN to preorders |
| `supabase/tests/test_customers_demand_rls.sql` | Created — 50 pgTAP RLS isolation tests |
| `openspec/changes/customers-demand-domain/tasks.md` | Marked Phase 3 + Phase 4 checkboxes `[x]` |
| `openspec/changes/customers-demand-domain/verify-report.md` | Created — this file |

---

## Acceptance Criteria (all 11)

| # | Criterion | Status |
|---|-----------|--------|
| 1 | `supabase db reset` applies idempotently 00001→00007 | PASS |
| 2 | All 4 tables created with correct columns, indexes, RLS | PASS |
| 3 | Composite unique indexes `(company_id, id)` on all 4 tables | PASS |
| 4 | 6 composite FK constraints enforce same-company references | PASS |
| 5 | `set_updated_at()` triggers on all 4 tables | PASS |
| 6 | 16 RLS policies matching role matrix (4 per table) | PASS |
| 7 | No DELETE policies on any table | PASS |
| 8 | All pgTAP tests pass (464/464) | PASS |
| 9 | No Edge Functions or RPCs in V1 | PASS |
| 10 | No inventory reservation activation | PASS |
| 11 | Migration idempotent on re-apply | PASS |

---

## Status: PASS

PR 2 is complete. All phases (1–4) implemented and verified. The change is ready for archive.
