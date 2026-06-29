-- pgTAP: Purchasing domain RLS isolation tests
-- Verifies that company A cannot see company B data for all 5 purchasing tables,
-- unauthenticated users see nothing, admins see own-company rows,
-- cashier can SELECT but INSERT fails, service_role bypasses RLS,
-- DELETE is blocked (insufficient privilege).
-- (source: purchasing-domain Phase 1)

BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap;

SELECT plan(57);

-- ============================================================
-- Setup: Insert test data as postgres (bypasses RLS)
-- ============================================================

INSERT INTO public.companies (id, name, slug)
VALUES
  ('aaaa1111-1111-1111-1111-111111111111', 'Purchasing RLS Co A', 'purchasing-rls-co-a'),
  ('bbbb2222-2222-2222-2222-222222222222', 'Purchasing RLS Co B', 'purchasing-rls-co-b');

INSERT INTO public.branches (id, company_id, name, slug)
VALUES
  ('aaaa1111-bbbb-1111-bbbb-111111111111', 'aaaa1111-1111-1111-1111-111111111111', 'RLS Branch A', 'rls-branch-a'),
  ('bbbb2222-cccc-2222-dddd-222222222222', 'bbbb2222-2222-2222-2222-222222222222', 'RLS Branch B', 'rls-branch-b');

-- Auth users
INSERT INTO auth.users (id, email, raw_app_meta_data, raw_user_meta_data)
VALUES
  ('aaaa1111-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'rls-purch-admin-a@test.com',
   '{"company_id": "aaaa1111-1111-1111-1111-111111111111", "role": "admin"}',
   '{"full_name": "RLS Purch Admin A"}'),
  ('aaaa1111-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'rls-purch-cashier-a@test.com',
   '{"company_id": "aaaa1111-1111-1111-1111-111111111111", "role": "cashier"}',
   '{"full_name": "RLS Purch Cashier A"}'),
  ('bbbb2222-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'rls-purch-admin-b@test.com',
   '{"company_id": "bbbb2222-2222-2222-2222-222222222222", "role": "admin"}',
   '{"full_name": "RLS Purch Admin B"}')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.profiles (id, full_name)
