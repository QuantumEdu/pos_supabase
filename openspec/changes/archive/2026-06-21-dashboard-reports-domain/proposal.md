# Proposal: Dashboard, Reports & Export Domain

## Intent

Deliver real-time admin dashboard metrics, parameterized business reports, purchase suggestion engine, and CSV export for the multi-tenant POS. Resolves plan §28-30 requirements and the open decision on Excel export (D3 in project-architecture R11).

## Scope

### In Scope (V1)
- 7 dashboard views with `security_invoker = true` (today/week/month sales, low stock, near-expiration, outstanding balances, sales by branch)
- 6 report views (sales by day/week/month, current inventory, low stock, expiration, customer balances)
- 6 report/biz-logic RPCs (sales by cashier, cash cut, payments received, purchases by supplier, purchase suggestions, parameterized near-expiration)
- `product_variants.reorder_threshold` column (nullable NUMERIC)
- 7 time-range composite indexes for dashboard/report performance
- CSV export: RPC → JSONB → Edge Function streams CSV (6 entities)
- Migration 00012

### Out of Scope
- Excel (.xlsx) export → V1.5 (Edge Function size limit; CSV importable by Excel)
- Materialized views → V1.5/V2 (live views sufficient for MVP data volumes)
- pg_cron extension → deferred with mat views
- Report caching → V1.5 (instrument first, optimize later)
- Cashier-specific dashboard views → single view set, RLS handles role filtering

## Capabilities

### New Capabilities
- `dashboard-reports-domain`: Views, RPCs, indexes, Edge Functions, and export infrastructure for admin dashboard, business reports, purchase suggestions, and CSV export

### Modified Capabilities
- `project-architecture`: Resolves open decision #3 (Excel export scope: CSV-only V1)
- `inventory-domain`: Adds `reorder_threshold` column to `product_variants` table

## Approach

**SQL Views + RPC Functions** (per exploration recommendation). Dashboard metrics use `CREATE VIEW` with `security_invoker = true` and `CURRENT_DATE` filters for real-time data. Parameterized reports use `SECURITY DEFINER` RPCs returning JSONB. Purchase suggestions use a dedicated RPC with CTE-based priority scoring (pending requests weight 4, velocity weight 3, low_stock weight 2, sold_out weight 1). Export uses RPCs returning JSONB, streamed as CSV by Edge Functions. New `reorder_threshold` column on `product_variants` enables per-variant low-stock thresholds.

### Dashboard Views (7)

| View | Key Columns |
|------|-------------|
| `v_dashboard_sales_today` | company_id, total, count, payment_method_totals |
| `v_dashboard_sales_week` | company_id, day, total, count |
| `v_dashboard_sales_month` | company_id, day, total, count |
| `v_dashboard_low_stock` | company_id, variant_id, available_qty, reorder_threshold |
| `v_dashboard_near_expiration` | company_id, variant_id, lot_code, expiration_date, remaining_qty |
| `v_dashboard_outstanding_balances` | company_id, customer_id, total_amount, remaining_amount |
| `v_dashboard_sales_by_branch` | company_id, branch_id, total, count |

### Report Views (6) & RPCs (6)

| Name | Type | Key Parameters |
|------|------|----------------|
| `v_report_sales_by_day` | View | Date range via WHERE |
| `v_report_sales_by_week` | View | Date range via WHERE |
| `v_report_sales_by_month` | View | Date range via WHERE |
| `v_report_current_inventory` | View | Branch filter via WHERE |
| `v_report_low_stock` | View | Threshold filter |
| `v_report_expiration` | View | Date range via WHERE |
| `v_report_customer_balances` | View | Status filter via WHERE |
| `fn_report_sales_by_cashier` | RPC | company_id, date_from, date_to |
| `fn_report_cash_cut` | RPC | company_id, cash_session_id |
| `fn_report_payments_received` | RPC | company_id, date_from, date_to |
| `fn_report_purchases_by_supplier` | RPC | company_id, date_from, date_to |
| `fn_purchase_suggestions` | RPC | company_id, branch_id (optional) |
| `fn_report_near_expiration` | RPC | company_id, days_threshold (default 30) |

### Purchase Suggestion Engine

Frequency-based: CTE chain computes (1) pending customer requests, (2) 30-day sales velocity, (3) current stock, (4) priority score. Suggested order qty = `max(pending_requests, avg_daily_sales × 7) - current_stock`. Ordered by priority descending.

### CSV Export

RPC returns JSONB result set → Edge Function converts to CSV with `Content-Disposition: attachment` header. Entities: products, inventory, sales, customers, purchases, credits.

### `reorder_threshold` Column

Add `reorder_threshold NUMERIC` (nullable) to `product_variants`. NULL means use company-level threshold (future). Enables per-variant low-stock alerting — proper domain model vs hardcoded constant.

### New Indexes

| Table | Index |
|-------|-------|
| sales | (company_id, created_at) |
| sales | (company_id, branch_id, created_at) |
| sales | (company_id, cashier_user_id, created_at) |
| sale_items | (company_id, variant_id) |
| payments | (company_id, payment_method, created_at) |
| stock_lots | (company_id, branch_id, status, remaining_qty) |
| stock_lots | (company_id, expiration_date) |

## PR Boundary Breakdown

| PR | Content | Est. Lines | Budget Risk |
|----|---------|-----------|-------------|
| 1 | Migration: `reorder_threshold` column, 7 indexes, 13 views | ~350 | Low |
| 2 | RPCs: 6 report/biz-logic functions | ~400 | Medium |
| 3 | Purchase suggestion engine + export helper RPCs | ~350 | Medium |
| 4 | Edge Functions for CSV export (6 entities) | ~400 | Medium |

Chained: PR2 depends on PR1 views; PR3 depends on PR1 indexes; PR4 depends on PR2-3 RPCs.

## Dependencies

- All 8 prior domain migrations must be applied (catalog → purchasing → inventory → customers → pos-sales → cash-session → credit-payments → returns)
- `v_stock_available` and `v_stock_expiring` views must exist

## Risks

| Risk | Likelihood | Mitigation |
|------|------------|-------------|
| Slow dashboard on >100K sales | Medium | Time-range indexes; defer mat views to V1.5 |
| RLS on materialized views | Low | Not using mat views in V1 |
| Cash cut report mismatch with close session | Medium | Must reuse exact same calculation logic from `close_cash_session` |
| Edge Function memory on large CSV exports | Low | Stream row-by-row; paginate if needed |

## Rollback Plan

Drop migration 00012: CASCADE drops all views, RPCs, indexes, and the `reorder_threshold` column. Edge Functions are independent — delete function folders. Zero data loss (no operational table mutations in this domain).

## Success Criteria

- [ ] 7 dashboard views return correct real-time metrics filtered by `CURRENT_DATE`
- [ ] 6 RPCs return correct aggregated data for parameterized date ranges
- [ ] Purchase suggestions ordered by priority with correct suggested qty formula
- [ ] CSV export streams valid CSV for all 6 entities
- [ ] RLS enforced: cashier sees own branch data, admin sees company-wide
- [ ] All dashboard queries respond < 200ms for < 50K sales dataset