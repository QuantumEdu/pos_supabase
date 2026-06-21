# Dashboard Reports Domain Specification

## Purpose

Real-time admin dashboard metrics, parameterized business reports, purchase suggestion engine, and CSV export for multi-tenant SaaS POS. Dashboard views provide live today/week/month sales, low-stock alerts, near-expiration lots, outstanding balances, and branch comparisons. Report views and RPCs provide day/week/month aggregations, inventory snapshots, cashier summaries, cash cut details, and supplier breakdowns. Resolves project-architecture R11 #3 (CSV-only V1, xlsx deferred to V1.5). Depends on all 8 prior domain migrations (catalog through returns).

## Requirements

### RR1: v_dashboard_sales_today

The system MUST provide `v_dashboard_sales_today` with `security_invoker = true` returning `company_id`, `branch_id`, `total_sales` (NUMERIC), `sales_count` (BIGINT), `by_payment_method` (JSONB aggregate of payment_method → total per method), and `as_of_date` (DATE DEFAULT CURRENT_DATE). The view MUST filter `sales` where `created_at >= CURRENT_DATE` and `status != 'cancelled'`. RLS enforces company isolation; cashier sees own branch only.

- **GIVEN** company A with 3 sales today totalling $450 and 2 via cash, 1 via card → **WHEN** admin queries `v_dashboard_sales_today` → **THEN** `total_sales = 450`, `sales_count = 3`, `by_payment_method = {"cash": 300, "card": 150}`, `as_of_date = CURRENT_DATE`
- **GIVEN** company A user → **WHEN** querying → **THEN** only company A rows; company B rows invisible
- **GIVEN** no sales today for company A → **WHEN** querying → **THEN** zero rows returned (not a zero-valued row)

### RR2: v_dashboard_sales_week

The system MUST provide `v_dashboard_sales_week` with `security_invoker = true` returning `company_id`, `branch_id`, `day_date` (DATE), `daily_total` (NUMERIC), `daily_count` (BIGINT), `as_of_date` (DATE DEFAULT CURRENT_DATE). The view MUST group sales by day for `CURRENT_DATE - INTERVAL '6 days'` through `CURRENT_DATE` using `date_trunc('day', created_at)`.

- **GIVEN** company A with sales Mon–Wed → **WHEN** admin queries → **THEN** rows for Mon, Tue, Wed with daily totals; Thu–Sun absent (no sales)
- **GIVEN** cashier for branch B1 → **WHEN** querying → **THEN** only branch B1 rows visible

### RR3: v_dashboard_sales_month

The system MUST provide `v_dashboard_sales_month` with `security_invoker = true` returning `company_id`, `branch_id`, `day_date` (DATE), `daily_total` (NUMERIC), `daily_count` (BIGINT), `as_of_date` (DATE DEFAULT CURRENT_DATE). The view MUST group sales by day for the current calendar month (`date_trunc('month', CURRENT_DATE)` through `CURRENT_DATE`).

- **GIVEN** company A with sales on days 1–5 of the month → **WHEN** admin queries → **THEN** rows for days 1–5 with daily totals
- **GIVEN** day with no sales → **WHEN** querying → **THEN** that day absent (not a zero row)

### RR4: v_dashboard_low_stock

The system MUST provide `v_dashboard_low_stock` with `security_invoker = true` returning `company_id`, `branch_id`, `variant_id`, `variant_name` (from `product_variants`), `sku`, `available_qty` (from `v_stock_available.physical_qty`), `reorder_threshold` (from `product_variants.reorder_threshold`), `below_threshold_by` (NUMERIC computed as `reorder_threshold - available_qty`). The view MUST show only variants where `reorder_threshold IS NOT NULL AND available_qty <= reorder_threshold` or where `available_qty = 0` regardless of threshold.

- **GIVEN** variant with `available_qty = 3` and `reorder_threshold = 5` → **WHEN** querying → **THEN** row shows `below_threshold_by = 2`
- **GIVEN** variant with `available_qty = 10` and `reorder_threshold = 5` → **WHEN** querying → **THEN** row absent (above threshold)
- **GIVEN** variant with `available_qty = 0` and `reorder_threshold = NULL` → **WHEN** querying → **THEN** row shows `below_threshold_by = NULL` (zero stock regardless of threshold)