VALUES
  ('aaaa1111-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'RLS Purch Admin A'),
  ('aaaa1111-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'RLS Purch Cashier A'),
  ('bbbb2222-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'RLS Purch Admin B')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.company_users (user_id, company_id, role)
VALUES
  ('aaaa1111-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'aaaa1111-1111-1111-1111-111111111111', 'admin'),
  ('aaaa1111-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'aaaa1111-1111-1111-1111-111111111111', 'cashier'),
  ('bbbb2222-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'bbbb2222-2222-2222-2222-222222222222', 'admin')
ON CONFLICT (user_id, company_id) DO NOTHING;

-- Catalog references
INSERT INTO public.brands (id, company_id, name, slug)
VALUES
  ('aaaa1111-0001-0001-0001-aaaaaaaaaaaa', 'aaaa1111-1111-1111-1111-111111111111', 'RLS Brand A', 'rls-brand-a'),
  ('bbbb2222-0001-0001-0001-bbbbbbbbbbbb', 'bbbb2222-2222-2222-2222-222222222222', 'RLS Brand B', 'rls-brand-b');

INSERT INTO public.categories (id, company_id, name, slug)
VALUES
  ('aaaa1111-0002-0002-0002-aaaaaaaaaaaa', 'aaaa1111-1111-1111-1111-111111111111', 'RLS Cat A', 'rls-cat-a'),
  ('bbbb2222-0002-0002-0002-bbbbbbbbbbbb', 'bbbb2222-2222-2222-2222-222222222222', 'RLS Cat B', 'rls-cat-b');

INSERT INTO public.products (id, company_id, name, slug)
VALUES
  ('aaaa1111-0003-0003-0003-aaaaaaaaaaaa', 'aaaa1111-1111-1111-1111-111111111111', 'RLS Product A', 'rls-product-a'),
  ('bbbb2222-0003-0003-0003-bbbbbbbbbbbb', 'bbbb2222-2222-2222-2222-222222222222', 'RLS Product B', 'rls-product-b');

INSERT INTO public.product_variants (id, company_id, product_id, sku, name)
VALUES
  ('aaaa1111-0004-0004-0004-aaaaaaaaaaaa', 'aaaa1111-1111-1111-1111-111111111111',
   'aaaa1111-0003-0003-0003-aaaaaaaaaaaa', 'PURCH-RLS-A', 'RLS Variant A'),
  ('bbbb2222-0004-0004-0004-bbbbbbbbbbbb', 'bbbb2222-2222-2222-2222-222222222222',
   'bbbb2222-0003-0003-0003-bbbbbbbbbbbb', 'PURCH-RLS-B', 'RLS Variant B');

-- Purchasing test data
INSERT INTO public.suppliers (id, company_id, name, slug)
VALUES
  ('aaaa1111-1000-1000-1000-aaaaaaaaaaaa', 'aaaa1111-1111-1111-1111-111111111111', 'RLS Supplier A1', 'rls-supplier-a1'),
  ('aaaa1111-1000-1000-1000-aaaaaaaaaaab', 'aaaa1111-1111-1111-1111-111111111111', 'RLS Supplier A2', 'rls-supplier-a2'),
  ('bbbb2222-1000-1000-1000-bbbbbbbbbbbb', 'bbbb2222-2222-2222-2222-222222222222', 'RLS Supplier B1', 'rls-supplier-b1');

INSERT INTO public.purchase_orders (id, company_id, branch_id, supplier_id, order_number, status)
VALUES
  ('aaaa1111-2000-2000-2000-aaaaaaaaaaaa', 'aaaa1111-1111-1111-1111-111111111111',
   'aaaa1111-bbbb-1111-bbbb-111111111111', 'aaaa1111-1000-1000-1000-aaaaaaaaaaaa',
   'RLS-PO-A1', 'draft'),
  ('aaaa1111-2000-2000-2000-aaaaaaaaaaab', 'aaaa1111-1111-1111-1111-111111111111',
   'aaaa1111-bbbb-1111-bbbb-111111111111', 'aaaa1111-1000-1000-1000-aaaaaaaaaaab',
   'RLS-PO-A2', 'sent'),
  ('bbbb2222-2000-2000-2000-bbbbbbbbbbbb', 'bbbb2222-2222-2222-2222-222222222222',
   'bbbb2222-cccc-2222-dddd-222222222222', 'bbbb2222-1000-1000-1000-bbbbbbbbbbbb',
   'RLS-PO-B1', 'draft');

INSERT INTO public.purchase_order_items (id, company_id, purchase_order_id, variant_id, ordered_qty, unit_cost)
VALUES
  ('aaaa1111-3000-3000-3000-aaaaaaaaaaaa', 'aaaa1111-1111-1111-1111-111111111111',
   'aaaa1111-2000-2000-2000-aaaaaaaaaaaa', 'aaaa1111-0004-0004-0004-aaaaaaaaaaaa',
   10, 50.00),
  ('aaaa1111-3000-3000-3000-aaaaaaaaaaab', 'aaaa1111-1111-1111-1111-111111111111',
   'aaaa1111-2000-2000-2000-aaaaaaaaaaab', 'aaaa1111-0004-0004-0004-aaaaaaaaaaaa',
   5, 75.00),
  ('bbbb2222-3000-3000-3000-bbbbbbbbbbbb', 'bbbb2222-2222-2222-2222-222222222222',
   'bbbb2222-2000-2000-2000-bbbbbbbbbbbb', 'bbbb2222-0004-0004-0004-bbbbbbbbbbbb',
   8, 60.00);

INSERT INTO public.purchase_receipts (id, company_id, branch_id, purchase_order_id, receipt_number)
VALUES
  ('aaaa1111-4000-4000-4000-aaaaaaaaaaaa', 'aaaa1111-1111-1111-1111-111111111111',
   'aaaa1111-bbbb-1111-bbbb-111111111111', 'aaaa1111-2000-2000-2000-aaaaaaaaaaaa',
   'RLS-REC-A1'),
  ('bbbb2222-4000-4000-4000-bbbbbbbbbbbb', 'bbbb2222-2222-2222-2222-222222222222',
   'bbbb2222-cccc-2222-dddd-222222222222', 'bbbb2222-2000-2000-2000-bbbbbbbbbbbb',
   'RLS-REC-B1');

INSERT INTO public.purchase_receipt_items (id, company_id, purchase_receipt_id, purchase_order_item_id, variant_id, received_qty, unit_cost, subtotal)
VALUES
  ('aaaa1111-5000-5000-5000-aaaaaaaaaaaa', 'aaaa1111-1111-1111-1111-111111111111',
   'aaaa1111-4000-4000-4000-aaaaaaaaaaaa', 'aaaa1111-3000-3000-3000-aaaaaaaaaaaa',
   'aaaa1111-0004-0004-0004-aaaaaaaaaaaa', 5, 50.00, 250.00),
  ('bbbb2222-5000-5000-5000-bbbbbbbbbbbb', 'bbbb2222-2222-2222-2222-222222222222',
   'bbbb2222-4000-4000-4000-bbbbbbbbbbbb', 'bbbb2222-3000-3000-3000-bbbbbbbbbbbb',
   'bbbb2222-0004-0004-0004-bbbbbbbbbbbb', 4, 60.00, 240.00);

-- ============================================================
-- Helper functions for RLS context switching
-- ============================================================
CREATE OR REPLACE FUNCTION _set_purchasing_rls_context(p_company_id UUID, p_role TEXT, p_user_id UUID)
RETURNS VOID AS $$
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object(
    'sub', p_user_id,
    'role', 'authenticated',
    'app_metadata', json_build_object(
      'company_id', p_company_id,
      'role', p_role
    )
  )::text, true);
  SET ROLE authenticated;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION _reset_purchasing_rls_context()
RETURNS VOID AS $$
BEGIN
  RESET ROLE;
  PERFORM set_config('request.jwt.claims', '', true);
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- SUPPLIERS RLS: Admin Company A sees own, not cross-tenant
-- ============================================================
SELECT _set_purchasing_rls_context('aaaa1111-1111-1111-1111-111111111111', 'admin', 'aaaa1111-aaaa-aaaa-aaaa-aaaaaaaaaaaa'::UUID);

SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.suppliers $$,
  ARRAY[2::bigint],
  'RLS suppliers: Admin in Company A sees 2 own-company rows'
);

SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.suppliers WHERE company_id != 'aaaa1111-1111-1111-1111-111111111111' $$,
  ARRAY[0::bigint],
  'RLS suppliers: Admin in Company A sees 0 cross-tenant rows'
);

SELECT _reset_purchasing_rls_context();

-- ============================================================
-- PURCHASE_ORDERS RLS: Admin Company A sees own, not cross-tenant
-- ============================================================
SELECT _set_purchasing_rls_context('aaaa1111-1111-1111-1111-111111111111', 'admin', 'aaaa1111-aaaa-aaaa-aaaa-aaaaaaaaaaaa'::UUID);

SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.purchase_orders $$,
  ARRAY[2::bigint],
  'RLS purchase_orders: Admin in Company A sees 2 own-company rows'
);

SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.purchase_orders WHERE company_id != 'aaaa1111-1111-1111-1111-111111111111' $$,
  ARRAY[0::bigint],
  'RLS purchase_orders: Admin in Company A sees 0 cross-tenant rows'
);

SELECT _reset_purchasing_rls_context();

-- ============================================================
-- PURCHASE_ORDER_ITEMS RLS: Admin Company A sees own, not cross-tenant
-- ============================================================
SELECT _set_purchasing_rls_context('aaaa1111-1111-1111-1111-111111111111', 'admin', 'aaaa1111-aaaa-aaaa-aaaa-aaaaaaaaaaaa'::UUID);

SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.purchase_order_items $$,
  ARRAY[2::bigint],
  'RLS purchase_order_items: Admin in Company A sees 2 own-company rows'
);

SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.purchase_order_items WHERE company_id != 'aaaa1111-1111-1111-1111-111111111111' $$,
  ARRAY[0::bigint],
  'RLS purchase_order_items: Admin in Company A sees 0 cross-tenant rows'
);

SELECT _reset_purchasing_rls_context();

-- ============================================================
-- PURCHASE_RECEIPTS RLS: Admin Company A sees own, not cross-tenant
-- ============================================================
SELECT _set_purchasing_rls_context('aaaa1111-1111-1111-1111-111111111111', 'admin', 'aaaa1111-aaaa-aaaa-aaaa-aaaaaaaaaaaa'::UUID);

SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.purchase_receipts $$,
  ARRAY[1::bigint],
  'RLS purchase_receipts: Admin in Company A sees 1 own-company row'
);

SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.purchase_receipts WHERE company_id != 'aaaa1111-1111-1111-1111-111111111111' $$,
  ARRAY[0::bigint],
  'RLS purchase_receipts: Admin in Company A sees 0 cross-tenant rows'
);

SELECT _reset_purchasing_rls_context();

-- ============================================================
-- PURCHASE_RECEIPT_ITEMS RLS: Admin Company A sees own, not cross-tenant
-- ============================================================
SELECT _set_purchasing_rls_context('aaaa1111-1111-1111-1111-111111111111', 'admin', 'aaaa1111-aaaa-aaaa-aaaa-aaaaaaaaaaaa'::UUID);

SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.purchase_receipt_items $$,
  ARRAY[1::bigint],
  'RLS purchase_receipt_items: Admin in Company A sees 1 own-company row'
);

SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.purchase_receipt_items WHERE company_id != 'aaaa1111-1111-1111-1111-111111111111' $$,
  ARRAY[0::bigint],
  'RLS purchase_receipt_items: Admin in Company A sees 0 cross-tenant rows'
);

SELECT _reset_purchasing_rls_context();

-- ============================================================
-- UNAUTHENTICATED: anon sees nothing on all 5 tables
-- ============================================================
SET ROLE anon;

SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.suppliers $$,
  ARRAY[0::bigint],
  'RLS suppliers: Unauthenticated user sees 0 rows'
);

SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.purchase_orders $$,
  ARRAY[0::bigint],
  'RLS purchase_orders: Unauthenticated user sees 0 rows'
);

SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.purchase_order_items $$,
  ARRAY[0::bigint],
  'RLS purchase_order_items: Unauthenticated user sees 0 rows'
);

SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.purchase_receipts $$,
  ARRAY[0::bigint],
  'RLS purchase_receipts: Unauthenticated user sees 0 rows'
);

SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.purchase_receipt_items $$,
  ARRAY[0::bigint],
  'RLS purchase_receipt_items: Unauthenticated user sees 0 rows'
);

RESET ROLE;

-- ============================================================
-- CASHIER: Can SELECT but INSERT fails on all 5 tables
-- ============================================================
SELECT _set_purchasing_rls_context('aaaa1111-1111-1111-1111-111111111111', 'cashier', 'aaaa1111-bbbb-bbbb-bbbb-bbbbbbbbbbbb'::UUID);

-- Cashier can SELECT
SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.suppliers $$,
  ARRAY[2::bigint],
  'RLS suppliers: Cashier can SELECT own-company rows'
);

SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.purchase_orders $$,
  ARRAY[2::bigint],
  'RLS purchase_orders: Cashier can SELECT own-company rows'
);

SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.purchase_order_items $$,
  ARRAY[2::bigint],
  'RLS purchase_order_items: Cashier can SELECT own-company rows'
);

SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.purchase_receipts $$,
  ARRAY[1::bigint],
  'RLS purchase_receipts: Cashier can SELECT own-company rows'
);

SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.purchase_receipt_items $$,
  ARRAY[1::bigint],
  'RLS purchase_receipt_items: Cashier can SELECT own-company rows'
);

-- Cashier cannot INSERT
SELECT throws_ok(
  $$ INSERT INTO public.suppliers (company_id, name, slug)
     VALUES ('aaaa1111-1111-1111-1111-111111111111', 'Cashier Supplier', 'cashier-supplier') $$,
  NULL,
  NULL,
  'RLS suppliers: Cashier cannot insert'
);

SELECT throws_ok(
  $$ INSERT INTO public.purchase_orders (company_id, branch_id, supplier_id, order_number, status)
     VALUES ('aaaa1111-1111-1111-1111-111111111111',
             'aaaa1111-bbbb-1111-bbbb-111111111111',
             'aaaa1111-1000-1000-1000-aaaaaaaaaaaa',
             'PO-CASHIER', 'draft') $$,
  NULL,
  NULL,
  'RLS purchase_orders: Cashier cannot insert'
);

