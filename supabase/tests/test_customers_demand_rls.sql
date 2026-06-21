-- pgTAP: Customers Demand domain RLS isolation tests
-- Verifies that company A cannot see company B data for all 4 demand tables,
-- unauthenticated users see nothing, admins see/write own-company rows,
-- cashier SELECT read-only, cashier branch scoping on preorders/preorder_items,
-- service_role bypasses RLS, and DELETE is blocked (no DELETE policies).
-- (source: RCD8, RCD9, RCD10)

BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap;

SELECT plan(50);

-- ============================================================
-- Setup: Insert test data as postgres (bypasses RLS)
-- ============================================================

-- Companies
INSERT INTO public.companies (id, name, slug)
VALUES
  ('dddd1111-1111-1111-1111-111111111111', 'CustDemand RLS Co A', 'custdemand-rls-co-a'),
  ('eeee2222-2222-2222-2222-222222222222', 'CustDemand RLS Co B', 'custdemand-rls-co-b');

-- Branches: A1 + A2 for company A, B1 for company B
INSERT INTO public.branches (id, company_id, name, slug)
VALUES
  ('dddd1111-bbbb-1111-bbbb-111111111111', 'dddd1111-1111-1111-1111-111111111111', 'RLS Branch A1', 'rls-branch-a1'),
  ('dddd1111-bbbb-1111-bbbb-222222222222', 'dddd1111-1111-1111-1111-111111111111', 'RLS Branch A2', 'rls-branch-a2'),
  ('eeee2222-cccc-2222-dddd-222222222222', 'eeee2222-2222-2222-2222-222222222222', 'RLS Branch B1', 'rls-branch-b1');

-- Auth users
INSERT INTO auth.users (id, email, raw_app_meta_data, raw_user_meta_data)
VALUES
  ('dddd1111-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'rls-cd-admin-a@test.com',
   '{"company_id": "dddd1111-1111-1111-1111-111111111111", "role": "admin"}',
   '{"full_name": "RLS CD Admin A"}'),
  ('dddd1111-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'rls-cd-cashier-a@test.com',
   '{"company_id": "dddd1111-1111-1111-1111-111111111111", "role": "cashier", "branch_id": "dddd1111-bbbb-1111-bbbb-111111111111"}',
   '{"full_name": "RLS CD Cashier A"}'),
  ('eeee2222-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'rls-cd-admin-b@test.com',
   '{"company_id": "eeee2222-2222-2222-2222-222222222222", "role": "admin"}',
   '{"full_name": "RLS CD Admin B"}')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.profiles (id, full_name)