### RR5: v_dashboard_near_expiration

The system MUST provide `v_dashboard_near_expiration` with `security_invoker = true` returning `company_id`, `branch_id`, `lot_id`, `variant_id`, `lot_code`, `expiration_date`, `remaining_qty`, `days_until_expiry` (INTEGER computed as `expiration_date - CURRENT_DATE`). The view MUST show only active lots where `expiration_date <= CURRENT_DATE + INTERVAL '30 days'` AND `expiration_date IS NOT NULL`. NULL expiration dates are excluded.

- **GIVEN** lot expiring in 10 days with `remaining_qty = 5` → **WHEN** querying → **THEN** `days_until_expiry = 10`, `remaining_qty = 5`
- **GIVEN** lot with NULL `expiration_date` → **WHEN** querying → **THEN** row absent (no expiration tracking)
- **GIVEN** lot expiring in 45 days → **WHEN** querying → **THEN** row absent (beyond 30-day window)

### RR6: v_dashboard_outstanding_balances

The system MUST provide `v_dashboard_outstanding_balances` with `security_invoker = true` returning `company_id`, `customer_id`, `customer_name` (from `customers.name`), `total_owed` (SUM of `customer_balances.total_amount` where status IN ('pending','partial')), `paid_amount` (SUM of `paid_amount`), `remaining_amount` (SUM of `remaining_amount`), `oldest_balance_date` (MIN `created_at` from active balances). The view MUST group by customer, showing only customers with non-zero `remaining_amount`.

- **GIVEN** customer with 2 active balances: $100 (pending) and $200 (partial, $50 paid) → **WHEN** querying → **THEN** `total_owed = 300`, `paid_amount = 50`, `remaining_amount = 250`
- **GIVEN** customer with all balances `status = 'paid'` → **WHEN** querying → **THEN** row absent (no outstanding balance)

### RR7: v_dashboard_sales_by_branch

The system MUST provide `v_dashboard_sales_by_branch` with `security_invoker = true` returning `company_id`, `branch_id`, `today_total`, `week_total`, `month_total` (all NUMERIC). Each total aggregates non-cancelled sales for the respective time window. Branches with no sales in a window return `0` (not NULL) via `COALESCE`.

- **GIVEN** branch B1 with $500 today, $3000 this week, $12000 this month → **WHEN** querying → **THEN** `today_total = 500`, `week_total = 3000`, `month_total = 12000`
- **GIVEN** branch B2 with no sales today → **WHEN** querying → **THEN** `today_total = 0` (COALESCE)

### RR8: v_report_sales_by_day

The system MUST provide `v_report_sales_by_day` with `security_invoker = true` returning `company_id`, `branch_id`, `sale_date` (DATE), `total_sales` (NUMERIC), `sales_count` (BIGINT), `avg_ticket` (NUMERIC computed as `total_sales / sales_count`). The view MUST aggregate non-cancelled sales by `date(created_at)`. RLS enforces company and branch isolation.

- **GIVEN** company A with 5 sales on 2026-06-15 totalling $750 → **WHEN** querying with `WHERE sale_date = '2026-06-15'` → **THEN** `total_sales = 750`, `sales_count = 5`, `avg_ticket = 150`
- **GIVEN** no sales on a specific date → **WHEN** querying → **THEN** no row for that date

### RR9: v_report_sales_by_week

The system MUST provide `v_report_sales_by_week` with `security_invoker = true` returning `company_id`, `branch_id`, `week_start` (DATE, Monday of the ISO week), `total_sales`, `sales_count`, `avg_ticket`. The view MUST use `date_trunc('week', created_at)` to group non-cancelled sales by ISO week.

- **GIVEN** sales across Mon–Sun in one ISO week → **WHEN** querying → **THEN** single row with `week_start` = Monday date
- **GIVEN** sales across two ISO weeks → **WHEN** querying → **THEN** two rows, one per week

### RR10: v_report_sales_by_month