SELECT throws_ok(
  $$ INSERT INTO public.purchase_order_items (company_id, purchase_order_id, variant_id, ordered_qty, unit_cost)
     VALUES ('aaaa1111-1111-1111-1111-111111111111',
             'aaaa1111-2000-2000-2000-aaaaaaaaaaaa',
             'aaaa1111-0004-0004-0004-aaaaaaaaaaaa',
             5, 25.00) $$,
  NULL,
  NULL,
  'RLS purchase_order_items: Cashier cannot insert'
);

SELECT throws_ok(
  $$ INSERT INTO public.purchase_receipts (company_id, branch_id, purchase_order_id, receipt_number)
     VALUES ('aaaa1111-1111-1111-1111-111111111111',
             'aaaa1111-bbbb-1111-bbbb-111111111111',
             'aaaa1111-2000-2000-2000-aaaaaaaaaaaa',
             'REC-CASHIER') $$,
  NULL,
  NULL,
  'RLS purchase_receipts: Cashier cannot insert'
);

SELECT throws_ok(
  $$ INSERT INTO public.purchase_receipt_items (company_id, purchase_receipt_id, purchase_order_item_id, variant_id, received_qty, unit_cost, subtotal)
     VALUES ('aaaa1111-1111-1111-1111-111111111111',
             'aaaa1111-4000-4000-4000-aaaaaaaaaaaa',
             'aaaa1111-3000-3000-3000-aaaaaaaaaaaa',
             'aaaa1111-0004-0004-0004-aaaaaaaaaaaa',
             2, 50.00, 100.00) $$,
  NULL,
  NULL,
  'RLS purchase_receipt_items: Cashier cannot insert'
);

SELECT _reset_purchasing_rls_context();

-- ============================================================
-- ADMIN INSERT into own company
-- ============================================================
SELECT _set_purchasing_rls_context('aaaa1111-1111-1111-1111-111111111111', 'admin', 'aaaa1111-aaaa-aaaa-aaaa-aaaaaaaaaaaa'::UUID);

SELECT lives_ok(
  $$ INSERT INTO public.suppliers (company_id, name, slug)
     VALUES ('aaaa1111-1111-1111-1111-111111111111', 'RLS Supplier Insert', 'rls-supplier-insert') $$,
  'RLS suppliers: Admin can insert into own company'
);

SELECT lives_ok(
  $$ INSERT INTO public.purchase_orders (id, company_id, branch_id, supplier_id, order_number, status)
     VALUES ('aaaa1111-2000-2000-2000-aaaaaaaaaaac', 'aaaa1111-1111-1111-1111-111111111111',
             'aaaa1111-bbbb-1111-bbbb-111111111111',
             'aaaa1111-1000-1000-1000-aaaaaaaaaaaa',
             'RLS-PO-INSERT', 'draft') $$,
  'RLS purchase_orders: Admin can insert into own company'
);

SELECT lives_ok(
  $$ INSERT INTO public.purchase_order_items (id, company_id, purchase_order_id, variant_id, ordered_qty, unit_cost)
     VALUES ('aaaa1111-3000-3000-3000-aaaaaaaaaaac', 'aaaa1111-1111-1111-1111-111111111111',
             'aaaa1111-2000-2000-2000-aaaaaaaaaaac',
             'aaaa1111-0004-0004-0004-aaaaaaaaaaaa',
             3, 20.00) $$,
  'RLS purchase_order_items: Admin can insert into own company'
);

SELECT lives_ok(
  $$ INSERT INTO public.purchase_receipts (id, company_id, branch_id, purchase_order_id, receipt_number)
     VALUES ('aaaa1111-4000-4000-4000-aaaaaaaaaaab', 'aaaa1111-1111-1111-1111-111111111111',
             'aaaa1111-bbbb-1111-bbbb-111111111111',
             'aaaa1111-2000-2000-2000-aaaaaaaaaaac',
             'RLS-REC-INSERT') $$,
  'RLS purchase_receipts: Admin can insert into own company'
);

