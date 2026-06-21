-- pgTAP: Returns domain RLS tests
-- Verifies RLS isolation (RR5):
--   - company-scoped SELECT for authenticated (admin all branches, cashier own branch)
--   - cross-company invisibility
--   - admin-only INSERT (is_admin policy + grant)
--   - non-admin INSERT denied
--   - admin-only UPDATE (status transition) allowed; non-admin UPDATE denied
--   - no DELETE (no DELETE grant/policy; logical deletion only)
--   - anon sees zero rows
--   - service_role bypasses RLS across companies
-- source: RR5, design D7

BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap;

SELECT plan(16);

-- ============================================================================
-- Seed: two companies, admin + cashier, branches, a customer-free sale, and a
-- pre-seeded return row in each company.
-- ============================================================================
INSERT INTO public.companies (id, name, slug)
VALUES
  ('c1900000-0000-0000-0000-000000000001', 'Returns RLS Co A', 'returns-rls-co-a'),
  ('c2900000-0000-0000-0000-000000000002', 'Returns RLS Co B', 'returns-rls-co-b');

INSERT INTO public.branches (id, company_id, name, slug)
VALUES
  ('b1900000-1111-1111-1111-111111111111', 'c1900000-0000-0000-0000-000000000001', 'RRLS Branch A1', 'rrls-branch-a1'),
  ('b1900000-2222-2222-2222-222222222222', 'c1900000-0000-0000-0000-000000000001', 'RRLS Branch A2', 'rrls-branch-a2'),
  ('b2900000-3333-3333-3333-333333333333', 'c2900000-0000-0000-0000-000000000002', 'RRLS Branch B1', 'rrls-branch-b1');

INSERT INTO auth.users (id, email, raw_app_meta_data, raw_user_meta_data)
VALUES
  ('a9190000-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'returns-rls-admin-a@test.com',
   '{"company_id": "c1900000-0000-0000-0000-000000000001", "role": "admin"}',
   '{"full_name": "RRLS Admin A"}'),
  ('a9190000-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'returns-rls-cashier-a@test.com',
   '{"company_id": "c1900000-0000-0000-0000-000000000001", "role": "cashier", "branch_id": "b1900000-1111-1111-1111-111111111111"}',
   '{"full_name": "RRLS Cashier A"}'),
  ('a9290000-cccc-cccc-cccc-cccccccccccc', 'returns-rls-admin-b@test.com',
   '{"company_id": "c2900000-0000-0000-0000-000000000002", "role": "admin"}',
   '{"full_name": "RRLS Admin B"}')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.profiles (id, full_name)
