-- pgTAP: POS Sales domain RLS tests
-- Verifies RLS isolation: company-scoped reads, write denial,
-- admin/cashier/branch-user read access, anon zero-row access.

BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap;

SELECT plan(10);

-- Seed data
INSERT INTO public.companies (id, name, slug)
VALUES
  ('c1b00000-0000-0000-0000-000000000001', 'Sales RLS Co A', 'sales-rls-co-a'),
  ('c2b00000-0000-0000-0000-000000000002', 'Sales RLS Co B', 'sales-rls-co-b');

INSERT INTO public.branches (id, company_id, name, slug)
VALUES
  ('b1b00000-1111-1111-1111-111111111111', 'c1b00000-0000-0000-0000-000000000001', 'RLS Branch A1', 'rls-branch-a1'),
  ('b2b00000-2222-2222-2222-222222222222', 'c2b00000-0000-0000-0000-000000000002', 'RLS Branch B1', 'rls-branch-b1');

INSERT INTO auth.users (id, email, raw_app_meta_data, raw_user_meta_data)
VALUES
  ('ab1b0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'sales-rls-admin-a@test.com',
   '{"company_id": "c1b00000-0000-0000-0000-000000000001", "role": "admin"}',
   '{"full_name": "Sales RLS Admin A"}'),
  ('ac1b0000-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'sales-rls-cashier-a@test.com',
   '{"company_id": "c1b00000-0000-0000-0000-000000000001", "role": "cashier", "branch_id": "b1b00000-1111-1111-1111-111111111111"}',
   '{"full_name": "Sales RLS Cashier A"}'),
  ('ab2b0000-cccc-cccc-cccc-cccccccccccc', 'sales-rls-admin-b@test.com',
   '{"company_id": "c2b00000-0000-0000-0000-000000000002", "role": "admin"}',
   '{"full_name": "Sales RLS Admin B"}'),
  ('a0f00000-dddd-dddd-dddd-dddddddddddd', 'sales-rls-anon@test.com',
   '{}', '{}')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.profiles (id, full_name)