SELECT lives_ok(
  $$ INSERT INTO public.purchase_receipt_items (id, company_id, purchase_receipt_id, purchase_order_item_id, variant_id, received_qty, unit_cost, subtotal)
     VALUES ('aaaa1111-5000-5000-5000-aaaaaaaaaaab', 'aaaa1111-1111-1111-1111-111111111111',
             'aaaa1111-4000-4000-4000-aaaaaaaaaaab',
             'aaaa1111-3000-3000-3000-aaaaaaaaaaac',
             'aaaa1111-0004-0004-0004-aaaaaaaaaaaa',
             2, 20.00, 40.00) $$,
  'RLS purchase_receipt_items: Admin can insert into own company'
);

SELECT _reset_purchasing_rls_context();

-- ============================================================
-- ADMIN INSERT cross-company: should fail on all 5 tables
-- ============================================================
SELECT _set_purchasing_rls_context('aaaa1111-1111-1111-1111-111111111111', 'admin', 'aaaa1111-aaaa-aaaa-aaaa-aaaaaaaaaaaa'::UUID);

SELECT throws_ok(
  $$ INSERT INTO public.suppliers (company_id, name, slug)
     VALUES ('bbbb2222-2222-2222-2222-222222222222', 'Cross Supplier', 'cross-supplier') $$,
  NULL,
  NULL,
  'RLS suppliers: Admin cannot insert into different company'
);

SELECT throws_ok(
  $$ INSERT INTO public.purchase_orders (company_id, branch_id, supplier_id, order_number, status)
     VALUES ('bbbb2222-2222-2222-2222-222222222222',
             'bbbb2222-cccc-2222-dddd-222222222222',
             'bbbb2222-1000-1000-1000-bbbbbbbbbbbb',
             'CROSS-PO', 'draft') $$,
  NULL,
  NULL,
  'RLS purchase_orders: Admin cannot insert into different company'
);

SELECT throws_ok(
  $$ INSERT INTO public.purchase_order_items (company_id, purchase_order_id, variant_id, ordered_qty, unit_cost)
     VALUES ('bbbb2222-2222-2222-2222-222222222222',
             'bbbb2222-2000-2000-2000-bbbbbbbbbbbb',
             'bbbb2222-0004-0004-0004-bbbbbbbbbbbb',
             5, 30.00) $$,
  NULL,
  NULL,
  'RLS purchase_order_items: Admin cannot insert into different company'
);

SELECT throws_ok(
  $$ INSERT INTO public.purchase_receipts (company_id, branch_id, purchase_order_id, receipt_number)
     VALUES ('bbbb2222-2222-2222-2222-222222222222',
             'bbbb2222-cccc-2222-dddd-222222222222',
             'bbbb2222-2000-2000-2000-bbbbbbbbbbbb',
             'CROSS-REC') $$,
  NULL,
  NULL,
  'RLS purchase_receipts: Admin cannot insert into different company'
);

SELECT throws_ok(
  $$ INSERT INTO public.purchase_receipt_items (company_id, purchase_receipt_id, purchase_order_item_id, variant_id, received_qty, unit_cost, subtotal)
     VALUES ('bbbb2222-2222-2222-2222-222222222222',
             'bbbb2222-4000-4000-4000-bbbbbbbbbbbb',
             'bbbb2222-3000-3000-3000-bbbbbbbbbbbb',
             'bbbb2222-0004-0004-0004-bbbbbbbbbbbb',
             2, 30.00, 60.00) $$,
  NULL,
  NULL,
  'RLS purchase_receipt_items: Admin cannot insert into different company'
);

SELECT _reset_purchasing_rls_context();

-- ============================================================
-- ADMIN UPDATE own-company rows
-- ============================================================
SELECT _set_purchasing_rls_context('aaaa1111-1111-1111-1111-111111111111', 'admin', 'aaaa1111-aaaa-aaaa-aaaa-aaaaaaaaaaaa'::UUID);

SELECT lives_ok(
  $$ UPDATE public.suppliers SET name = 'RLS Supplier A1 Updated' WHERE id = 'aaaa1111-1000-1000-1000-aaaaaaaaaaaa' $$,
  'RLS suppliers: Admin can update own-company row'
);

SELECT lives_ok(
  $$ UPDATE public.purchase_orders SET notes = 'RLS update test' WHERE id = 'aaaa1111-2000-2000-2000-aaaaaaaaaaaa' $$,
  'RLS purchase_orders: Admin can update own-company row (non-critical col)'
);

