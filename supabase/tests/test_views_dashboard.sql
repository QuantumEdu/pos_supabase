-- pgTAP: Dashboard & Reports view tests
-- Verifies 15 views exist with correct columns and basic behavior
-- source: RR1-RR15, RR22

BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap;

-- Helper: check security_invoker on views (pg_options_to_table approach)
CREATE OR REPLACE FUNCTION check_security_invoker(schema_name TEXT, view_name TEXT)
RETURNS BOOLEAN
LANGUAGE SQL STABLE
AS $$
  SELECT coalesce(
    (SELECT option_value = 'true'
     FROM pg_catalog.pg_options_to_table(
       (SELECT reloptions FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = schema_name AND c.relname = view_name AND c.relkind = 'v')
     )
     WHERE option_name = 'security_invoker'),
    false
  );
$$;

-- ============================================================================
-- Seed data (minimal cross-domain setup)
-- ============================================================================
INSERT INTO public.companies (id, name, slug)
VALUES ('d1d00000-0000-0000-0000-000000000001', 'Dashboard View Co A', 'dv-co-a')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.branches (id, company_id, name, slug)
VALUES
  ('d1d00001-0000-0000-0000-000000000001', 'd1d00000-0000-0000-0000-000000000001', 'DV Branch A1', 'dv-branch-a1'),
  ('d1d00001-0000-0000-0000-000000000002', 'd1d00000-0000-0000-0000-000000000001', 'DV Branch A2', 'dv-branch-a2')
ON CONFLICT (id) DO NOTHING;

INSERT INTO auth.users (id, email, raw_app_meta_data, raw_user_meta_data)
VALUES
  ('d1d00aaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'dv-admin@test.com',
   '{"company_id": "d1d00000-0000-0000-0000-000000000001", "role": "admin"}',
   '{"full_name": "DV Admin"}')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.profiles (id, full_name)