VALUES
  ('ab1b0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'Sales RLS Admin A'),
  ('ac1b0000-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'Sales RLS Cashier A'),
  ('ab2b0000-cccc-cccc-cccc-cccccccccccc', 'Sales RLS Admin B'),
  ('a0f00000-dddd-dddd-dddd-dddddddddddd', 'Sales RLS Anon')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.company_users (user_id, company_id, role)
VALUES
  ('ab1b0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'c1b00000-0000-0000-0000-000000000001', 'admin'),
  ('ac1b0000-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'c1b00000-0000-0000-0000-000000000001', 'cashier'),
  ('ab2b0000-cccc-cccc-cccc-cccccccccccc', 'c2b00000-0000-0000-0000-000000000002', 'admin')
ON CONFLICT (user_id, company_id) DO NOTHING;

INSERT INTO public.branch_users (user_id, branch_id, company_id)
VALUES
  ('ac1b0000-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'b1b00000-1111-1111-1111-111111111111', 'c1b00000-0000-0000-0000-000000000001')
ON CONFLICT (user_id, branch_id) DO NOTHING;

-- Open a cash session for cashier A
INSERT INTO public.cash_sessions (
  id, company_id, branch_id, cashier_user_id, status, opening_amount, expected_cash_amount, created_by
) VALUES (
  '0c1b0000-0000-0000-0000-000000000001',
  'c1b00000-0000-0000-0000-000000000001',
  'b1b00000-1111-1111-1111-111111111111',
  'ac1b0000-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
  'open', 100.00, 100.00,
  'ab1b0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
);

-- Open cash session for company B
INSERT INTO public.cash_sessions (
  id, company_id, branch_id, cashier_user_id, status, opening_amount, expected_cash_amount, created_by
) VALUES (
  '0c2b0000-0000-0000-0000-000000000002',
  'c2b00000-0000-0000-0000-000000000002',
  'b2b00000-2222-2222-2222-222222222222',
  'ab2b0000-cccc-cccc-cccc-cccccccccccc',
  'open', 200.00, 200.00,
  'ab2b0000-cccc-cccc-cccc-cccccccccccc'
);

-- Insert sales rows via service_role simulation
INSERT INTO public.sales (
  id, company_id, branch_id, cashier_user_id, cash_session_id, status,
  subtotal, total, sale_number
) VALUES (
  '1a1b0000-0000-0000-0000-000000000001',
  'c1b00000-0000-0000-0000-000000000001',
  'b1b00000-1111-1111-1111-111111111111',
  'ac1b0000-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
  '0c1b0000-0000-0000-0000-000000000001',
  'active', 100.00, 110.00, 2001
);

INSERT INTO public.sales (
  id, company_id, branch_id, cashier_user_id, cash_session_id, status,
  subtotal, total, sale_number
) VALUES (
  '1a2b0000-0000-0000-0000-000000000002',
  'c2b00000-0000-0000-0000-000000000002',
  'b2b00000-2222-2222-2222-222222222222',
  'ab2b0000-cccc-cccc-cccc-cccccccccccc',
  '0c2b0000-0000-0000-0000-000000000002',
  'active', 200.00, 220.00, 2002
);

-- ============================================================================
-- RLS context helpers (follows cash_session domain pattern)
-- ============================================================================

CREATE OR REPLACE FUNCTION _set_pos_sales_rls_context(p_company_id UUID, p_role TEXT, p_user_id UUID, p_branch_id UUID DEFAULT NULL)
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

CREATE OR REPLACE FUNCTION _reset_pos_sales_rls_context()
RETURNS VOID AS $$
BEGIN
  RESET ROLE;
  PERFORM set_config('request.jwt.claims', '', true);
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- Authenticated read scopes
-- ============================================================================

-- Admin A sees company A sales (1 row)
SELECT _set_pos_sales_rls_context('c1b00000-0000-0000-0000-000000000001', 'admin', 'ab1b0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.sales $$,
  ARRAY[1::bigint],
  'RLS: admin A sees only company A sales'
);
SELECT _reset_pos_sales_rls_context();

-- Admin B sees company B sales (1 row)
SELECT _set_pos_sales_rls_context('c2b00000-0000-0000-0000-000000000002', 'admin', 'ab2b0000-cccc-cccc-cccc-cccccccccccc');
SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.sales $$,
  ARRAY[1::bigint],
  'RLS: admin B sees only company B sales'
);
SELECT _reset_pos_sales_rls_context();

-- Cashier A sees own company sales (1 row)
SELECT _set_pos_sales_rls_context('c1b00000-0000-0000-0000-000000000001', 'cashier', 'ac1b0000-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'b1b00000-1111-1111-1111-111111111111');
SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.sales $$,
  ARRAY[1::bigint],
  'RLS: cashier A sees own company sales'
);
SELECT _reset_pos_sales_rls_context();

-- ============================================================================
-- Authenticated user with no company sees 0 sales
-- ============================================================================
SELECT _set_pos_sales_rls_context('00000000-0000-0000-0000-000000000000', 'anon', 'a0f00000-dddd-dddd-dddd-dddddddddddd');
SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.sales $$,
  ARRAY[0::bigint],
  'RLS: anon user sees 0 sales'
);
SELECT _reset_pos_sales_rls_context();

-- ============================================================================
-- Write denial for authenticated roles
-- ============================================================================
SELECT _set_pos_sales_rls_context('c1b00000-0000-0000-0000-000000000001', 'admin', 'ab1b0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
SELECT throws_ok(
  $$ INSERT INTO public.sales (
       company_id, branch_id, cashier_user_id, cash_session_id, status,
       subtotal, total, sale_number
     ) VALUES (
       'c1b00000-0000-0000-0000-000000000001',
       'b1b00000-1111-1111-1111-111111111111',
       'ac1b0000-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
       '0c1b0000-0000-0000-0000-000000000001',
       'active', 50.00, 50.00, 2003
     ) $$,
  NULL, NULL,
  'RLS: authenticated user cannot INSERT into sales'
);
SELECT _reset_pos_sales_rls_context();

-- ============================================================================
-- Anon role: zero rows on all tables
-- ============================================================================
SET ROLE anon;

SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.sales $$,
  ARRAY[0::bigint],
  'RLS: anon sees 0 sales'
);

SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.sale_items $$,
  ARRAY[0::bigint],
  'RLS: anon sees 0 sale_items'
);

SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.payments $$,
  ARRAY[0::bigint],
  'RLS: anon sees 0 payments'
);

SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.discount_authorizations $$,
  ARRAY[0::bigint],
  'RLS: anon sees 0 discount_authorizations'
);

SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.sale_item_batches $$,
  ARRAY[0::bigint],
  'RLS: anon sees 0 sale_item_batches'
);

RESET ROLE;

-- ============================================================================
-- Cleanup
-- ============================================================================
SELECT * FROM finish();
ROLLBACK;