The system MUST provide `v_report_sales_by_month` with `security_invoker = true` returning `company_id`, `branch_id`, `month_start` (DATE, first day of month), `total_sales`, `sales_count`, `avg_ticket`. The view MUST use `date_trunc('month', created_at)` to group non-cancelled sales by calendar month.

- **GIVEN** sales in June 2026 → **WHEN** querying → **THEN** row with `month_start = 2026-06-01`
- **GIVEN** sales across June and July → **WHEN** querying → **THEN** two rows

### RR11: v_report_current_inventory

The system MUST provide `v_report_current_inventory` with `security_invoker = true` returning `company_id`, `branch_id`, `variant_id`, `variant_name` (from `product_variants`), `sku`, `lot_code`, `lot_status` (from `stock_lots.status`), `remaining_qty`, `cost_per_unit`, `estimated_value` (NUMERIC computed as `remaining_qty * cost_per_unit`). The view MUST show all active lots (including near-depletion) with non-zero `remaining_qty`.

- **GIVEN** active lot with `remaining_qty = 10`, `cost_per_unit = 5.00` → **WHEN** querying → **THEN** `estimated_value = 50.00`
- **GIVEN** depleted lot with `remaining_qty = 0` → **WHEN** querying → **THEN** row absent (excluded)
- **GIVEN** lot with `remaining_qty = 0` and `status = 'active'` → **WHEN** querying → **THEN** row absent (zero remaining)

### RR12: v_report_low_stock

The system MUST provide `v_report_low_stock` with `security_invoker = true` returning `company_id`, `branch_id`, `variant_id`, `variant_name`, `sku`, `available_qty`, `reorder_threshold`, `below_threshold_by`. Unlike RR4 (dashboard subset), this view MUST show ALL variants with `reorder_threshold IS NOT NULL`, regardless of whether they are below threshold (providing a full reorder point report).

- **GIVEN** variant with `available_qty = 10`, `reorder_threshold = 5` → **WHEN** querying → **THEN** row present with `below_threshold_by = -5` (above threshold, negative)
- **GIVEN** variant with `reorder_threshold = NULL` → **WHEN** querying → **THEN** row absent (no threshold defined)

### RR13: v_report_expiration

The system MUST provide `v_report_expiration` with `security_invoker = true` returning `company_id`, `branch_id`, `lot_id`, `variant_id`, `lot_code`, `expiration_date`, `remaining_qty`, `days_until_expiry`, `status` (TEXT: 'expired' if `days_until_expiry < 0`, 'critical' if 0–7, 'warning' if 8–30, 'ok' if >30, 'no_date' if NULL). The view MUST show ALL active lots regardless of expiration proximity (full report, not filtered to 30-day window like RR5).

- **GIVEN** lot expiring in 3 days → **WHEN** querying → **THEN** `status = 'critical'`, `days_until_expiry = 3`
- **GIVEN** lot already expired → **WHEN** querying → **THEN** `status = 'expired'`, `days_until_expiry` negative
- **GIVEN** lot with NULL expiration → **WHEN** querying → **THEN** `status = 'no_date'`, `days_until_expiry = NULL`

### RR14: v_report_customer_balances

The system MUST provide `v_report_customer_balances` with `security_invoker = true` returning `company_id`, `customer_id`, `customer_name`, `total_owed` (SUM of `total_amount`), `paid_amount`, `remaining`, `balance_count` (count of active balances), `oldest_balance` (TIMESTAMPTZ of earliest `created_at` from active balances). Unlike RR6 (dashboard summary), this view MUST show ALL customers who have EVER had credit (any status), including fully paid.

- **GIVEN** customer with 1 paid balance ($100 total, $100 paid) and 1 pending ($50 total, $0 paid) → **WHEN** querying → **THEN** `total_owed = 150`, `paid_amount = 100`, `remaining = 50`, `balance_count = 2`
- **GIVEN** customer with all balances paid → **WHEN** querying → **THEN** row present showing `remaining = 0`

### RR15: v_report_payments_received

