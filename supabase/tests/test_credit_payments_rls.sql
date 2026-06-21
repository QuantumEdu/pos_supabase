-- pgTAP: Credit Payments domain RLS tests
-- Verifies RLS isolation (RCP6): company-scoped SELECT for authenticated,
-- admin INSERT/UPDATE gated by is_admin(), cross-company invisibility, anon
-- zero rows, no DELETE (logical deletion only), and service_role bypass.
-- source: RCP6

BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap;

SELECT plan(10);

-- ============================================================================
-- Seed data: two companies, each with an admin, a customer, a sale, and a
-- balance. Plus an anon user with no company membership.
-- ============================================================================
INSERT INTO public.companies (id, name, slug)
VALUES
  ('c1f00000-0000-0000-0000-000000000001', 'Credit RLS Co A', 'credit-rls-co-a'),
  ('c2f00000-0000-0000-0000-000000000002', 'Credit RLS Co B', 'credit-rls-co-b');

INSERT INTO public.branches (id, company_id, name, slug)
VALUES
  ('b1f00000-1111-1111-1111-111111111111', 'c1f00000-0000-0000-0000-000000000001', 'RLS Branch A1', 'rls-branch-a1'),
  ('b2f00000-2222-2222-2222-222222222222', 'c2f00000-0000-0000-0000-000000000002', 'RLS Branch B1', 'rls-branch-b2');

INSERT INTO auth.users (id, email, raw_app_meta_data, raw_user_meta_data)
VALUES
  ('af1f0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'credit-rls-admin-a@test.com',
   '{"company_id": "c1f00000-0000-0000-0000-000000000001", "role": "admin"}',
   '{"full_name": "RLS Admin A"}'),
  ('af1f0000-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'credit-rls-cashier-a@test.com',
   '{"company_id": "c1f00000-0000-0000-0000-000000000001", "role": "cashier"}',
   '{"full_name": "RLS Cashier A"}'),
  ('af2f0000-cccc-cccc-cccc-cccccccccccc', 'credit-rls-admin-b@test.com',
   '{"company_id": "c2f00000-0000-0000-0000-000000000002", "role": "admin"}',
   '{"full_name": "RLS Admin B"}'),
  ('a0f00000-dddd-dddd-dddd-dddddddddddd', 'credit-rls-anon@test.com', '{}', '{}')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.profiles (id, full_name)
