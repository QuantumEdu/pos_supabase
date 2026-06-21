# PR 1 Verify Report: Customers Demand Domain

## Status: PASS

## Files Created

| File | Lines | Purpose |
|------|-------|---------|
| `supabase/migrations/00007_customers_demand_domain.sql` | 282 | 4 tables, 4 composite unique indexes, 6 composite FKs, 4 triggers, 16 RLS policies, 12 grants |
| `supabase/tests/test_customers_demand_constraints.sql` | 276 | 26 pgTAP tests covering uniqueness, CHECK, composite FK, triggers, nullable columns |

## Migration Verification

```
supabase db reset → PASS (zero errors)
Migrations applied: 00001 → 00007 in order
```

## Constraint Test Results

```
test_customers_demand_constraints.sql ... 26/26 PASS
```

### Test Breakdown

| # | Category | Tests | Result |
|---|----------|-------|--------|
| 1–2 | customers (company_id, slug) uniqueness | Duplicate same-company rejected; cross-company allowed | PASS |
| 3–4 | preorders (company_id, preorder_number) uniqueness | Duplicate same-company rejected; cross-company allowed | PASS |
| 5 | customer_requests.status CHECK | Invalid value rejected | PASS |
| 6 | customer_requests.requested_qty CHECK | <= 0 rejected | PASS |
| 7 | preorders.status CHECK | Invalid value rejected | PASS |
| 8 | preorder_items.qty CHECK | <= 0 rejected | PASS |
| 9 | preorder_items.unit_price NULL | Accepted | PASS |
| 10 | preorder_items.variant_id NOT NULL | NULL rejected | PASS |
| 11 | cr → customers cross-tenant FK | Rejected | PASS |
| 12 | cr → variant cross-tenant FK | Rejected | PASS |
| 13 | cr variant_id NULL accepted | Accepted (nullable FK) | PASS |
| 14 | cr valid same-company variant FK | Accepted | PASS |
| 15 | preorder → customer cross-tenant FK | Rejected | PASS |
| 16 | preorder → branch cross-tenant FK | Rejected | PASS |
| 17 | pi → preorder cross-tenant FK | Rejected | PASS |
| 18 | pi → variant cross-tenant FK | Rejected | PASS |
| 19–22 | set_updated_at trigger | Fires on all 4 tables | PASS |
| 23–26 | deleted_at/deleted_by NULL | Accepted on all 4 tables | PASS |

### Full Test Suite

```
All tests successful. Files=10, Tests=414, Result: PASS
```

## Design Decisions Implemented

| Decision | Implementation |
|----------|---------------|
| D1: SDK + RLS only | No RPCs, no Edge Functions in migration 00007 |
| D2: preorder_number column | TEXT NOT NULL UNIQUE(company_id, preorder_number) |
| D3: pi independent logical deletion | is_active, deleted_at, deleted_by on preorder_items |
| D5: preorders branch scoping | Cashier SELECT uses branch_users JOIN |
| Preorders SELECT policy | Complex USING: admin OR branch_id OR branch_users EXISTS |

## Compliance Checks

- [x] No `reserve_stock`, `release_reservation`, `stock_lots`, `stock_movements` references
- [x] No `CREATE OR REPLACE FUNCTION` (RPC) statements
- [x] No Edge Function directories created
- [x] Idempotent DDL (IF NOT EXISTS / DO blocks)
- [x] No DELETE policies on any table
- [x] All FK constraints use composite (company_id, target_id) pattern
- [x] All tables have `set_updated_at()` trigger
- [x] RLS enabled on all 4 tables

## PR 2 Readiness

PR 2 (RLS isolation tests + verification) can proceed immediately:
- Migration is stable and idempotent
- All constraint tests pass
- Schema matches design and spec
- No blockers identified