The system MUST provide `v_report_payments_received` with `security_invoker = true` returning `company_id`, `date` (DATE), `payment_method` (TEXT), `total_amount` (NUMERIC), `payment_count` (BIGINT). The view MUST aggregate `customer_payments` by date and payment_method. RLS enforces company isolation.

- **GIVEN** 3 payments on 2026-06-20: 2 cash ($50, $30) and 1 card ($100) → **WHEN** querying → **THEN** two rows: `(date=2026-06-20, payment_method=cash, total_amount=80, payment_count=2)` and `(date=2026-06-20, payment_method=card, total_amount=100, payment_count=1)`
- **GIVEN** no payments on a date → **WHEN** querying → **THEN** no row for that date

### RR16: fn_report_sales_by_cashier

The system MUST provide `fn_report_sales_by_cashier(company_id UUID, date_from DATE, date_to DATE)` as a SECURITY DEFINER RPC with `SET search_path = public`. The RPC MUST return JSONB rows with `cashier_user_id`, `cashier_name` (from `auth.users` or `company_users`), `total_sales`, `sale_count`, `avg_ticket` for non-cancelled sales grouped by cashier within the date range. The RPC MUST validate that the caller's `company_id` matches the parameter `company_id`, rejecting cross-tenant requests.

- **GIVEN** admin for company A calling with valid date range → **WHEN** RPC executes → **THEN** returns cashier-grouped sales aggregations for company A within date range
- **GIVEN** caller for company A → **WHEN** passing `company_id` for company B → **THEN** RPC rejects with cross-tenant validation error
- **GIVEN** date range with no sales → **WHEN** RPC executes → **THEN** returns empty result set

### RR17: fn_report_cash_cut

The system MUST provide `fn_report_cash_cut(company_id UUID, cash_session_id UUID)` as a SECURITY DEFINER RPC with `SET search_path = public`. The RPC MUST return JSONB with: session details (`cashier_user_id`, `branch_id`, `opened_at`, `closed_at`, `opening_amount`, `expected_cash_amount`, `counted_cash_amount`, `difference_amount`), payment totals grouped by `payment_method` from `payments` linked to sales in the session, cash movements grouped by `movement_type` from `cash_movements` linked to the session, and the computed difference. The calculation logic MUST match `close_cash_session` difference computation exactly.

- **GIVEN** closed session S1 with 5 cash payments totalling $500 and 3 card payments totalling $300 → **WHEN** RPC called → **THEN** returns session details, payment breakdown by method, cash movement summary, and difference
- **GIVEN** caller for company A → **WHEN** passing `cash_session_id` belonging to company B → **THEN** RPC rejects (cross-tenant)
- **GIVEN** open session (not yet closed) → **WHEN** RPC called → **THEN** returns partial data with `closed_at = NULL`, `counted_cash_amount = NULL`, `difference_amount = NULL`

### RR18: fn_report_purchases_by_supplier

The system MUST provide `fn_report_purchases_by_supplier(company_id UUID, date_from DATE, date_to DATE)` as a SECURITY DEFINER RPC with `SET search_path = public`. The RPC MUST return JSONB rows with `supplier_id`, `supplier_name` (from `suppliers`), `total_purchases` (SUM of `purchase_orders.total`), `order_count` (COUNT) for non-cancelled POs within the date range. The RPC MUST validate caller's `company_id`.

- **GIVEN** company A with 3 non-cancelled POs from supplier X totalling $5000 → **WHEN** RPC called with date range covering those POs → **THEN** row for supplier X with `total_purchases = 5000`, `order_count = 3`
- **GIVEN** date range with no non-cancelled POs → **WHEN** RPC called → **THEN** empty result set

### RR19: fn_purchase_suggestions

The system MUST provide `fn_purchase_suggestions(company_id UUID, branch_id UUID DEFAULT NULL)` as a SECURITY DEFINER RPC with `SET search_path = public`. The RPC MUST return JSONB rows with `variant_id`, `variant_name`, `current_stock` (from `v_stock_available`), `avg_daily_sales` (NUMERIC: total sold / days in window over last 30 days), `days_until_stockout` (INTEGER: `current_stock / avg_daily_sales`; NULL if no sales), `suggested_qty` (NUMERIC: `GREATEST(pending_requests, avg_daily_sales * 7) - current_stock`; floored at 0). Priority scoring uses CTEs: weight 4 for pending `customer_requests`, weight 3 for sales velocity, weight 2 for low stock (below threshold), weight 1 for sold-out (0 stock with recent sales). If `branch_id` provided, suggestions scoped to that branch; if NULL, scoped to all branches in the company.