VALUES
  ('af1f0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'RLS Admin A'),
  ('af1f0000-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'RLS Cashier A'),
  ('af2f0000-cccc-cccc-cccc-cccccccccccc', 'RLS Admin B'),
  ('a0f00000-dddd-dddd-dddd-dddddddddddd', 'RLS Anon')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.company_users (user_id, company_id, role)
VALUES
  ('af1f0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'c1f00000-0000-0000-0000-000000000001', 'admin'),
  ('af1f0000-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'c1f00000-0000-0000-0000-000000000001', 'cashier'),
  ('af2f0000-cccc-cccc-cccc-cccccccccccc', 'c2f00000-0000-0000-0000-000000000002', 'admin')
ON CONFLICT (user_id, company_id) DO NOTHING;

INSERT INTO public.branch_users (user_id, branch_id, company_id)
VALUES
  ('af1f0000-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'b1f00000-1111-1111-1111-111111111111', 'c1f00000-0000-0000-0000-000000000001'),
  ('af2f0000-cccc-cccc-cccc-cccccccccccc', 'b2f00000-2222-2222-2222-222222222222', 'c2f00000-0000-0000-0000-000000000002')
ON CONFLICT (user_id, branch_id) DO NOTHING;

-- Customers (one per company)
INSERT INTO public.customers (id, company_id, name, slug, created_by)
VALUES
  ('0cf10000-0000-0000-0000-000000000001', 'c1f00000-0000-0000-0000-000000000001', 'RLS Customer A', 'rls-customer-a', 'af1f0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa'),
  ('0cf20000-0000-0000-0000-000000000002', 'c2f00000-0000-0000-0000-000000000002', 'RLS Customer B', 'rls-customer-b', 'af2f0000-cccc-cccc-cccc-cccccccccccc');

-- Cash sessions (one per company)
INSERT INTO public.cash_sessions (
  id, company_id, branch_id, cashier_user_id, status, opening_amount, expected_cash_amount, created_by, updated_by
) VALUES
  ('0cf10000-0000-0000-0000-000000000091', 'c1f00000-0000-0000-0000-000000000001', 'b1f00000-1111-1111-1111-111111111111', 'af1f0000-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'open', 100.00, 100.00, 'af1f0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'af1f0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa'),
  ('0cf20000-0000-0000-0000-000000000092', 'c2f00000-0000-0000-0000-000000000002', 'b2f00000-2222-2222-2222-222222222222', 'af2f0000-cccc-cccc-cccc-cccccccccccc', 'open', 200.00, 200.00, 'af2f0000-cccc-cccc-cccc-cccccccccccc', 'af2f0000-cccc-cccc-cccc-cccccccccccc');

-- Sales (one per company)
INSERT INTO public.sales (
  id, company_id, branch_id, cashier_user_id, cash_session_id, status,
  subtotal, total, sale_number, created_by, updated_by
) VALUES
  ('1af10000-0000-0000-0000-000000000001', 'c1f00000-0000-0000-0000-000000000001', 'b1f00000-1111-1111-1111-111111111111', 'af1f0000-bbbb-bbbb-bbbb-bbbbbbbbbbbb', '0cf10000-0000-0000-0000-000000000091', 'active', 100.00, 100.00, 8001, 'af1f0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'af1f0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa'),
  ('1af20000-0000-0000-0000-000000000002', 'c2f00000-0000-0000-0000-000000000002', 'b2f00000-2222-2222-2222-222222222222', 'af2f0000-cccc-cccc-cccc-cccccccccccc', '0cf20000-0000-0000-0000-000000000092', 'active', 200.00, 200.00, 8002, 'af2f0000-cccc-cccc-cccc-cccccccccccc', 'af2f0000-cccc-cccc-cccc-cccccccccccc');

-- Balances + payments (one set per company) — inserted as table owner/superuser
INSERT INTO public.customer_balances (
  id, company_id, sale_id, customer_id, total_amount, paid_amount, status, created_by, updated_by
) VALUES
  ('fbf10000-0000-0000-0000-000000000001', 'c1f00000-0000-0000-0000-000000000001', '1af10000-0000-0000-0000-000000000001', '0cf10000-0000-0000-0000-000000000001', 100.00, 0.00, 'pending', 'af1f0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'af1f0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa'),
  ('fbf20000-0000-0000-0000-000000000002', 'c2f00000-0000-0000-0000-000000000002', '1af20000-0000-0000-0000-000000000002', '0cf20000-0000-0000-0000-000000000002', 200.00, 0.00, 'pending', 'af2f0000-cccc-cccc-cccc-cccccccccccc', 'af2f0000-cccc-cccc-cccc-cccccccccccc');

INSERT INTO public.customer_payments (
  id, company_id, balance_id, amount, payment_method, created_by, updated_by
) VALUES
  ('faf10000-0000-0000-0000-000000000001', 'c1f00000-0000-0000-0000-000000000001', 'fbf10000-0000-0000-0000-000000000001', 30.00, 'cash', 'af1f0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'af1f0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa'),
  ('faf20000-0000-0000-0000-000000000002', 'c2f00000-0000-0000-0000-000000000002', 'fbf20000-0000-0000-0000-000000000002', 50.00, 'card', 'af2f0000-cccc-cccc-cccc-cccccccccccc', 'af2f0000-cccc-cccc-cccc-cccccccccccc');

-- ============================================================================
-- RLS context helpers
-- ============================================================================
CREATE OR REPLACE FUNCTION _set_credit_rls_context(p_company_id UUID, p_role TEXT, p_user_id UUID, p_branch_id UUID DEFAULT NULL)
RETURNS VOID AS $$
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object(
    'sub', p_user_id,
    'role', 'authenticated',
    'app_metadata', json_build_object(
      'company_id', p_company_id,
      'role', p_role,
      'branch_id', p_branch_id
    )
  )::text, true);
  SET ROLE authenticated;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION _reset_credit_rls_context()
RETURNS VOID AS $$
BEGIN
  RESET ROLE;
  PERFORM set_config('request.jwt.claims', '', true);
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- Company-scoped SELECT
-- ============================================================================
SELECT _set_credit_rls_context('c1f00000-0000-0000-0000-000000000001', 'admin', 'af1f0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.customer_balances $$,
  ARRAY[1::bigint],
  'RLS: admin A sees only company A balances'
);
SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.customer_payments $$,
  ARRAY[1::bigint],
  'RLS: admin A sees only company A payments'
);
SELECT _reset_credit_rls_context();

SELECT _set_credit_rls_context('c2f00000-0000-0000-0000-000000000002', 'admin', 'af2f0000-cccc-cccc-cccc-cccccccccccc');
SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.customer_balances $$,
  ARRAY[1::bigint],
  'RLS: admin B sees only company B balances (cross-company invisible)'
);
SELECT _reset_credit_rls_context();

SELECT _set_credit_rls_context('c1f00000-0000-0000-0000-000000000001', 'cashier', 'af1f0000-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'b1f00000-1111-1111-1111-111111111111');
SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.customer_balances $$,
  ARRAY[1::bigint],
  'RLS: cashier A sees own company balances (SELECT not admin-gated)'
);
SELECT _reset_credit_rls_context();

-- ============================================================================
-- Unauthenticated (anon) sees zero rows
-- ============================================================================
SET ROLE anon;
SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.customer_balances $$,
  ARRAY[0::bigint],
  'RLS: anon sees 0 customer_balances'
);
SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.customer_payments $$,
  ARRAY[0::bigint],
  'RLS: anon sees 0 customer_payments'
);
RESET ROLE;

-- ============================================================================
-- Admin INSERT succeeds (is_admin() policy + grant)
-- Use a distinct sale in company A so the balance does not collide on UNIQUE.
-- ============================================================================
INSERT INTO public.sales (
  id, company_id, branch_id, cashier_user_id, cash_session_id, status,
  subtotal, total, sale_number, created_by, updated_by
) VALUES (
  '1af10000-0000-0000-0000-000000000011', 'c1f00000-0000-0000-0000-000000000001', 'b1f00000-1111-1111-1111-111111111111', 'af1f0000-bbbb-bbbb-bbbb-bbbbbbbbbbbb', '0cf10000-0000-0000-0000-000000000091', 'active', 30.00, 30.00, 8011, 'af1f0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'af1f0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
);

SELECT _set_credit_rls_context('c1f00000-0000-0000-0000-000000000001', 'admin', 'af1f0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
SELECT lives_ok(
  $$ INSERT INTO public.customer_balances (
       company_id, sale_id, customer_id, total_amount, created_by, updated_by
     ) VALUES (
       'c1f00000-0000-0000-0000-000000000001',
       '1af10000-0000-0000-0000-000000000011',
       '0cf10000-0000-0000-0000-000000000001',
       30.00,
       'af1f0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
       'af1f0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
     ) $$,
  'RLS: admin authenticated can INSERT a balance (is_admin policy + grant)'
);
SELECT _reset_credit_rls_context();

-- ============================================================================
-- Non-admin (cashier) authenticated INSERT is denied (is_admin policy fails)
-- ============================================================================
INSERT INTO public.sales (
  id, company_id, branch_id, cashier_user_id, cash_session_id, status,
  subtotal, total, sale_number, created_by, updated_by
) VALUES (
  '1af10000-0000-0000-0000-000000000012', 'c1f00000-0000-0000-0000-000000000001', 'b1f00000-1111-1111-1111-111111111111', 'af1f0000-bbbb-bbbb-bbbb-bbbbbbbbbbbb', '0cf10000-0000-0000-0000-000000000091', 'active', 30.00, 30.00, 8012, 'af1f0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'af1f0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
);

SELECT _set_credit_rls_context('c1f00000-0000-0000-0000-000000000001', 'cashier', 'af1f0000-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'b1f00000-1111-1111-1111-111111111111');
SELECT throws_ok(
  $$ INSERT INTO public.customer_balances (
       company_id, sale_id, customer_id, total_amount, created_by, updated_by
     ) VALUES (
       'c1f00000-0000-0000-0000-000000000001',
       '1af10000-0000-0000-0000-000000000012',
       '0cf10000-0000-0000-0000-000000000001',
       30.00,
       'af1f0000-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
       'af1f0000-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
     ) $$,
  NULL, NULL,
  'RLS: non-admin authenticated INSERT is denied (is_admin policy fails)'
);
SELECT _reset_credit_rls_context();

-- ============================================================================
-- No DELETE (no DELETE grant; logical deletion only)
-- ============================================================================
SELECT _set_credit_rls_context('c1f00000-0000-0000-0000-000000000001', 'admin', 'af1f0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
SELECT throws_ok(
  $$ DELETE FROM public.customer_balances WHERE company_id = 'c1f00000-0000-0000-0000-000000000001' $$,
  NULL, NULL,
  'RLS: DELETE is denied (no DELETE grant; logical deletion only)'
);
SELECT _reset_credit_rls_context();

-- ============================================================================
-- service_role bypass: sees all rows across companies
-- ============================================================================
SET ROLE service_role;
SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.customer_balances $$,
  ARRAY[3::bigint],
  'RLS: service_role bypasses RLS (sees all 3 balances across companies)'
);
RESET ROLE;

-- ============================================================================
-- Cleanup
-- ============================================================================
SELECT * FROM finish();
ROLLBACK;