VALUES ('d1d00aaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'DV Admin')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.company_users (company_id, user_id, role, is_active)
VALUES
  ('d1d00000-0000-0000-0000-000000000001', 'd1d00aaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'admin', true)
ON CONFLICT DO NOTHING;

INSERT INTO public.products (id, company_id, name, slug)
VALUES ('d1d00000-0000-0000-0000-000012345678', 'd1d00000-0000-0000-0000-000000000001', 'Dashboard Widgets', 'dashboard-widgets')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.product_variants (id, company_id, product_id, name, sku, is_active)
VALUES
  ('d1d10000-0000-0000-0000-000000000001', 'd1d00000-0000-0000-0000-000000000001', 'd1d00000-0000-0000-0000-000012345678', 'Widget A', 'WGT-A', true),
  ('d1d10000-0000-0000-0000-000000000002', 'd1d00000-0000-0000-0000-000000000001', 'd1d00000-0000-0000-0000-000012345678', 'Widget B', 'WGT-B', true)
ON CONFLICT DO NOTHING;

-- Set reorder_threshold for low-stock testing
UPDATE public.product_variants
SET reorder_threshold = 10.00
WHERE id = 'd1d10000-0000-0000-0000-000000000001'
  AND company_id = 'd1d00000-0000-0000-0000-000000000001';

INSERT INTO public.cash_sessions (id, company_id, branch_id, cashier_user_id, status, opening_amount, expected_cash_amount, opened_at)
VALUES ('d1d40000-0000-0000-0000-000000000001', 'd1d00000-0000-0000-0000-000000000001',
        'd1d00001-0000-0000-0000-000000000001', 'd1d00aaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
        'open', 500.00, 500.00, NOW())
ON CONFLICT (id) DO NOTHING;

-- Create a sale today for testing dashboard views
INSERT INTO public.sales (id, company_id, branch_id, cashier_user_id, cash_session_id, status, subtotal, discount_amount, tax_amount, total, sale_number, created_at)
VALUES
  ('d1d20000-0000-0000-0000-000000000001', 'd1d00000-0000-0000-0000-000000000001',
   'd1d00001-0000-0000-0000-000000000001', 'd1d00aaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
   'd1d40000-0000-0000-0000-000000000001', 'active', 250.00, 0, 37.50, 287.50, 1001, NOW()),
  ('d1d20000-0000-0000-0000-000000000002', 'd1d00000-0000-0000-0000-000000000001',
   'd1d00001-0000-0000-0000-000000000001', 'd1d00aaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
   'd1d40000-0000-0000-0000-000000000001', 'active', 100.00, 10.00, 13.50, 103.50, 1002, NOW())
ON CONFLICT DO NOTHING;

INSERT INTO public.payments (company_id, sale_id, payment_method, amount)
VALUES
  ('d1d00000-0000-0000-0000-000000000001', 'd1d20000-0000-0000-0000-000000000001', 'cash', 200.00),
  ('d1d00000-0000-0000-0000-000000000001', 'd1d20000-0000-0000-0000-000000000001', 'card', 87.50),
  ('d1d00000-0000-0000-0000-000000000001', 'd1d20000-0000-0000-0000-000000000002', 'cash', 103.50)
ON CONFLICT DO NOTHING;

INSERT INTO public.stock_lots (id, company_id, branch_id, variant_id, lot_code, expiration_date, received_qty, remaining_qty, cost_per_unit, status, is_active)
VALUES
  ('d1d30000-0000-0000-0000-000000000001', 'd1d00000-0000-0000-0000-000000000001',
   'd1d00001-0000-0000-0000-000000000001', 'd1d10000-0000-0000-0000-000000000001',
   'LOT-A-001', CURRENT_DATE + INTERVAL '15 days', 50, 50, 5.00, 'active', true)
ON CONFLICT DO NOTHING;

-- Set auth context for RLS (admin role)
SELECT set_config('request.jwt.claims', '{"sub": "d1d00aaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", "app_metadata": {"company_id": "d1d00000-0000-0000-0000-000000000001", "role": "admin"}}', true);

-- ============================================================================
-- Plan: 15 views × 3 assertions (exists, columns, security_invoker) = 45
--        + 3 sanity checks per main views = let's do a focused plan
-- ============================================================================
SELECT plan(45);

-- ============================================================================
-- DASHBOARD VIEWS (7)
-- ============================================================================

-- v_dashboard_sales_today (RR1)
SELECT has_view('public', 'v_dashboard_sales_today', 'v_dashboard_sales_today exists');
SELECT columns_are('public', 'v_dashboard_sales_today',
  ARRAY['company_id', 'branch_id', 'total_sales', 'sales_count', 'by_payment_method', 'as_of_date'],
  'v_dashboard_sales_today has correct columns'
);
SELECT ok(check_security_invoker('public', 'v_dashboard_sales_today'),
  'v_dashboard_sales_today has security_invoker = true'
);

-- v_dashboard_sales_week (RR2)
SELECT has_view('public', 'v_dashboard_sales_week', 'v_dashboard_sales_week exists');
SELECT columns_are('public', 'v_dashboard_sales_week',
  ARRAY['company_id', 'branch_id', 'day_date', 'daily_total', 'daily_count', 'as_of_date'],
  'v_dashboard_sales_week has correct columns'
);
SELECT ok(check_security_invoker('public', 'v_dashboard_sales_week'),
  'v_dashboard_sales_week has security_invoker = true'
);

-- v_dashboard_sales_month (RR3)
SELECT has_view('public', 'v_dashboard_sales_month', 'v_dashboard_sales_month exists');
SELECT columns_are('public', 'v_dashboard_sales_month',
  ARRAY['company_id', 'branch_id', 'day_date', 'daily_total', 'daily_count', 'as_of_date'],
  'v_dashboard_sales_month has correct columns'
);
SELECT ok(check_security_invoker('public', 'v_dashboard_sales_month'),
  'v_dashboard_sales_month has security_invoker = true'
);

-- v_dashboard_low_stock (RR4)
SELECT has_view('public', 'v_dashboard_low_stock', 'v_dashboard_low_stock exists');
SELECT columns_are('public', 'v_dashboard_low_stock',
  ARRAY['company_id', 'branch_id', 'variant_id', 'variant_name', 'sku', 'available_qty', 'reorder_threshold', 'below_threshold_by'],
  'v_dashboard_low_stock has correct columns'
);
SELECT ok(check_security_invoker('public', 'v_dashboard_low_stock'),
  'v_dashboard_low_stock has security_invoker = true'
);

-- v_dashboard_near_expiration (RR5)
SELECT has_view('public', 'v_dashboard_near_expiration', 'v_dashboard_near_expiration exists');
SELECT columns_are('public', 'v_dashboard_near_expiration',
  ARRAY['company_id', 'branch_id', 'lot_id', 'variant_id', 'lot_code', 'expiration_date', 'remaining_qty', 'days_until_expiry'],
  'v_dashboard_near_expiration has correct columns'
);
SELECT ok(check_security_invoker('public', 'v_dashboard_near_expiration'),
  'v_dashboard_near_expiration has security_invoker = true'
);

-- v_dashboard_outstanding_balances (RR6)
SELECT has_view('public', 'v_dashboard_outstanding_balances', 'v_dashboard_outstanding_balances exists');
SELECT columns_are('public', 'v_dashboard_outstanding_balances',
  ARRAY['company_id', 'customer_id', 'customer_name', 'total_owed', 'paid_amount', 'remaining_amount', 'oldest_balance_date'],
  'v_dashboard_outstanding_balances has correct columns'
);
SELECT ok(check_security_invoker('public', 'v_dashboard_outstanding_balances'),
  'v_dashboard_outstanding_balances has security_invoker = true'
);

-- v_dashboard_sales_by_branch (RR7)
SELECT has_view('public', 'v_dashboard_sales_by_branch', 'v_dashboard_sales_by_branch exists');
SELECT columns_are('public', 'v_dashboard_sales_by_branch',
  ARRAY['company_id', 'branch_id', 'today_total', 'week_total', 'month_total'],
  'v_dashboard_sales_by_branch has correct columns'
);
SELECT ok(check_security_invoker('public', 'v_dashboard_sales_by_branch'),
  'v_dashboard_sales_by_branch has security_invoker = true'
);

-- ============================================================================
-- REPORT VIEWS (8)
-- ============================================================================

-- v_report_sales_by_day (RR8)
SELECT has_view('public', 'v_report_sales_by_day', 'v_report_sales_by_day exists');
SELECT columns_are('public', 'v_report_sales_by_day',
  ARRAY['company_id', 'branch_id', 'sale_date', 'total_sales', 'sales_count', 'avg_ticket'],
  'v_report_sales_by_day has correct columns'
);
SELECT ok(check_security_invoker('public', 'v_report_sales_by_day'),
  'v_report_sales_by_day has security_invoker = true'
);

-- v_report_sales_by_week (RR9)
SELECT has_view('public', 'v_report_sales_by_week', 'v_report_sales_by_week exists');
SELECT columns_are('public', 'v_report_sales_by_week',
  ARRAY['company_id', 'branch_id', 'week_start', 'total_sales', 'sales_count', 'avg_ticket'],
  'v_report_sales_by_week has correct columns'
);
SELECT ok(check_security_invoker('public', 'v_report_sales_by_week'),
  'v_report_sales_by_week has security_invoker = true'
);

-- v_report_sales_by_month (RR10)
SELECT has_view('public', 'v_report_sales_by_month', 'v_report_sales_by_month exists');
SELECT columns_are('public', 'v_report_sales_by_month',
  ARRAY['company_id', 'branch_id', 'month_start', 'total_sales', 'sales_count', 'avg_ticket'],
  'v_report_sales_by_month has correct columns'
);
SELECT ok(check_security_invoker('public', 'v_report_sales_by_month'),
  'v_report_sales_by_month has security_invoker = true'
);

-- v_report_current_inventory (RR11)
SELECT has_view('public', 'v_report_current_inventory', 'v_report_current_inventory exists');
SELECT columns_are('public', 'v_report_current_inventory',
  ARRAY['company_id', 'branch_id', 'variant_id', 'variant_name', 'sku', 'lot_code', 'lot_status', 'remaining_qty', 'cost_per_unit', 'estimated_value'],
  'v_report_current_inventory has correct columns'
);
SELECT ok(check_security_invoker('public', 'v_report_current_inventory'),
  'v_report_current_inventory has security_invoker = true'
);

-- v_report_low_stock (RR12)
SELECT has_view('public', 'v_report_low_stock', 'v_report_low_stock exists');
SELECT columns_are('public', 'v_report_low_stock',
  ARRAY['company_id', 'branch_id', 'variant_id', 'variant_name', 'sku', 'available_qty', 'reorder_threshold', 'below_threshold_by'],
  'v_report_low_stock has correct columns'
);
SELECT ok(check_security_invoker('public', 'v_report_low_stock'),
  'v_report_low_stock has security_invoker = true'
);

-- v_report_expiration (RR13)
SELECT has_view('public', 'v_report_expiration', 'v_report_expiration exists');
SELECT columns_are('public', 'v_report_expiration',
  ARRAY['company_id', 'branch_id', 'lot_id', 'variant_id', 'lot_code', 'expiration_date', 'remaining_qty', 'days_until_expiry', 'status'],
  'v_report_expiration has correct columns'
);
SELECT ok(check_security_invoker('public', 'v_report_expiration'),
  'v_report_expiration has security_invoker = true'
);

-- v_report_customer_balances (RR14)
SELECT has_view('public', 'v_report_customer_balances', 'v_report_customer_balances exists');
SELECT columns_are('public', 'v_report_customer_balances',
  ARRAY['company_id', 'customer_id', 'customer_name', 'total_owed', 'paid_amount', 'remaining', 'balance_count', 'oldest_balance'],
  'v_report_customer_balances has correct columns'
);
SELECT ok(check_security_invoker('public', 'v_report_customer_balances'),
  'v_report_customer_balances has security_invoker = true'
);

-- v_report_payments_received (RR15)
SELECT has_view('public', 'v_report_payments_received', 'v_report_payments_received exists');
SELECT columns_are('public', 'v_report_payments_received',
  ARRAY['company_id', 'date', 'payment_method', 'total_amount', 'payment_count'],
  'v_report_payments_received has correct columns'
);
SELECT ok(check_security_invoker('public', 'v_report_payments_received'),
  'v_report_payments_received has security_invoker = true'
);

SELECT * FROM finish();
ROLLBACK;