- **GIVEN** variant with 20 pending customer requests, 0 stock, and 5 avg daily sales → **WHEN** RPC called → **THEN** `suggested_qty = max(20, 35) - 0 = 35`, high priority score
- **GIVEN** variant with 10 units in stock, 2 avg daily sales, no pending requests, `reorder_threshold = 15` → **WHEN** RPC called → **THEN** `suggested_qty = max(0, 14) - 10 = 4`, `days_until_stockout = 5`
- **GIVEN** variant with no sales history and no pending requests → **WHEN** RPC called → **THEN** `avg_daily_sales = 0`, `days_until_stockout = NULL`, `suggested_qty = 0` (not suggested)

### RR20: fn_export_entities

The system MUST provide `fn_export_entities(company_id UUID, entity_name TEXT, format TEXT, filters JSONB DEFAULT '{}'::JSONB)` as a SECURITY DEFINER RPC with `SET search_path = public`. The RPC MUST support entity names: `products`, `inventory`, `sales`, `customers`, `purchases`, `credits`. For `format = 'json'`, return JSONB. For `format = 'csv'`, return TEXT with CSV-formatted output (header row + data rows). The `filters` JSONB MUST accept optional `date_from`, `date_to`, `branch_id`, `status`, and `supplier_id` keys applicable per entity. The RPC MUST validate caller's `company_id` and reject unknown `entity_name` values.

- **GIVEN** admin for company A → **WHEN** calling with `entity_name = 'sales'`, `format = 'csv'`, `filters = '{"date_from": "2026-06-01"}'` → **THEN** returns TEXT with CSV header + data rows for company A sales since that date
- **GIVEN** admin for company A → **WHEN** calling with `entity_name = 'inventory'`, `format = 'json'` → **THEN** returns JSONB array of inventory rows for company A
- **GIVEN** unknown `entity_name = 'foo'` → **WHEN** RPC called → **THEN** returns error "unknown entity"
- **GIVEN** caller for company A → **WHEN** passing `company_id` for company B → **THEN** RPC rejects

### RR21: product_variants.reorder_threshold

The system MUST add a `reorder_threshold NUMERIC(12,2)` nullable column to `product_variants`. NULL means "use company-level default threshold" (company default to be configured in a future domain). The column MUST be added via migration 00012 as `ALTER TABLE product_variants ADD COLUMN IF NOT EXISTS reorder_threshold NUMERIC(12,2)`. No default value — NULL preserves backward compatibility with existing rows. Existing `product_variants` rows retain NULL for `reorder_threshold`.

- **GIVEN** migration 00012 applied → **WHEN** inspecting `product_variants` → **THEN** `reorder_threshold` column exists as NUMERIC(12,2), nullable
- **GIVEN** existing variant rows before migration → **WHEN** queried after migration → **THEN** `reorder_threshold = NULL` for all pre-existing rows
- **GIVEN** admin → **WHEN** setting `reorder_threshold = 5.00` on a variant → **THEN** variant now has threshold;.dashboard low-stock view includes it

### RR22: Performance Indexes

The system MUST create the following composite indexes in migration 00012 to support dashboard and report query performance: `sales(company_id, created_at)`, `sales(company_id, branch_id, created_at)`, `sales(company_id, cashier_user_id, created_at)`, `sale_items(company_id, variant_id)`, `payments(company_id, payment_method, created_at)`, `stock_lots(company_id, branch_id, status, remaining_qty)`, `stock_lots(company_id, expiration_date)`. All indexes MUST use `IF NOT EXISTS` for idempotency. Views and RPCs in this domain MUST reference these indexed columns in WHERE/JOIN clauses to ensure optimal query plans.

