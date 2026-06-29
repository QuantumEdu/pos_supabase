-- pgTAP: Cash session domain RLS tests
-- Verifies admin/cashier read scopes, anon zero rows, direct write denial,
-- and service_role bypass expectations.

BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap;

SELECT plan(12);

INSERT INTO public.companies (id, name, slug)
VALUES
  ('d1000000-0000-0000-0000-000000000001', 'Cash RLS Co A', 'cash-rls-co-a'),
  ('d2000000-0000-0000-0000-000000000002', 'Cash RLS Co B', 'cash-rls-co-b');

INSERT INTO public.branches (id, company_id, name, slug)
VALUES
  ('d1111111-1111-1111-1111-111111111111', 'd1000000-0000-0000-0000-000000000001', 'RLS Branch A1', 'rls-branch-a1'),
  ('d1222222-2222-2222-2222-222222222222', 'd1000000-0000-0000-0000-000000000001', 'RLS Branch A2', 'rls-branch-a2'),
  ('d2111111-1111-1111-1111-111111111111', 'd2000000-0000-0000-0000-000000000002', 'RLS Branch B1', 'rls-branch-b1');

INSERT INTO auth.users (id, email, raw_app_meta_data, raw_user_meta_data)
VALUES
  ('daaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'cash-rls-admin-a@test.com',
   '{"company_id": "d1000000-0000-0000-0000-000000000001", "role": "admin"}',
   '{"full_name": "Cash RLS Admin A"}'),
  ('dbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'cash-rls-cashier-a1@test.com',
   '{"company_id": "d1000000-0000-0000-0000-000000000001", "role": "cashier", "branch_id": "d1111111-1111-1111-1111-111111111111"}',
   '{"full_name": "Cash RLS Cashier A1"}'),
  ('dccccccc-cccc-cccc-cccc-cccccccccccc', 'cash-rls-cashier-a2@test.com',
   '{"company_id": "d1000000-0000-0000-0000-000000000001", "role": "cashier", "branch_id": "d1222222-2222-2222-2222-222222222222"}',
   '{"full_name": "Cash RLS Cashier A2"}'),
  ('dddddddd-dddd-dddd-dddd-dddddddddddd', 'cash-rls-admin-b@test.com',
   '{"company_id": "d2000000-0000-0000-0000-000000000002", "role": "admin"}',
   '{"full_name": "Cash RLS Admin B"}')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.profiles (id, full_name)