SELECT lives_ok(
  $$ UPDATE public.purchase_order_items SET unit_cost = 55.00 WHERE id = 'aaaa1111-3000-3000-3000-aaaaaaaaaaaa' $$,
  'RLS purchase_order_items: Admin can update own-company row (non-critical col)'
);

SELECT lives_ok(
  $$ UPDATE public.purchase_receipts SET notes = 'RLS update rec' WHERE id = 'aaaa1111-4000-4000-4000-aaaaaaaaaaaa' $$,
  'RLS purchase_receipts: Admin can update own-company row'
);

SELECT lives_ok(
  $$ UPDATE public.purchase_receipt_items SET lot_code = 'LOT-RLS' WHERE id = 'aaaa1111-5000-5000-5000-aaaaaaaaaaaa' $$,
  'RLS purchase_receipt_items: Admin can update own-company row'
);

SELECT _reset_purchasing_rls_context();

-- ============================================================
-- ADMIN cannot UPDATE cross-tenant rows (silently blocked by RLS USING)
-- ============================================================
SELECT _set_purchasing_rls_context('aaaa1111-1111-1111-1111-111111111111', 'admin', 'aaaa1111-aaaa-aaaa-aaaa-aaaaaaaaaaaa'::UUID);

UPDATE public.suppliers SET name = 'Hacked B1' WHERE id = 'bbbb2222-1000-1000-1000-bbbbbbbbbbbb';
UPDATE public.purchase_orders SET notes = 'Hacked PO' WHERE id = 'bbbb2222-2000-2000-2000-bbbbbbbbbbbb';
UPDATE public.purchase_order_items SET unit_cost = 999.99 WHERE id = 'bbbb2222-3000-3000-3000-bbbbbbbbbbbb';
UPDATE public.purchase_receipts SET notes = 'Hacked Rec' WHERE id = 'bbbb2222-4000-4000-4000-bbbbbbbbbbbb';
UPDATE public.purchase_receipt_items SET lot_code = 'HACKED' WHERE id = 'bbbb2222-5000-5000-5000-bbbbbbbbbbbb';

SELECT _reset_purchasing_rls_context();

-- Verify rows unchanged as postgres (no RLS)
SELECT is(
  (SELECT name FROM public.suppliers WHERE id = 'bbbb2222-1000-1000-1000-bbbbbbbbbbbb'),
  'RLS Supplier B1',
  'RLS suppliers: Admin cannot update cross-tenant rows (name unchanged)'
);

SELECT is(
  (SELECT notes FROM public.purchase_orders WHERE id = 'bbbb2222-2000-2000-2000-bbbbbbbbbbbb'),
  NULL,
  'RLS purchase_orders: Admin cannot update cross-tenant rows (notes unchanged)'
);

SELECT is(
  (SELECT unit_cost FROM public.purchase_order_items WHERE id = 'bbbb2222-3000-3000-3000-bbbbbbbbbbbb'),
  60.00,
  'RLS purchase_order_items: Admin cannot update cross-tenant rows (unit_cost unchanged)'
);

SELECT is(
  (SELECT notes FROM public.purchase_receipts WHERE id = 'bbbb2222-4000-4000-4000-bbbbbbbbbbbb'),
  NULL,
  'RLS purchase_receipts: Admin cannot update cross-tenant rows (notes unchanged)'
);

SELECT is(
  (SELECT lot_code FROM public.purchase_receipt_items WHERE id = 'bbbb2222-5000-5000-5000-bbbbbbbbbbbb'),
  NULL,
  'RLS purchase_receipt_items: Admin cannot update cross-tenant rows (lot_code unchanged)'
);

-- ============================================================
-- NO PHYSICAL DELETE: DELETE blocked on all 5 tables
-- (No DELETE policies exist, no DELETE grant to authenticated)
-- ============================================================
SET ROLE authenticated;

SELECT throws_ok(
  $$ DELETE FROM public.suppliers WHERE id = 'aaaa1111-1000-1000-1000-aaaaaaaaaaaa' $$,
  '42501',
  NULL,
  'RLS suppliers: DELETE blocked (insufficient privilege)'
);