- **GIVEN** migration 00012 applied → **WHEN** `EXPLAIN` analyzing dashboard views → **THEN** index scans on `(company_id, created_at)` used for time-range queries
- **GIVEN** `supabase db reset` → **WHEN** re-applied → **THEN** no duplicate index errors (IF NOT EXISTS guard)

---

## ADDED Requirements (inventory-domain modification)

### RR23: reorder_threshold Column Addition to product_variants

<!-- cross-reference: RR21; inventory-domain spec RI2, RI7 -->

Migration 00012 MUST add `reorder_threshold NUMERIC(12,2)` nullable to `product_variants`. This modifies the inventory-domain schema. The column MUST NOT alter existing `v_stock_available` or `v_stock_expiring` view definitions — those views remain unchanged. The new column is consumed by `v_dashboard_low_stock` (RR4) and `v_report_low_stock` (RR12) via JOIN to `product_variants`. If a future domain establishes a company-level default threshold, `reorder_threshold = NULL` variants will fall back to that default; for V1, NULL variants are excluded from low-stock threshold checks (RR4 shows only variants where threshold IS NOT NULL, plus zero-stock variants regardless of threshold).

- **GIVEN** `v_stock_available` queried → **WHEN** after migration 00012 → **THEN** view definition unchanged; no reference to `reorder_threshold`
- **GIVEN** variant with `reorder_threshold = NULL` and `available_qty > 0` → **WHEN** querying `v_dashboard_low_stock` → **THEN** row absent (NULL threshold excluded unless zero stock)

---

## ADDED Requirements (project-architecture modification)

### RR24: R11 Decision #3 — Excel Export Scope

<!-- source: project-architecture spec R11 -->

Resolves open decision #3 in project-architecture R11. V1 delivers CSV export only (via `fn_export_entities` returning TEXT/JSONB and Edge Function streaming CSV). Excel (.xlsx) export is deferred to V1.5 due to Edge Function size limits (no lightweight xlsx library for Deno Deploy) and the Supabase-only architecture constraint (R1). CSV importable by Excel satisfies MVP requirements. The decision record: **CSV-only V1, xlsx deferred V1.5**.

- **GIVEN** V1 → **WHEN** user requests export → **THEN** only CSV and JSON formats available; no .xlsx endpoint
- **GIVEN** V1.5 → **WHEN** xlsx implementation planned → **THEN** Archimate with Edge Function + xlsx library; `fn_export_entities` already returns JSONB (reusable)

---

## Edge Functions (deferred to PR4)

### RR25: CSV Export Edge Function

<!-- source: proposal.md §CSV Export, §PR Boundary Breakdown PR4 -->

The Edge Function `/functions/export-csv/index.ts` MUST receive export requests (entity_name, format, filters), authenticate the user, validate company access, call `fn_export_entities` with validated parameters, and stream the CSV response with `Content-Disposition: attachment; filename="{entity_name}_{date}.csv"` header. This requirement is spec'd here for completeness but implementation is deferred to PR4 per the proposal's PR boundary breakdown.

- **GIVEN** authenticated admin → **WHEN** POST to export-csv EF with valid entity and format → **THEN** CSV streamed with correct headers
- **GIVEN** unauthenticated request → **WHEN** POST to export-csv EF → **THEN** rejected at step 1

---

## Design Decisions

### DR1: SQL Views + RPC Functions (per exploration recommendation)

Dashboard metrics use `CREATE VIEW` with `security_invoker = true` and `CURRENT_DATE` filters for real-time data. Parameterized reports use `SECURITY DEFINER` RPCs returning JSONB. This follows the established project pattern (views + RPCs) and the exploration's Approach 1 recommendation.

### DR2: CSV-Only V1 (resolves R11 #3)

Excel export deferred to V1.5. CSV importable by Excel satisfies MVP. The Deno Edge Function size limit makes xlsx library inclusion impractical for V1. Resolved in favor of CSV-only V1 per proposal §Out of Scope and exploration §Export Strategy.

### DR3: Live Views (no materialized views in V1)

All dashboard views are live (non-materialized). For MVP data volumes (projected < 100K sales in first year), live views with composite indexes are sufficient. Materialized views + pg_cron refresh deferred to V1.5/V2 when data volume demands it. Live views guarantee real-time metrics — critical for POS dashboard ("today's sales" must be real-time).