VALUES
  ('dddd1111-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'RLS CD Admin A'),
  ('dddd1111-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'RLS CD Cashier A'),
  ('eeee2222-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'RLS CD Admin B')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.company_users (user_id, company_id, role)
VALUES
  ('dddd1111-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'dddd1111-1111-1111-1111-111111111111', 'admin'),
  ('dddd1111-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'dddd1111-1111-1111-1111-111111111111', 'cashier'),
  ('eeee2222-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'eeee2222-2222-2222-2222-222222222222', 'admin')
ON CONFLICT (user_id, company_id) DO NOTHING;

INSERT INTO public.branch_users (user_id, branch_id, company_id)
VALUES ('dddd1111-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'dddd1111-bbbb-1111-bbbb-111111111111', 'dddd1111-1111-1111-1111-111111111111')
ON CONFLICT (user_id, branch_id) DO NOTHING;

-- Catalog references needed for FKs
INSERT INTO public.brands (id, company_id, name, slug)
VALUES
  ('dddd1111-0001-0001-0001-aaaaaaaaaaaa', 'dddd1111-1111-1111-1111-111111111111', 'RLS CD Brand A', 'rls-cd-brand-a'),
  ('eeee2222-0001-0001-0001-bbbbbbbbbbbb', 'eeee2222-2222-2222-2222-222222222222', 'RLS CD Brand B', 'rls-cd-brand-b');

INSERT INTO public.categories (id, company_id, name, slug)
VALUES
  ('dddd1111-0002-0002-0002-aaaaaaaaaaaa', 'dddd1111-1111-1111-1111-111111111111', 'RLS CD Cat A', 'rls-cd-cat-a'),
  ('eeee2222-0002-0002-0002-bbbbbbbbbbbb', 'eeee2222-2222-2222-2222-222222222222', 'RLS CD Cat B', 'rls-cd-cat-b');

INSERT INTO public.products (id, company_id, name, slug, brand_id, category_id)
VALUES
  ('dddd1111-0003-0003-0003-aaaaaaaaaaaa', 'dddd1111-1111-1111-1111-111111111111', 'RLS CD Product A', 'rls-cd-product-a',
   'dddd1111-0001-0001-0001-aaaaaaaaaaaa', 'dddd1111-0002-0002-0002-aaaaaaaaaaaa'),
  ('eeee2222-0003-0003-0003-bbbbbbbbbbbb', 'eeee2222-2222-2222-2222-222222222222', 'RLS CD Product B', 'rls-cd-product-b',
   'eeee2222-0001-0001-0001-bbbbbbbbbbbb', 'eeee2222-0002-0002-0002-bbbbbbbbbbbb');

INSERT INTO public.product_variants (id, company_id, product_id, sku, name)
VALUES
  ('dddd1111-0004-0004-0004-aaaaaaaaaaaa', 'dddd1111-1111-1111-1111-111111111111',
   'dddd1111-0003-0003-0003-aaaaaaaaaaaa', 'CD-RLS-A', 'RLS CD Variant A'),
  ('eeee2222-0004-0004-0004-bbbbbbbbbbbb', 'eeee2222-2222-2222-2222-222222222222',
   'eeee2222-0003-0003-0003-bbbbbbbbbbbb', 'CD-RLS-B', 'RLS CD Variant B');

-- Customers test data
INSERT INTO public.customers (id, company_id, name, slug)
VALUES
  ('dddd1111-1000-1000-1000-aaaaaaaaaaaa', 'dddd1111-1111-1111-1111-111111111111', 'RLS Customer A1', 'rls-customer-a1'),
  ('dddd1111-1000-1000-1000-aaaaaaaaaaab', 'dddd1111-1111-1111-1111-111111111111', 'RLS Customer A2', 'rls-customer-a2'),
  ('eeee2222-1000-1000-1000-bbbbbbbbbbbb', 'eeee2222-2222-2222-2222-222222222222', 'RLS Customer B1', 'rls-customer-b1');

-- Customer Requests test data
INSERT INTO public.customer_requests (id, company_id, customer_id, variant_id, requested_qty, status)
VALUES
  ('dddd1111-2000-2000-2000-aaaaaaaaaaaa', 'dddd1111-1111-1111-1111-111111111111',
   'dddd1111-1000-1000-1000-aaaaaaaaaaaa', 'dddd1111-0004-0004-0004-aaaaaaaaaaaa', 5, 'pending'),
  ('dddd1111-2000-2000-2000-aaaaaaaaaaab', 'dddd1111-1111-1111-1111-111111111111',
   'dddd1111-1000-1000-1000-aaaaaaaaaaab', NULL, 10, 'pending'),
  ('eeee2222-2000-2000-2000-bbbbbbbbbbbb', 'eeee2222-2222-2222-2222-222222222222',
   'eeee2222-1000-1000-1000-bbbbbbbbbbbb', 'eeee2222-0004-0004-0004-bbbbbbbbbbbb', 3, 'pending');

-- Preorders test data: A1 branch, A2 branch, B1 branch
INSERT INTO public.preorders (id, company_id, branch_id, customer_id, preorder_number, status)
VALUES
  ('dddd1111-3000-3000-3000-aaaaaaaaaaaa', 'dddd1111-1111-1111-1111-111111111111',
   'dddd1111-bbbb-1111-bbbb-111111111111', 'dddd1111-1000-1000-1000-aaaaaaaaaaaa',
   'RLS-PRE-A1', 'draft'),
  ('dddd1111-3000-3000-3000-aaaaaaaaaaab', 'dddd1111-1111-1111-1111-111111111111',
   'dddd1111-bbbb-1111-bbbb-222222222222', 'dddd1111-1000-1000-1000-aaaaaaaaaaab',
   'RLS-PRE-A2', 'confirmed'),
  ('eeee2222-3000-3000-3000-bbbbbbbbbbbb', 'eeee2222-2222-2222-2222-222222222222',
   'eeee2222-cccc-2222-dddd-222222222222', 'eeee2222-1000-1000-1000-bbbbbbbbbbbb',
   'RLS-PRE-B1', 'draft');

-- Preorder Items: one per preorder
INSERT INTO public.preorder_items (id, company_id, preorder_id, variant_id, qty, unit_price)
VALUES
  ('dddd1111-4000-4000-4000-aaaaaaaaaaaa', 'dddd1111-1111-1111-1111-111111111111',
   'dddd1111-3000-3000-3000-aaaaaaaaaaaa', 'dddd1111-0004-0004-0004-aaaaaaaaaaaa',
   5, 100.00),
  ('dddd1111-4000-4000-4000-aaaaaaaaaaab', 'dddd1111-1111-1111-1111-111111111111',
   'dddd1111-3000-3000-3000-aaaaaaaaaaab', 'dddd1111-0004-0004-0004-aaaaaaaaaaaa',
   3, 150.00),
  ('eeee2222-4000-4000-4000-bbbbbbbbbbbb', 'eeee2222-2222-2222-2222-222222222222',
   'eeee2222-3000-3000-3000-bbbbbbbbbbbb', 'eeee2222-0004-0004-0004-bbbbbbbbbbbb',
   3, 200.00);

-- ============================================================
-- Helper functions for RLS context switching
-- ============================================================
CREATE OR REPLACE FUNCTION _set_custdemand_rls_context(p_company_id UUID, p_role TEXT, p_user_id UUID, p_branch_id UUID DEFAULT NULL)
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

CREATE OR REPLACE FUNCTION _reset_custdemand_rls_context()
RETURNS VOID AS $$
BEGIN
  RESET ROLE;
  PERFORM set_config('request.jwt.claims', '', true);
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- 3.1 ADMIN CROSS-TENANT ISOLATION on all 4 tables
-- Admin A sees only company A rows; company B rows invisible
-- ============================================================
SELECT _set_custdemand_rls_context('dddd1111-1111-1111-1111-111111111111', 'admin', 'dddd1111-aaaa-aaaa-aaaa-aaaaaaaaaaaa'::UUID);

-- 1. customers
SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.customers $$,
  ARRAY[2::bigint],
  'RLS customers: Admin in Company A sees 2 own-company rows'
);

-- 2. customers cross-tenant
SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.customers WHERE company_id != 'dddd1111-1111-1111-1111-111111111111' $$,
  ARRAY[0::bigint],
  'RLS customers: Admin in Company A sees 0 cross-tenant rows'
);

-- 3. customer_requests
SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.customer_requests $$,
  ARRAY[2::bigint],
  'RLS customer_requests: Admin in Company A sees 2 own-company rows'
);

-- 4. customer_requests cross-tenant
SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.customer_requests WHERE company_id != 'dddd1111-1111-1111-1111-111111111111' $$,
  ARRAY[0::bigint],
  'RLS customer_requests: Admin in Company A sees 0 cross-tenant rows'
);

-- 5. preorders
SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.preorders $$,
  ARRAY[2::bigint],
  'RLS preorders: Admin in Company A sees 2 own-company rows'
);

-- 6. preorders cross-tenant
SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.preorders WHERE company_id != 'dddd1111-1111-1111-1111-111111111111' $$,
  ARRAY[0::bigint],
  'RLS preorders: Admin in Company A sees 0 cross-tenant rows'
);

-- 7. preorder_items
SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.preorder_items $$,
  ARRAY[2::bigint],
  'RLS preorder_items: Admin in Company A sees 2 own-company rows'
);