VALUES
  ('a9190000-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'RRLS Admin A'),
  ('a9190000-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'RRLS Cashier A'),
  ('a9290000-cccc-cccc-cccc-cccccccccccc', 'RRLS Admin B')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.company_users (user_id, company_id, role)
VALUES
  ('a9190000-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'c1900000-0000-0000-0000-000000000001', 'admin'),
  ('a9190000-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'c1900000-0000-0000-0000-000000000001', 'cashier'),
  ('a9290000-cccc-cccc-cccc-cccccccccccc', 'c2900000-0000-0000-0000-000000000002', 'admin')
ON CONFLICT (user_id, company_id) DO NOTHING;

INSERT INTO public.branch_users (user_id, branch_id, company_id)
VALUES
  ('a9190000-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'b1900000-1111-1111-1111-111111111111', 'c1900000-0000-0000-0000-000000000001')
ON CONFLICT (user_id, branch_id) DO NOTHING;

-- Product + variant + stock lot (FK targets for sale setup; minimal)
INSERT INTO public.products (id, company_id, name, slug, created_by)
VALUES
  ('dd910000-0000-0000-0000-000000000001', 'c1900000-0000-0000-0000-000000000001', 'RRLS Product A', 'rrls-product-a', 'a9190000-aaaa-aaaa-aaaa-aaaaaaaaaaaa'),
  ('dd920000-0000-0000-0000-000000000002', 'c2900000-0000-0000-0000-000000000002', 'RRLS Product B', 'rrls-product-b', 'a9290000-cccc-cccc-cccc-cccccccccccc');

INSERT INTO public.product_variants (id, company_id, product_id, name, sku, created_by)
VALUES
  ('dc910000-0000-0000-0000-000000000001', 'c1900000-0000-0000-0000-000000000001', 'dd910000-0000-0000-0000-000000000001', 'RRLS Var A', 'RRLS-VAR-A', 'a9190000-aaaa-aaaa-aaaa-aaaaaaaaaaaa'),
  ('dc920000-0000-0000-0000-000000000002', 'c2900000-0000-0000-0000-000000000002', 'dd920000-0000-0000-0000-000000000002', 'RRLS Var B', 'RRLS-VAR-B', 'a9290000-cccc-cccc-cccc-cccccccccccc');

INSERT INTO public.stock_lots (id, company_id, branch_id, variant_id, lot_code, received_qty, remaining_qty, created_by, updated_by) VALUES
  ('da910000-0000-0000-0000-000000000001', 'c1900000-0000-0000-0000-000000000001', 'b1900000-1111-1111-1111-111111111111', 'dc910000-0000-0000-0000-000000000001', 'LOT-A', 10, 10, 'a9190000-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'a9190000-aaaa-aaaa-aaaa-aaaaaaaaaaaa'),
  ('da920000-0000-0000-0000-000000000002', 'c2900000-0000-0000-0000-000000000002', 'b2900000-3333-3333-3333-333333333333', 'dc920000-0000-0000-0000-000000000002', 'LOT-B', 10, 10, 'a9290000-cccc-cccc-cccc-cccccccccccc', 'a9290000-cccc-cccc-cccc-cccccccccccc');

INSERT INTO public.cash_sessions (id, company_id, branch_id, cashier_user_id, status, opening_amount, expected_cash_amount, created_by, updated_by) VALUES
  ('0c910000-0000-0000-0000-000000000091', 'c1900000-0000-0000-0000-000000000001', 'b1900000-1111-1111-1111-111111111111', 'a9190000-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'open', 100.00, 100.00, 'a9190000-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'a9190000-aaaa-aaaa-aaaa-aaaaaaaaaaaa'),
  ('0c920000-0000-0000-0000-000000000092', 'c2900000-0000-0000-0000-000000000002', 'b2900000-3333-3333-3333-333333333333', 'a9290000-cccc-cccc-cccc-cccccccccccc', 'open', 200.00, 200.00, 'a9290000-cccc-cccc-cccc-cccccccccccc', 'a9290000-cccc-cccc-cccc-cccccccccccc');

-- Two sales per company (one in branch A1, a second in branch A2 for company A) for INSERT-isolation tests
INSERT INTO public.sales (id, company_id, branch_id, cashier_user_id, cash_session_id, status, subtotal, total, sale_number, created_by, updated_by) VALUES
  ('1a910000-0000-0000-0000-000000000001', 'c1900000-0000-0000-0000-000000000001', 'b1900000-1111-1111-1111-111111111111', 'a9190000-bbbb-bbbb-bbbb-bbbbbbbbbbbb', '0c910000-0000-0000-0000-000000000091', 'active', 30.00, 30.00, 9501, 'a9190000-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'a9190000-aaaa-aaaa-aaaa-aaaaaaaaaaaa'),
  ('1a910000-0000-0000-0000-000000000002', 'c1900000-0000-0000-0000-000000000001', 'b1900000-2222-2222-2222-222222222222', 'a9190000-bbbb-bbbb-bbbb-bbbbbbbbbbbb', '0c910000-0000-0000-0000-000000000091', 'active', 30.00, 30.00, 9502, 'a9190000-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'a9190000-aaaa-aaaa-aaaa-aaaaaaaaaaaa'),
  ('1a920000-0000-0000-0000-000000000003', 'c2900000-0000-0000-0000-000000000002', 'b2900000-3333-3333-3333-333333333333', 'a9290000-cccc-cccc-cccc-cccccccccccc', '0c920000-0000-0000-0000-000000000092', 'active', 60.00, 60.00, 9503, 'a9290000-cccc-cccc-cccc-cccccccccccc', 'a9290000-cccc-cccc-cccc-cccccccccccc');

INSERT INTO public.sale_items (id, company_id, sale_id, variant_id, quantity, unit_price, line_total, created_by, updated_by) VALUES
  ('1a910000-0000-0000-0000-0000000000a1', 'c1900000-0000-0000-0000-000000000001', '1a910000-0000-0000-0000-000000000001', 'dc910000-0000-0000-0000-000000000001', 3, 10.00, 30.00, 'a9190000-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'a9190000-aaaa-aaaa-aaaa-aaaaaaaaaaaa'),
  ('1a910000-0000-0000-0000-0000000000a2', 'c1900000-0000-0000-0000-000000000001', '1a910000-0000-0000-0000-000000000002', 'dc910000-0000-0000-0000-000000000001', 3, 10.00, 30.00, 'a9190000-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'a9190000-aaaa-aaaa-aaaa-aaaaaaaaaaaa'),
  ('1a920000-0000-0000-0000-0000000000a3', 'c2900000-0000-0000-0000-000000000002', '1a920000-0000-0000-0000-000000000003', 'dc920000-0000-0000-0000-000000000002', 6, 10.00, 60.00, 'a9290000-cccc-cccc-cccc-cccccccccccc', 'a9290000-cccc-cccc-cccc-cccccccccccc');

-- Pre-seed one return header per company (as table owner / superuser) for SELECT tests.
-- Insert minimal return_item + return_item_batch in company A so the redirect subquery
-- in the return_items SELECT policy resolves.
INSERT INTO public.returns (id, company_id, branch_id, sale_id, type, status, total_amount, authorized_by, created_by, updated_by) VALUES
  ('fb910000-0000-0000-0000-000000000001', 'c1900000-0000-0000-0000-000000000001', 'b1900000-1111-1111-1111-111111111111', '1a910000-0000-0000-0000-000000000001', 'partial', 'pending', 0, 'a9190000-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'a9190000-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'a9190000-aaaa-aaaa-aaaa-aaaaaaaaaaaa'),
  ('fb920000-0000-0000-0000-000000000002', 'c2900000-0000-0000-0000-000000000002', 'b2900000-3333-3333-3333-333333333333', '1a920000-0000-0000-0000-000000000003', 'partial', 'pending', 0, 'a9290000-cccc-cccc-cccc-cccccccccccc', 'a9290000-cccc-cccc-cccc-cccccccccccc', 'a9290000-cccc-cccc-cccc-cccccccccccc');

-- sale_item_batches must exist BEFORE return_item_batches (composite FK on original_batch_id)
INSERT INTO public.sale_item_batches (id, company_id, sale_item_id, lot_id, quantity, created_by, updated_by) VALUES
  ('1a910000-0000-0000-0000-0000000000b1', 'c1900000-0000-0000-0000-000000000001', '1a910000-0000-0000-0000-0000000000a1', 'da910000-0000-0000-0000-000000000001', 3, 'a9190000-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'a9190000-aaaa-aaaa-aaaa-aaaaaaaaaaaa');

INSERT INTO public.return_items (id, company_id, return_id, sale_item_id, variant_id, qty, destination, unit_price, subtotal, created_by, updated_by) VALUES
  ('fb910000-0000-0000-0000-0000000000e1', 'c1900000-0000-0000-0000-000000000001', 'fb910000-0000-0000-0000-000000000001', '1a910000-0000-0000-0000-0000000000a1', 'dc910000-0000-0000-0000-000000000001', 1, 'inventario', 10.00, 10.00, 'a9190000-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'a9190000-aaaa-aaaa-aaaa-aaaaaaaaaaaa');

INSERT INTO public.return_item_batches (id, company_id, return_item_id, original_batch_id, variant_id, qty, created_by, updated_by) VALUES
  ('fb910000-0000-0000-0000-0000000000d1', 'c1900000-0000-0000-0000-000000000001', 'fb910000-0000-0000-0000-0000000000e1', '1a910000-0000-0000-0000-0000000000b1', 'dc910000-0000-0000-0000-000000000001', 1, 'a9190000-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'a9190000-aaaa-aaaa-aaaa-aaaaaaaaaaaa');

-- ============================================================================
-- RLS context helpers
-- ============================================================================
CREATE OR REPLACE FUNCTION _set_returns_rls_context(p_company_id UUID, p_role TEXT, p_user_id UUID, p_branch_id UUID DEFAULT NULL)
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

CREATE OR REPLACE FUNCTION _reset_returns_rls_context()
RETURNS VOID AS $$
BEGIN
  RESET ROLE;
  PERFORM set_config('request.jwt.claims', '', true);
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- Company-scoped SELECT: admin A sees only company A returns; company B invisible
-- ============================================================================
SELECT _set_returns_rls_context('c1900000-0000-0000-0000-000000000001', 'admin', 'a9190000-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.returns $$,
  ARRAY[1::bigint],
  'RLS returns: admin A sees only company A returns (cross-company invisible)'
);
SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.return_items $$,
  ARRAY[1::bigint],
  'RLS return_items: admin A sees only company A items'
);
SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.return_item_batches $$,
  ARRAY[1::bigint],
  'RLS return_item_batches: admin A sees only company A batches'
);
SELECT _reset_returns_rls_context();

-- Admin B sees only company B
SELECT _set_returns_rls_context('c2900000-0000-0000-0000-000000000002', 'admin', 'a9290000-cccc-cccc-cccc-cccccccccccc');
SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.returns $$,
  ARRAY[1::bigint],
  'RLS returns: admin B sees only company B returns'
);
SELECT _reset_returns_rls_context();

-- ============================================================================
-- Branch-scoped SELECT for non-admin: cashier A (branch A1) sees own-branch rows only
-- (admin sees ALL company branches; a second return lives in branch A2)
-- Pre-seed a second return in branch A2 (company A) so admin==2 vs cashier==1.
-- ============================================================================
INSERT INTO public.returns (id, company_id, branch_id, sale_id, type, status, total_amount, authorized_by, created_by, updated_by) VALUES
  ('fb910000-0000-0000-0000-000000000010', 'c1900000-0000-0000-0000-000000000001', 'b1900000-2222-2222-2222-222222222222', '1a910000-0000-0000-0000-000000000002', 'partial', 'pending', 0, 'a9190000-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'a9190000-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'a9190000-aaaa-aaaa-aaaa-aaaaaaaaaaaa');

-- admin A now sees 2 returns across both branches
SELECT _set_returns_rls_context('c1900000-0000-0000-0000-000000000001', 'admin', 'a9190000-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.returns $$,
  ARRAY[2::bigint],
  'RLS returns: admin A sees ALL company A branches (2 returns across A1+A2)'
);
SELECT _reset_returns_rls_context();

-- cashier A (branch A1 only) sees 1 return (the A1 one; the A2 one is invisible)
SELECT _set_returns_rls_context('c1900000-0000-0000-0000-000000000001', 'cashier', 'a9190000-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'b1900000-1111-1111-1111-111111111111');
SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.returns $$,
  ARRAY[1::bigint],
  'RLS returns: non-admin cashier sees only own-branch rows (A1 only; A2 invisible)'
);
SELECT _reset_returns_rls_context();

-- ============================================================================
-- Admin INSERT allowed (is_admin policy + grant)
-- ============================================================================
SELECT _set_returns_rls_context('c1900000-0000-0000-0000-000000000001', 'admin', 'a9190000-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
SELECT lives_ok(
  $$ INSERT INTO public.returns (company_id, branch_id, sale_id, type, status, total_amount, authorized_by, created_by, updated_by)
     VALUES ('c1900000-0000-0000-0000-000000000001', 'b1900000-1111-1111-1111-111111111111', '1a910000-0000-0000-0000-000000000001', 'partial', 'pending', 0, 'a9190000-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'a9190000-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'a9190000-aaaa-aaaa-aaaa-aaaaaaaaaaaa') $$,
  'RLS: admin authenticated can INSERT a return (is_admin policy + grant)'
);
SELECT _reset_returns_rls_context();

-- ============================================================================
-- Non-admin INSERT denied (is_admin policy fails)
-- ============================================================================
SELECT _set_returns_rls_context('c1900000-0000-0000-0000-000000000001', 'cashier', 'a9190000-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'b1900000-1111-1111-1111-111111111111');
SELECT throws_ok(
  $$ INSERT INTO public.returns (company_id, branch_id, sale_id, type, status, total_amount, authorized_by, created_by, updated_by)
     VALUES ('c1900000-0000-0000-0000-000000000001', 'b1900000-1111-1111-1111-111111111111', '1a910000-0000-0000-0000-000000000001', 'partial', 'pending', 0, 'a9190000-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'a9190000-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'a9190000-bbbb-bbbb-bbbb-bbbbbbbbbbbb') $$,
  NULL, NULL,
  'RLS: non-admin authenticated INSERT is denied (is_admin policy fails)'
);
SELECT _reset_returns_rls_context();

-- ============================================================================
-- Admin UPDATE (status transition) allowed; non-admin UPDATE denied
-- ============================================================================
SELECT _set_returns_rls_context('c1900000-0000-0000-0000-000000000001', 'admin', 'a9190000-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
SELECT lives_ok(
  $$ UPDATE public.returns SET status = 'approved', updated_by = 'a9190000-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        WHERE id = 'fb910000-0000-0000-0000-000000000001' $$,
  'RLS: admin authenticated can UPDATE a return status (status transition allowed)'
);
SELECT _reset_returns_rls_context();

-- Non-admin UPDATE does not raise (returns allows UPDATE): the USING policy
-- (is_admin=false) makes the row invisible to the cashier, so 0 rows are
-- touched and the header stays unchanged. Assert the row is NOT modified.
SELECT _set_returns_rls_context('c1900000-0000-0000-0000-000000000001', 'cashier', 'a9190000-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'b1900000-1111-1111-1111-111111111111');
SELECT lives_ok(
  $$ UPDATE public.returns SET status = 'completed', updated_by = 'a9190000-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
        WHERE id = 'fb910000-0000-0000-0000-000000000001' $$,
  'RLS: non-admin UPDATE statement runs without error (0 rows visible via USING)'
);
SELECT _reset_returns_rls_context();
SELECT is(
  status, 'approved',
  'RLS: non-admin UPDATE was denied (header unchanged: status stays approved, is_admin USING blocked the row)'
) FROM public.returns WHERE id = 'fb910000-0000-0000-0000-000000000001';

-- ============================================================================
-- No DELETE: admin cannot physically DELETE (no DELETE policy/grant; logical deletion only)
-- ============================================================================
SELECT _set_returns_rls_context('c1900000-0000-0000-0000-000000000001', 'admin', 'a9190000-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
SELECT throws_ok(
  $$ DELETE FROM public.returns WHERE id = 'fb910000-0000-0000-0000-000000000001' $$,
  NULL, NULL,
  'RLS: DELETE is denied (no DELETE grant/policy; logical deletion only)'
);
SELECT _reset_returns_rls_context();

-- ============================================================================
-- anon sees zero rows on all three tables
-- ============================================================================
SET ROLE anon;
SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.returns $$,
  ARRAY[0::bigint],
  'RLS: anon sees 0 returns'
);
SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.return_items $$,
  ARRAY[0::bigint],
  'RLS: anon sees 0 return_items'
);
SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.return_item_batches $$,
  ARRAY[0::bigint],
  'RLS: anon sees 0 return_item_batches'
);
RESET ROLE;

-- ============================================================================
-- service_role bypass: sees ALL rows across companies
-- ============================================================================
SET ROLE service_role;
SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.returns $$,
  ARRAY[4::bigint],
  'RLS: service_role bypasses RLS (sees all returns: 2 in A + 1 in B + admin-insert = 4)'
);
RESET ROLE;

-- ============================================================================
-- Cleanup
-- ============================================================================
SELECT * FROM finish();
ROLLBACK;