### DR4: Reorder Threshold Column (per exploration recommendation)

`product_variants.reorder_threshold` (nullable NUMERIC) is the proper domain model for per-variant low-stock thresholds. NULL means "use company default" (to be configured in a future domain). This is superior to a hardcoded constant and supports `v_dashboard_low_stock` and `v_report_low_stock` filtering.

### DR5: No Report Caching (V1)

No caching layer in V1. Instrument first, optimize later. If performance becomes an issue, Edge Function-level caching (< 2 min stale) MAY be added in V1.5.

### DR6: Single View Set with RLS Role Filtering

No separate cashier-specific dashboard views. RLS policies on views handle role filtering: cashier sees own-branch data, admin sees company-wide data. This is consistent with project-architecture R3.

---

## Non-Goals

- Excel (.xlsx) export → V1.5 (Edge Function size + Deno Deploy constraint)
- Materialized views → V1.5/V2 (live views sufficient for MVP data volumes)
- pg_cron extension → deferred with materialized views
- Report caching → V1.5 (instrument first, optimize later)
- Chart rendering or visualization logic → frontend concern
- Email/scheduled report delivery → V2
- Cashier-specific dashboard views (single view set, RLS handles role filtering)
- Frontend composable/hook implementations → frontend domain
- Dashboard real-time subscriptions (Supabase Realtime) → future consideration
- Data archival / partitioning strategies → V2

---

## Open Decisions

| # | Decision | Status | Notes |
|---|----------|--------|-------|
| 1 | Company-level default reorder threshold value | Deferred to future domain | V1 uses NULL = "no threshold"; future company-settings domain MAY define a default |
| 2 | `fn_export_entities` CSV column ordering | Implementation detail | Column order MAY follow table column order or be configurable via filters; spec does not mandate |
| 3 | RPC return format: JSONB rows vs JSON array | Implementation detail | JSONB rows (SETOF JSONB) preferred for cursor compatibility; single JSON array alternative acceptable |
| 4 | Near-expiration default window (30 days) | Fixed at 30 for V1 | `v_dashboard_near_expiration` uses 30-day default; `fn_report_near_expiration` (from exploration, listed in proposal) allows parameterized threshold — omitted from this spec's V1 scope if not in the 22-item task list; if needed, MUST be added as an RPC |

---

## Cross-Domain Touchpoints

| Source | Target Domain | Touchpoint |
|--------|--------------|------------|
| `v_dashboard_low_stock`, `v_report_low_stock` | Inventory | JOINs `product_variants.reorder_threshold` (new column RR21) and `v_stock_available` |
| `v_dashboard_near_expiration`, `v_report_expiration` | Inventory | Queries `stock_lots` (expiration_date, remaining_qty, status) |
| `v_dashboard_sales_today/week/month`, `v_report_sales_by_*` | POS Sales | Queries `sales` (total, status, created_at) and `payments` (payment_method, amount) |
| `v_dashboard_sales_by_branch` | POS Sales + Bootstrap | Queries `sales` and `branches` |
| `v_dashboard_outstanding_balances`, `v_report_customer_balances` | Credit Payments | Queries `customer_balances` and `customers` |
| `v_report_payments_received` | Credit Payments | Queries `customer_payments` |
| `fn_report_cash_cut` | Cash Session | Queries `cash_sessions` and `cash_movements` |
| `fn_report_purchases_by_supplier` | Purchasing | Queries `purchase_orders` and `suppliers` |
| `fn_purchase_suggestions` | Customers-Demand + Inventory + POS Sales | Queries `customer_requests`, `v_stock_available`, `sale_items`, `product_variants` |
| `fn_report_sales_by_cashier` | POS Sales | Queries `sales` and `company_users` / `auth.users` |
| `reorder_threshold` column | Inventory | ALTER TABLE `product_variants` (modifies inventory-domain schema) |
| Performance indexes | POS Sales, Inventory | Creates indexes on `sales`, `sale_items`, `payments`, `stock_lots` |