-- 8. preorder_items cross-tenant
SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.preorder_items WHERE company_id != 'dddd1111-1111-1111-1111-111111111111' $$,
  ARRAY[0::bigint],
  'RLS preorder_items: Admin in Company A sees 0 cross-tenant rows'
);

SELECT _reset_custdemand_rls_context();

-- ============================================================
-- 3.2 ADMIN INSERT own-company rows
-- ============================================================
SELECT _set_custdemand_rls_context('dddd1111-1111-1111-1111-111111111111', 'admin', 'dddd1111-aaaa-aaaa-aaaa-aaaaaaaaaaaa'::UUID);

-- 9. customers INSERT
SELECT lives_ok(
  $$ INSERT INTO public.customers (company_id, name, slug)
     VALUES ('dddd1111-1111-1111-1111-111111111111', 'RLS Customer Insert', 'rls-customer-insert') $$,
  'RLS customers: Admin can insert into own company'
);

-- 10. customer_requests INSERT
SELECT lives_ok(
  $$ INSERT INTO public.customer_requests (company_id, customer_id, requested_qty, status)
     VALUES ('dddd1111-1111-1111-1111-111111111111',
             'dddd1111-1000-1000-1000-aaaaaaaaaaaa',
             5, 'pending') $$,
  'RLS customer_requests: Admin can insert into own company'
);

