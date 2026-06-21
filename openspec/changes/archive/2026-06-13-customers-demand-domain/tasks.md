# Tasks: Customers Demand Domain

## Review Workload Forecast

| Field | Value |
|-------|-------|
| Estimated changed lines | ~590 (migration ~240, constraint tests ~150, RLS tests ~200) |
| 400-line budget risk | High |
| Chained PRs recommended | Yes |
| Suggested split | PR 1: Migration + constraint tests (~390 lines) → PR 2: RLS tests + verification (~200 lines) |
| Delivery strategy | ask-on-risk |
| Chain strategy | feature-branch-chain |

Decision needed before apply: Yes
Chained PRs recommended: Yes
Chain strategy: feature-branch-chain
400-line budget risk: High

### Suggested Work Units

| Unit | Goal | Likely PR | Notes |
|------|------|-----------|-------|
| 1 | Schema migration + constraint pgTAP tests | PR 1 | Targets `feature/customers-demand-domain`; includes `00007_customers_demand_domain.sql` and `test_customers_demand_constraints.sql` |
| 2 | RLS isolation pgTAP tests + verification | PR 2 | Targets PR 1 branch; includes `test_customers_demand_rls.sql` and verify report |

## Phase 1: Schema Migration (PR 1)

- [x] 1.1 Create `supabase/migrations/00007_customers_demand_domain.sql` with `customers` table: UUID PK `gen_random_uuid()`, `company_id` FK → `companies`, `name`, `slug` UNIQUE `(company_id, slug)`, optional `tax_id`/`phone`/`email`/`address`/`notes`, `is_active NOT NULL DEFAULT TRUE`, audit columns (`created_at`, `updated_at`, `created_by`, `updated_by`, `deleted_at`, `deleted_by`)
- [x] 1.2 Add `customer_requests` table: UUID PK, `company_id` FK → `companies`, `customer_id`, nullable `variant_id`, `requested_qty NUMERIC(14,3) CHECK (> 0)`, `status TEXT CHECK ('pending','resolved','cancelled') DEFAULT 'pending'`, `is_active`, audit columns (including `deleted_at`/`deleted_by`)
- [x] 1.3 Add `preorders` table: UUID PK, `company_id` FK → `companies`, `branch_id`, `customer_id`, `preorder_number TEXT UNIQUE (company_id, preorder_number)`, `status TEXT CHECK ('draft','confirmed','fulfilled','cancelled') DEFAULT 'draft'`, `is_active`, audit columns (including `deleted_at`/`deleted_by`)
- [x] 1.4 Add `preorder_items` table: UUID PK, `company_id` FK → `companies`, `preorder_id`, `variant_id NOT NULL`, `qty NUMERIC(14,3) CHECK (> 0)`, `unit_price NUMERIC(12,2)` nullable, `is_active`, audit columns (including `deleted_at`/`deleted_by`, matching `purchase_order_items` pattern)
- [x] 1.5 Create composite unique indexes `(company_id, id)` on all 4 tables (`customers`, `customer_requests`, `preorders`, `preorder_items`) to enable composite FK targeting
- [x] 1.6 Add 6 composite FK constraints via idempotent ALTER TABLE DO blocks: `customer_requests(company_id,customer_id)→customers`, `customer_requests(company_id,variant_id)→product_variants` (nullable), `preorders(company_id,branch_id)→branches`, `preorders(company_id,customer_id)→customers`, `preorder_items(company_id,preorder_id)→preorders`, `preorder_items(company_id,variant_id)→product_variants`
- [x] 1.7 Attach `set_updated_at()` trigger on all 4 tables via idempotent DO-loop pattern matching 00004/00005/00006
- [x] 1.8 Enable RLS and create 16 policies: SELECT own-company (cashier branch-scoped on preorders via `branch_users`), INSERT admin, UPDATE admin, service_role ALL bypass
- [x] 1.9 Add GRANT: authenticated SELECT/INSERT/UPDATE, anon SELECT, service_role SELECT on all 4 tables
- [x] 1.10 Verify: `supabase db reset` applies 00001→00007 idempotently with zero errors; all 4 tables exist with correct columns, indexes, and RLS enabled

## Phase 2: Constraint Tests (PR 1)

- [x] 2.1 Create `supabase/tests/test_customers_demand_constraints.sql` — test `customers(company_id, slug)` uniqueness, same slug in different company allowed, duplicate same-company slug rejected
- [x] 2.2 Test CHECK constraints: `customer_requests.status` rejects invalid values, `requested_qty > 0` enforced, `preorders.status` rejects invalid values, `preorder_items.qty > 0` enforced, `unit_price` accepts NULL, `variant_id` rejects NULL on `preorder_items`
- [x] 2.3 Test composite FK integrity: cross-tenant `customer_requests.customer_id` rejected, cross-tenant `preorders.branch_id` rejected, cross-tenant `preorder_items.variant_id` rejected, `customer_requests.variant_id` NULL accepted, same-company FK validations pass
- [x] 2.4 Test `preorder_number` unique per company; same number in different companies allowed; duplicate same-company number rejected
- [x] 2.5 Test `set_updated_at` trigger fires on UPDATE for all 4 tables; `deleted_at`/`deleted_by` columns accept NULL and non-NULL
- [x] 2.6 Verify: `supabase test db` — all constraint tests pass green

## Phase 3: RLS Isolation Tests (PR 2)

- [x] 3.1 Create `supabase/tests/test_customers_demand_rls.sql` — test admin cross-tenant isolation: admin A sees only company A rows on all 4 tables, admin B invisible
- [x] 3.2 Test admin INSERT/UPDATE: admin creates/updates own-company rows; cross-company company_id mismatch rejected by RLS policy
- [x] 3.3 Test cashier SELECT read-only: SELECT returns own-company rows; INSERT fails (WITH CHECK violation), UPDATE silently blocked (USING clause filters to 0 rows) on all 4 tables
- [x] 3.4 Test cashier branch scoping on `preorders`: cashier B1 sees only branch B1 preorders; `preorder_items` filtered to parent preorders belonging to cashier's branch (policy fixed: added EXISTS subquery JOIN to preorders)
- [x] 3.5 Test unauthenticated (`anon`) returns zero rows on all 4 tables; service_role SELECT bypass via GRANT
- [x] 3.6 Test no DELETE policy: DELETE fails with `insufficient_privilege` on all 4 tables for authenticated role

## Phase 4: Verification & Spec Alignment (PR 2)

- [x] 4.1 Run `supabase db reset` — confirm migrations 00001→00007 apply idempotently in order
- [x] 4.2 Run `supabase test db` — all pgTAP tests pass (constraints + RLS), zero failures: 464/464 PASS
- [x] 4.3 Audit migration SQL: confirm zero references to `reserve_stock`, `release_reservation`, `stock_lots`, `stock_movements`, Edge Functions, or SECURITY DEFINER RPCs
- [x] 4.4 Verify acceptance criteria from proposal.md — all 11 checkboxes pass
- [x] 4.5 Update `tasks.md` marking all completed tasks `[x]`; write `verify-report.md`
