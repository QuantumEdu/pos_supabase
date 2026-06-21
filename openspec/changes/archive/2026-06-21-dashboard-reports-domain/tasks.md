# Tasks: Dashboard, Reports & Export Domain

## Phase 1: PR1 — Migration (Schema + Views + Indexes)

**Est. lines**: ~450
**Budget risk**: Medium (approaching 400-line limit but within tolerance)

[x] 1.1 — Create `supabase/migrations/00012_dashboard_reports_domain.sql` — schema change: `ALTER TABLE product_variants ADD COLUMN IF NOT EXISTS reorder_threshold NUMERIC(12,2)`
[x] 1.2 — Add 7 composite indexes: `idx_sales_company_created_at`, `idx_sales_company_branch_created_at`, `idx_sales_company_cashier_created_at`, `idx_sale_items_company_variant`, `idx_payments_company_method_created_at`, `idx_stock_lots_company_branch_status_qty`, `idx_stock_lots_company_expiration`
[x] 1.3 — Create dashboard views (7): `v_dashboard_sales_today`, `v_dashboard_sales_week`, `v_dashboard_sales_month`, `v_dashboard_low_stock`, `v_dashboard_near_expiration`, `v_dashboard_outstanding_balances`, `v_dashboard_sales_by_branch`
[x] 1.4 — Create report views (8): `v_report_sales_by_day`, `v_report_sales_by_week`, `v_report_sales_by_month`, `v_report_current_inventory`, `v_report_low_stock`, `v_report_expiration`, `v_report_customer_balances`, `v_report_payments_received`
[x] 1.5 — Add COMMENT ON for all 15 views and the reorder_threshold column

**pgTAP tests for PR1**:
[x] 1.6 — Write pgTAP test suite for views (test_views_dashboard.sql): verify each view returns correct columns, RLS isolation, security_invoker, zero-row handling
[x] 1.7 — Write pgTAP test suite for indexes (test_indexes_dashboard.sql): verify all 7 indexes exist

## Phase 2: PR2 — RPCs

**Est. lines**: ~380
**Budget risk**: Low

[x] 2.1 — Create helper function `fn_jsonb_to_csv(p_data JSONB)` IMMUTABLE — JSONB array to CSV text with string escaping
[x] 2.2 — Create `fn_report_sales_by_cashier(p_company_id UUID, p_date_from DATE, p_date_to DATE)` — SECURITY DEFINER, cross-tenant guard, joins profiles for cashier_name
[x] 2.3 — Create `fn_report_cash_cut(p_company_id UUID, p_cash_session_id UUID)` — session details + payment breakdown + cash movements, matches close_cash_session logic
[x] 2.4 — Create `fn_report_purchases_by_supplier(p_company_id UUID, p_date_from DATE, p_date_to DATE)` — supplier aggregation
[x] 2.5 — Create `fn_purchase_suggestions(p_company_id UUID, p_branch_id UUID DEFAULT NULL)` — 5-CTE chain: sales velocity, current stock, pending requests, thresholds, priority scoring (weights: 4 requests, 3 velocity, 2 low-stock, 1 sold-out)
[x] 2.6 — Create `fn_export_entities(p_company_id UUID, p_entity TEXT, p_format TEXT DEFAULT 'json', p_filters JSONB DEFAULT '{}')` — 6 entity types with CSV/JSON format
[x] 2.7 — Add COMMENT ON, REVOKE/GRANT for all 6 functions

**pgTAP tests for PR2**:
[x] 2.8 — Write pgTAP test suite for RPCs (test_rpcs_dashboard.sql): verify function existence, cross-tenant rejection, return types, edge cases

## Phase 3: PR4 — Edge Functions (deferred)

**Blocked by**: PR2 RPCs (fn_export_entities must exist)
**Est. lines**: ~300
**Budget risk**: Low

[x] 3.1 — Create `supabase/functions/export-csv/index.ts` — 8-step pattern: CORS, auth, admin role, Zod validate, call fn_export_entities RPC, set Content-Disposition header, stream CSV, audit placeholder
[x] 3.2 — Create `supabase/functions/_shared/export_csv_handler.ts` — shared handler for CSV export
[x] 3.3 — Write Deno tests for CSV export EF

---

## Dependencies

```
1.1 → 1.3, 1.4 (views depend on reorder_threshold column existing)
1.2 → 1.3, 1.4 (query performance optimized by indexes)
1.3-1.5 → 2.x (views must exist for RPCs that reference them)
1.6-1.7 → 2.x (pgTAP tests validate PR1 before PR2 applies)
2.1-2.7 → 3.x (RPCs must exist for EF to call)
2.8 → 3.x
```

## Workload Forecast

| Metric | Value |
|--------|-------|
| Total lines estimated | ~1,130 (PR1: ~450, PR2: ~380, PR4: ~300) |
| Chained PRs recommended | Yes |
| 400-line budget risk | PR1: Medium (~450), PR2: Low, PR4: Low |
| Decision needed before apply | Yes — confirm feature-branch-chain strategy |

## Test Strategy

- **PR1 pgTAP**: `test_views_dashboard.sql` (~40 assertions) + `test_indexes_dashboard.sql` (~7 assertions)
- **PR2 pgTAP**: `test_rpcs_dashboard.sql` (~30 assertions)
- **PR4 Deno**: `export_csv_test.ts` (~15 tests)
- Coverage target: all spec scenarios (RR1-RR25)

## Rollback Plan

Drop migration 00012: `DROP VIEW IF EXISTS ... CASCADE` (all 15 views), `DROP FUNCTION IF EXISTS ... CASCADE` (all 6 functions), `DROP INDEX IF EXISTS ...` (7 indexes). Schema change (`reorder_threshold` column) requires explicit `ALTER TABLE product_variants DROP COLUMN IF EXISTS reorder_threshold`. Zero data loss.