-- 11. preorders INSERT
SELECT lives_ok(
  $$ INSERT INTO public.preorders (id, company_id, branch_id, customer_id, preorder_number, status)
     VALUES ('dddd1111-3000-3000-3000-aaaaaaaaaaac', 'dddd1111-1111-1111-1111-111111111111',
             'dddd1111-bbbb-1111-bbbb-111111111111',
             'dddd1111-1000-1000-1000-aaaaaaaaaaaa',
             'RLS-PRE-INSERT', 'draft') $$,
  'RLS preorders: Admin can insert into own company'
);

-- 12. preorder_items INSERT
SELECT lives_ok(
  $$ INSERT INTO public.preorder_items (id, company_id, preorder_id, variant_id, qty)
     VALUES ('dddd1111-4000-4000-4000-aaaaaaaaaaac', 'dddd1111-1111-1111-1111-111111111111',
             'dddd1111-3000-3000-3000-aaaaaaaaaaac',
             'dddd1111-0004-0004-0004-aaaaaaaaaaaa',
             1) $$,
  'RLS preorder_items: Admin can insert into own company'
);

SELECT _reset_custdemand_rls_context();

-- ============================================================
-- 3.2 ADMIN UPDATE own-company rows
-- ============================================================
SELECT _set_custdemand_rls_context('dddd1111-1111-1111-1111-111111111111', 'admin', 'dddd1111-aaaa-aaaa-aaaa-aaaaaaaaaaaa'::UUID);

-- 13. customers UPDATE
SELECT lives_ok(
  $$ UPDATE public.customers SET name = 'RLS Customer A1 Updated' WHERE id = 'dddd1111-1000-1000-1000-aaaaaaaaaaaa' $$,
  'RLS customers: Admin can update own-company row'
);

-- 14. customer_requests UPDATE
SELECT lives_ok(
  $$ UPDATE public.customer_requests SET status = 'resolved' WHERE id = 'dddd1111-2000-2000-2000-aaaaaaaaaaaa' $$,
  'RLS customer_requests: Admin can update own-company row'
);

-- 15. preorders UPDATE
SELECT lives_ok(
  $$ UPDATE public.preorders SET notes = 'RLS update test' WHERE id = 'dddd1111-3000-3000-3000-aaaaaaaaaaaa' $$,
  'RLS preorders: Admin can update own-company row'
);

-- 16. preorder_items UPDATE
SELECT lives_ok(
  $$ UPDATE public.preorder_items SET qty = 7 WHERE id = 'dddd1111-4000-4000-4000-aaaaaaaaaaaa' $$,
  'RLS preorder_items: Admin can update own-company row'
);

SELECT _reset_custdemand_rls_context();

-- ============================================================
-- 3.2 ADMIN INSERT cross-company: company_id mismatch rejected
-- ============================================================
SELECT _set_custdemand_rls_context('dddd1111-1111-1111-1111-111111111111', 'admin', 'dddd1111-aaaa-aaaa-aaaa-aaaaaaaaaaaa'::UUID);

-- 17. customers cross-company INSERT
SELECT throws_ok(
  $$ INSERT INTO public.customers (company_id, name, slug)
     VALUES ('eeee2222-2222-2222-2222-222222222222', 'Cross Customer', 'cross-customer') $$,
  NULL,
  NULL,
  'RLS customers: Admin cannot insert into different company'
);

-- 18. customer_requests cross-company INSERT
SELECT throws_ok(
  $$ INSERT INTO public.customer_requests (company_id, customer_id, requested_qty, status)
     VALUES ('eeee2222-2222-2222-2222-222222222222',
             'eeee2222-1000-1000-1000-bbbbbbbbbbbb',
             3, 'pending') $$,
  NULL,
  NULL,
  'RLS customer_requests: Admin cannot insert into different company'
);

-- 19. preorders cross-company INSERT
SELECT throws_ok(
  $$ INSERT INTO public.preorders (company_id, branch_id, customer_id, preorder_number, status)
     VALUES ('eeee2222-2222-2222-2222-222222222222',
             'eeee2222-cccc-2222-dddd-222222222222',
             'eeee2222-1000-1000-1000-bbbbbbbbbbbb',
             'CROSS-PRE', 'draft') $$,
  NULL,
  NULL,
  'RLS preorders: Admin cannot insert into different company'
);