SELECT throws_ok(
  $$ DELETE FROM public.purchase_orders WHERE id = 'aaaa1111-2000-2000-2000-aaaaaaaaaaaa' $$,
  '42501',
  NULL,
  'RLS purchase_orders: DELETE blocked (insufficient privilege)'
);

SELECT throws_ok(
  $$ DELETE FROM public.purchase_order_items WHERE id = 'aaaa1111-3000-3000-3000-aaaaaaaaaaaa' $$,
  '42501',
  NULL,
  'RLS purchase_order_items: DELETE blocked (insufficient privilege)'
);

SELECT throws_ok(
  $$ DELETE FROM public.purchase_receipts WHERE id = 'aaaa1111-4000-4000-4000-aaaaaaaaaaaa' $$,
  '42501',
  NULL,
  'RLS purchase_receipts: DELETE blocked (insufficient privilege)'
);

SELECT throws_ok(
  $$ DELETE FROM public.purchase_receipt_items WHERE id = 'aaaa1111-5000-5000-5000-aaaaaaaaaaaa' $$,
  '42501',
  NULL,
  'RLS purchase_receipt_items: DELETE blocked (insufficient privilege)'
);

RESET ROLE;

-- ============================================================
-- SERVICE_ROLE bypasses all RLS
-- ============================================================
SET ROLE service_role;

SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.suppliers
     WHERE company_id IN ('aaaa1111-1111-1111-1111-111111111111', 'bbbb2222-2222-2222-2222-222222222222') $$,
  ARRAY[4::bigint],
  'RLS suppliers: service_role sees all fixture rows (3 Company A + 1 Company B)'
);

SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.purchase_orders
     WHERE company_id IN ('aaaa1111-1111-1111-1111-111111111111', 'bbbb2222-2222-2222-2222-222222222222') $$,
  ARRAY[4::bigint],
  'RLS purchase_orders: service_role sees all fixture rows (3 Company A + 1 Company B)'
);

SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.purchase_order_items
     WHERE company_id IN ('aaaa1111-1111-1111-1111-111111111111', 'bbbb2222-2222-2222-2222-222222222222') $$,
  ARRAY[4::bigint],
  'RLS purchase_order_items: service_role sees all fixture rows (3 Company A + 1 Company B)'
);

SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.purchase_receipts
     WHERE company_id IN ('aaaa1111-1111-1111-1111-111111111111', 'bbbb2222-2222-2222-2222-222222222222') $$,
  ARRAY[3::bigint],
  'RLS purchase_receipts: service_role sees all fixture rows (2 Company A + 1 Company B)'
);

SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.purchase_receipt_items
     WHERE company_id IN ('aaaa1111-1111-1111-1111-111111111111', 'bbbb2222-2222-2222-2222-222222222222') $$,
  ARRAY[3::bigint],
  'RLS purchase_receipt_items: service_role sees all fixture rows (2 Company A + 1 Company B)'
);

-- service_role can INSERT any row
SELECT lives_ok(
  $$ INSERT INTO public.suppliers (id, company_id, name, slug)
     VALUES ('aaaaffff-1000-1000-1000-aaaaaaaaaaaa', 'bbbb2222-2222-2222-2222-222222222222', 'Service Role Supplier', 'sr-supplier') $$,
  'RLS suppliers: service_role can insert any row'
);

SELECT lives_ok(
  $$ INSERT INTO public.purchase_order_items (id, company_id, purchase_order_id, variant_id, ordered_qty, unit_cost)
     VALUES ('aaaaffff-3000-3000-3000-aaaaaaaaaaaa', 'bbbb2222-2222-2222-2222-222222222222',
             'bbbb2222-2000-2000-2000-bbbbbbbbbbbb', 'bbbb2222-0004-0004-0004-bbbbbbbbbbbb',
             1, 10.00) $$,
  'RLS purchase_order_items: service_role can insert any row'
);

RESET ROLE;

-- ============================================================
-- Cleanup helper functions
-- ============================================================
DROP FUNCTION _set_purchasing_rls_context(UUID, TEXT, UUID);
DROP FUNCTION _reset_purchasing_rls_context();

-- ============================================================
-- Finish
-- ============================================================
SELECT * FROM finish();
ROLLBACK;