VALUES
  ('daaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'Cash RLS Admin A'),
  ('dbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'Cash RLS Cashier A1'),
  ('dccccccc-cccc-cccc-cccc-cccccccccccc', 'Cash RLS Cashier A2'),
  ('dddddddd-dddd-dddd-dddd-dddddddddddd', 'Cash RLS Admin B')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.company_users (user_id, company_id, role)
VALUES
  ('daaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'd1000000-0000-0000-0000-000000000001', 'admin'),
  ('dbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'd1000000-0000-0000-0000-000000000001', 'cashier'),
  ('dccccccc-cccc-cccc-cccc-cccccccccccc', 'd1000000-0000-0000-0000-000000000001', 'cashier'),
  ('dddddddd-dddd-dddd-dddd-dddddddddddd', 'd2000000-0000-0000-0000-000000000002', 'admin')
ON CONFLICT (user_id, company_id) DO NOTHING;

INSERT INTO public.branch_users (user_id, branch_id, company_id)
VALUES
  ('dbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'd1111111-1111-1111-1111-111111111111', 'd1000000-0000-0000-0000-000000000001'),
  ('dccccccc-cccc-cccc-cccc-cccccccccccc', 'd1222222-2222-2222-2222-222222222222', 'd1000000-0000-0000-0000-000000000001')
ON CONFLICT (user_id, branch_id) DO NOTHING;

INSERT INTO public.cash_sessions (
  id, company_id, branch_id, cashier_user_id, status, opening_amount, expected_cash_amount, created_by, updated_by
)
VALUES
  ('d3000000-0000-0000-0000-000000000001', 'd1000000-0000-0000-0000-000000000001', 'd1111111-1111-1111-1111-111111111111', 'dbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'open', 100.00, 100.00, 'daaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'daaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'),
  ('d3000000-0000-0000-0000-000000000002', 'd1000000-0000-0000-0000-000000000001', 'd1222222-2222-2222-2222-222222222222', 'dccccccc-cccc-cccc-cccc-cccccccccccc', 'open', 50.00, 50.00, 'daaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'daaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'),
  ('d3000000-0000-0000-0000-000000000003', 'd2000000-0000-0000-0000-000000000002', 'd2111111-1111-1111-1111-111111111111', 'dddddddd-dddd-dddd-dddd-dddddddddddd', 'open', 75.00, 75.00, 'dddddddd-dddd-dddd-dddd-dddddddddddd', 'dddddddd-dddd-dddd-dddd-dddddddddddd');

INSERT INTO public.cash_movements (
  id, company_id, branch_id, cash_session_id, movement_type, amount, reason, created_by, updated_by
)
VALUES
  ('d4000000-0000-0000-0000-000000000001', 'd1000000-0000-0000-0000-000000000001', 'd1111111-1111-1111-1111-111111111111', 'd3000000-0000-0000-0000-000000000001', 'opening_float', 100.00, 'opening A1', 'daaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'daaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'),
  ('d4000000-0000-0000-0000-000000000002', 'd1000000-0000-0000-0000-000000000001', 'd1222222-2222-2222-2222-222222222222', 'd3000000-0000-0000-0000-000000000002', 'opening_float', 50.00, 'opening A2', 'daaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'daaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'),
  ('d4000000-0000-0000-0000-000000000003', 'd2000000-0000-0000-0000-000000000002', 'd2111111-1111-1111-1111-111111111111', 'd3000000-0000-0000-0000-000000000003', 'opening_float', 75.00, 'opening B1', 'dddddddd-dddd-dddd-dddd-dddddddddddd', 'dddddddd-dddd-dddd-dddd-dddddddddddd');

CREATE OR REPLACE FUNCTION _set_cash_session_rls_context(p_company_id UUID, p_role TEXT, p_user_id UUID, p_branch_id UUID DEFAULT NULL)
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

CREATE OR REPLACE FUNCTION _reset_cash_session_rls_context()
RETURNS VOID AS $$
BEGIN
  RESET ROLE;
  PERFORM set_config('request.jwt.claims', '', true);
END;
$$ LANGUAGE plpgsql;

SELECT _set_cash_session_rls_context('d1000000-0000-0000-0000-000000000001', 'admin', 'daaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'::UUID);

SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.cash_sessions $$,
  ARRAY[2::bigint],
  'cash_sessions RLS: admin sees all own-company sessions'
);

SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.cash_movements $$,
  ARRAY[2::bigint],
  'cash_movements RLS: admin sees all own-company movements'
);

SELECT _reset_cash_session_rls_context();

SELECT _set_cash_session_rls_context(
  'd1000000-0000-0000-0000-000000000001',
  'cashier',
  'dbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'::UUID,
  'd1111111-1111-1111-1111-111111111111'::UUID
);

SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.cash_sessions $$,
  ARRAY[1::bigint],
  'cash_sessions RLS: cashier sees only own branch and own sessions'
);

SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.cash_movements $$,
  ARRAY[1::bigint],
  'cash_movements RLS: cashier sees only movements from visible own sessions'
);

SELECT _reset_cash_session_rls_context();

SET ROLE anon;

SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.cash_sessions $$,
  ARRAY[0::bigint],
  'cash_sessions RLS: anon sees zero rows'
);

SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.cash_movements $$,
  ARRAY[0::bigint],
  'cash_movements RLS: anon sees zero rows'
);

RESET ROLE;

SELECT _set_cash_session_rls_context('d1000000-0000-0000-0000-000000000001', 'admin', 'daaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'::UUID);

SELECT throws_ok(
  $$ INSERT INTO public.cash_sessions (company_id, branch_id, cashier_user_id, status, opening_amount, expected_cash_amount)
     VALUES ('d1000000-0000-0000-0000-000000000001', 'd1111111-1111-1111-1111-111111111111', 'dbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'open', 10.00, 10.00) $$,
  '42501',
  NULL,
  'cash_sessions RLS: authenticated admin cannot insert directly'
);

SELECT throws_ok(
  $$ UPDATE public.cash_sessions SET notes = 'edited directly' WHERE id = 'd3000000-0000-0000-0000-000000000001' $$,
  '42501',
  NULL,
  'cash_sessions RLS: authenticated admin cannot update directly'
);

SELECT throws_ok(
  $$ INSERT INTO public.cash_movements (company_id, branch_id, cash_session_id, movement_type, amount)
     VALUES ('d1000000-0000-0000-0000-000000000001', 'd1111111-1111-1111-1111-111111111111', 'd3000000-0000-0000-0000-000000000001', 'manual_cash_in', 5.00) $$,
  '42501',
  NULL,
  'cash_movements RLS: authenticated admin cannot insert directly'
);

SELECT throws_ok(
  $$ DELETE FROM public.cash_sessions WHERE id = 'd3000000-0000-0000-0000-000000000001' $$,
  '42501',
  NULL,
  'cash_sessions RLS: authenticated admin cannot delete directly'
);

SELECT _reset_cash_session_rls_context();

SET ROLE service_role;

SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.cash_sessions
     WHERE company_id IN ('d1000000-0000-0000-0000-000000000001', 'd2000000-0000-0000-0000-000000000002') $$,
  ARRAY[3::bigint],
  'cash_sessions RLS: service_role bypass sees all fixture rows'
);

SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.cash_movements
     WHERE company_id IN ('d1000000-0000-0000-0000-000000000001', 'd2000000-0000-0000-0000-000000000002') $$,
  ARRAY[3::bigint],
  'cash_movements RLS: service_role bypass sees all fixture rows'
);

RESET ROLE;

DROP FUNCTION _set_cash_session_rls_context(UUID, TEXT, UUID, UUID);
DROP FUNCTION _reset_cash_session_rls_context();

SELECT * FROM finish();
ROLLBACK;