-- 20. preorder_items cross-company INSERT
SELECT throws_ok(
  $$ INSERT INTO public.preorder_items (company_id, preorder_id, variant_id, qty)
     VALUES ('eeee2222-2222-2222-2222-222222222222',
             'eeee2222-3000-3000-3000-bbbbbbbbbbbb',
             'eeee2222-0004-0004-0004-bbbbbbbbbbbb',
             5) $$,
  NULL,
  NULL,
  'RLS preorder_items: Admin cannot insert into different company'
);

SELECT _reset_custdemand_rls_context();

-- ============================================================
-- 3.2 ADMIN UPDATE cross-tenant: silently blocked (0 rows affected)
-- Attempt updates as admin A on company B rows, then verify unchanged.
-- ============================================================
SELECT _set_custdemand_rls_context('dddd1111-1111-1111-1111-111111111111', 'admin', 'dddd1111-aaaa-aaaa-aaaa-aaaaaaaaaaaa'::UUID);

UPDATE public.customers SET name = 'Hacked Cust' WHERE id = 'eeee2222-1000-1000-1000-bbbbbbbbbbbb';
UPDATE public.customer_requests SET status = 'cancelled' WHERE id = 'eeee2222-2000-2000-2000-bbbbbbbbbbbb';
UPDATE public.preorders SET notes = 'Hacked PO' WHERE id = 'eeee2222-3000-3000-3000-bbbbbbbbbbbb';
UPDATE public.preorder_items SET qty = 999 WHERE id = 'eeee2222-4000-4000-4000-bbbbbbbbbbbb';

SELECT _reset_custdemand_rls_context();

-- 21. customers cross-tenant UPDATE verification
SELECT is(
  (SELECT name FROM public.customers WHERE id = 'eeee2222-1000-1000-1000-bbbbbbbbbbbb'),
  'RLS Customer B1',
  'RLS customers: Admin cannot update cross-tenant rows (name unchanged)'
);

-- 22. customer_requests cross-tenant UPDATE verification
SELECT is(
  (SELECT status FROM public.customer_requests WHERE id = 'eeee2222-2000-2000-2000-bbbbbbbbbbbb'),
  'pending',
  'RLS customer_requests: Admin cannot update cross-tenant rows (status unchanged)'
);

-- 23. preorders cross-tenant UPDATE verification
SELECT is(
  (SELECT notes FROM public.preorders WHERE id = 'eeee2222-3000-3000-3000-bbbbbbbbbbbb'),
  NULL,
  'RLS preorders: Admin cannot update cross-tenant rows (notes unchanged)'
);

-- 24. preorder_items cross-tenant UPDATE verification
SELECT is(
  (SELECT qty FROM public.preorder_items WHERE id = 'eeee2222-4000-4000-4000-bbbbbbbbbbbb'),
  3::numeric,
  'RLS preorder_items: Admin cannot update cross-tenant rows (qty unchanged)'
);

-- ============================================================
-- 3.3 CASHIER SELECT READ-ONLY on all 4 tables
-- Cashier can SELECT own-company rows; INSERT/UPDATE fails
-- ============================================================
SELECT _set_custdemand_rls_context('dddd1111-1111-1111-1111-111111111111', 'cashier', 'dddd1111-bbbb-bbbb-bbbb-bbbbbbbbbbbb'::UUID, 'dddd1111-bbbb-1111-bbbb-111111111111'::UUID);

-- 25. customers SELECT (3 = 2 initial + 1 inserted by admin test above)
SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.customers $$,
  ARRAY[3::bigint],
  'RLS customers: Cashier can SELECT own-company rows'
);

-- 26. customer_requests SELECT (3 = 2 initial + 1 inserted by admin test)
SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.customer_requests $$,
  ARRAY[3::bigint],
  'RLS customer_requests: Cashier can SELECT own-company rows'
);

-- 27. preorders SELECT (branch-scoped: 2 = 1 original A1 + 1 admin-inserted on A1)
SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.preorders $$,
  ARRAY[2::bigint],
  'RLS preorders: Cashier sees only assigned-branch rows'
);

-- 28. preorder_items SELECT (branch-scoped via parent preorder: 2 on A1 branch)
SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.preorder_items $$,
  ARRAY[2::bigint],
  'RLS preorder_items: Cashier sees only items from assigned-branch preorders'
);

-- 29. customers INSERT blocked
SELECT throws_ok(
  $$ INSERT INTO public.customers (company_id, name, slug)
     VALUES ('dddd1111-1111-1111-1111-111111111111', 'Cashier Customer', 'cashier-customer') $$,
  NULL,
  NULL,
  'RLS customers: Cashier cannot insert'
);

-- 30. customer_requests INSERT blocked
SELECT throws_ok(
  $$ INSERT INTO public.customer_requests (company_id, customer_id, requested_qty, status)
     VALUES ('dddd1111-1111-1111-1111-111111111111',
             'dddd1111-1000-1000-1000-aaaaaaaaaaaa',
             1, 'pending') $$,
  NULL,
  NULL,
  'RLS customer_requests: Cashier cannot insert'
);

-- 31. preorders INSERT blocked
SELECT throws_ok(
  $$ INSERT INTO public.preorders (company_id, branch_id, customer_id, preorder_number, status)
     VALUES ('dddd1111-1111-1111-1111-111111111111',
             'dddd1111-bbbb-1111-bbbb-111111111111',
             'dddd1111-1000-1000-1000-aaaaaaaaaaaa',
             'CASHIER-PRE', 'draft') $$,
  NULL,
  NULL,
  'RLS preorders: Cashier cannot insert'
);

-- 32. preorder_items INSERT blocked
SELECT throws_ok(
  $$ INSERT INTO public.preorder_items (company_id, preorder_id, variant_id, qty)
     VALUES ('dddd1111-1111-1111-1111-111111111111',
             'dddd1111-3000-3000-3000-aaaaaaaaaaaa',
             'dddd1111-0004-0004-0004-aaaaaaaaaaaa',
             1) $$,
  NULL,
  NULL,
  'RLS preorder_items: Cashier cannot insert'
);

-- Cashier UPDATE attempts (silently blocked by USING clause — 0 rows affected)
UPDATE public.customers SET name = 'Cashier Updated' WHERE id = 'dddd1111-1000-1000-1000-aaaaaaaaaaaa';
UPDATE public.customer_requests SET status = 'cancelled' WHERE id = 'dddd1111-2000-2000-2000-aaaaaaaaaaaa';
UPDATE public.preorders SET notes = 'Cashier Note' WHERE id = 'dddd1111-3000-3000-3000-aaaaaaaaaaaa';
UPDATE public.preorder_items SET qty = 10 WHERE id = 'dddd1111-4000-4000-4000-aaaaaaaaaaaa';

SELECT _reset_custdemand_rls_context();

-- 33. Verify customers unchanged (cashier UPDATE silently blocked)
SELECT is(
  (SELECT name FROM public.customers WHERE id = 'dddd1111-1000-1000-1000-aaaaaaaaaaaa'),
  'RLS Customer A1 Updated',
  'RLS customers: Cashier cannot update (name unchanged)'
);

-- 34. Verify customer_requests unchanged
SELECT is(
  (SELECT status FROM public.customer_requests WHERE id = 'dddd1111-2000-2000-2000-aaaaaaaaaaaa'),
  'resolved',
  'RLS customer_requests: Cashier cannot update (status unchanged)'
);

-- 35. Verify preorders unchanged
SELECT is(
  (SELECT notes FROM public.preorders WHERE id = 'dddd1111-3000-3000-3000-aaaaaaaaaaaa'),
  'RLS update test',
  'RLS preorders: Cashier cannot update (notes unchanged)'
);

-- 36. Verify preorder_items unchanged
SELECT is(
  (SELECT qty FROM public.preorder_items WHERE id = 'dddd1111-4000-4000-4000-aaaaaaaaaaaa'),
  7::numeric,
  'RLS preorder_items: Cashier cannot update (qty unchanged)'
);

-- ============================================================
-- 3.4 CASHIER BRANCH SCOPING on preorders
-- Cashier A1 sees only branch A1 preorders (verified above in test 27)
-- Cashier A1 preorder_items are filtered to parent preorders in A1 (test 28)
-- Verify that other-branch preorders are invisible
-- ============================================================
SELECT _set_custdemand_rls_context('dddd1111-1111-1111-1111-111111111111', 'cashier', 'dddd1111-bbbb-bbbb-bbbb-bbbbbbbbbbbb'::UUID, 'dddd1111-bbbb-1111-bbbb-111111111111'::UUID);

-- 37. Cashier branch scoping: only branch A1 preorders visible
SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.preorders WHERE branch_id != 'dddd1111-bbbb-1111-bbbb-111111111111' $$,
  ARRAY[0::bigint],
  'RLS preorders: Cashier sees 0 other-branch preorders'
);

-- 38. Cashier branch scoping: preorder_items filtered to branch A1 parent preorders
SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.preorder_items pi
     WHERE NOT EXISTS (
       SELECT 1 FROM public.preorders po
       WHERE po.id = pi.preorder_id AND po.branch_id = 'dddd1111-bbbb-1111-bbbb-111111111111'
     ) $$,
  ARRAY[0::bigint],
  'RLS preorder_items: Cashier sees 0 items from other-branch preorders'
);

SELECT _reset_custdemand_rls_context();

-- ============================================================
-- 3.5 UNAUTHENTICATED (anon) returns zero rows on all 4 tables
-- ============================================================
SET ROLE anon;

-- 39. customers
SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.customers $$,
  ARRAY[0::bigint],
  'RLS customers: Unauthenticated user sees 0 rows'
);

-- 40. customer_requests
SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.customer_requests $$,
  ARRAY[0::bigint],
  'RLS customer_requests: Unauthenticated user sees 0 rows'
);

-- 41. preorders
SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.preorders $$,
  ARRAY[0::bigint],
  'RLS preorders: Unauthenticated user sees 0 rows'
);

-- 42. preorder_items
SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.preorder_items $$,
  ARRAY[0::bigint],
  'RLS preorder_items: Unauthenticated user sees 0 rows'
);

RESET ROLE;

-- ============================================================
-- 3.5 SERVICE_ROLE SELECT bypass
-- ============================================================
SET ROLE service_role;

-- 43. customers
SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.customers $$,
  ARRAY[4::bigint],
  'RLS customers: service_role sees all rows (2 Company A + 1 Company B + 1 inserted)'
);

-- 44. customer_requests
SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.customer_requests $$,
  ARRAY[4::bigint],
  'RLS customer_requests: service_role sees all rows (2 Company A + 1 Company B + 1 inserted)'
);

-- 45. preorders
SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.preorders $$,
  ARRAY[4::bigint],
  'RLS preorders: service_role sees all rows (2 Company A + 1 Company B + 1 inserted)'
);

-- 46. preorder_items
SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.preorder_items $$,
  ARRAY[4::bigint],
  'RLS preorder_items: service_role sees all rows (2 Company A + 1 Company B + 1 inserted)'
);

RESET ROLE;

-- ============================================================
-- 3.6 NO DELETE POLICY: DELETE fails on all 4 tables
-- ============================================================
SET ROLE authenticated;

-- 47. customers DELETE blocked
SELECT throws_ok(
  $$ DELETE FROM public.customers WHERE id = 'dddd1111-1000-1000-1000-aaaaaaaaaaaa' $$,
  '42501',
  NULL,
  'RLS customers: DELETE blocked (insufficient privilege)'
);

-- 48. customer_requests DELETE blocked
SELECT throws_ok(
  $$ DELETE FROM public.customer_requests WHERE id = 'dddd1111-2000-2000-2000-aaaaaaaaaaaa' $$,
  '42501',
  NULL,
  'RLS customer_requests: DELETE blocked (insufficient privilege)'
);

-- 49. preorders DELETE blocked
SELECT throws_ok(
  $$ DELETE FROM public.preorders WHERE id = 'dddd1111-3000-3000-3000-aaaaaaaaaaaa' $$,
  '42501',
  NULL,
  'RLS preorders: DELETE blocked (insufficient privilege)'
);

-- 50. preorder_items DELETE blocked
SELECT throws_ok(
  $$ DELETE FROM public.preorder_items WHERE id = 'dddd1111-4000-4000-4000-aaaaaaaaaaaa' $$,
  '42501',
  NULL,
  'RLS preorder_items: DELETE blocked (insufficient privilege)'
);

RESET ROLE;

-- ============================================================
-- Cleanup helper functions
-- ============================================================
DROP FUNCTION _set_custdemand_rls_context(UUID, TEXT, UUID, UUID);
DROP FUNCTION _reset_custdemand_rls_context();

-- ============================================================
-- Finish
-- ============================================================
SELECT * FROM finish();
ROLLBACK;
