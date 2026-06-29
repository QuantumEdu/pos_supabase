-- pgTAP: Inventory domain RLS tests
-- Verifies company isolation, cashier/admin read scoping, authenticated direct
-- write denial, and service_role bypass for inventory tables and derived views.
-- (source: RI7-RI9, RI11)

BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap;

SELECT plan(21);

-- ============================================================
-- Setup inventory test data
-- ============================================================
INSERT INTO public.companies (id, name, slug)
VALUES
  ('77777777-7777-7777-7777-777777777777', 'Inventory RLS Co A', 'inventory-rls-co-a'),
  ('88888888-8888-8888-8888-888888888888', 'Inventory RLS Co B', 'inventory-rls-co-b');

INSERT INTO public.branches (id, company_id, name, slug)
VALUES
  ('77771111-1111-1111-1111-111111111111', '77777777-7777-7777-7777-777777777777', 'North Branch', 'north-branch'),
  ('77772222-2222-2222-2222-222222222222', '77777777-7777-7777-7777-777777777777', 'South Branch', 'south-branch'),
  ('88881111-1111-1111-1111-111111111111', '88888888-8888-8888-8888-888888888888', 'Other Branch', 'other-branch');

INSERT INTO auth.users (id, email, raw_app_meta_data, raw_user_meta_data)
VALUES
  ('7777aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'inventory-rls-admin@test.com',
   '{"company_id": "77777777-7777-7777-7777-777777777777", "role": "admin"}',
   '{"full_name": "Inventory RLS Admin"}'),
  ('7777bbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'inventory-rls-cashier@test.com',
   '{"company_id": "77777777-7777-7777-7777-777777777777", "role": "cashier", "branch_id": "77771111-1111-1111-1111-111111111111"}',
   '{"full_name": "Inventory RLS Cashier"}'),
  ('8888aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'inventory-rls-admin-b@test.com',
   '{"company_id": "88888888-8888-8888-8888-888888888888", "role": "admin"}',
   '{"full_name": "Inventory RLS Admin B"}')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.profiles (id, full_name)
VALUES
  ('7777aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'Inventory RLS Admin'),
  ('7777bbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'Inventory RLS Cashier'),
  ('8888aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'Inventory RLS Admin B')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.company_users (user_id, company_id, role)
VALUES
  ('7777aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', '77777777-7777-7777-7777-777777777777', 'admin'),
  ('7777bbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', '77777777-7777-7777-7777-777777777777', 'cashier'),
  ('8888aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', '88888888-8888-8888-8888-888888888888', 'admin')
ON CONFLICT (user_id, company_id) DO NOTHING;

INSERT INTO public.branch_users (user_id, branch_id, company_id)
VALUES ('7777bbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', '77771111-1111-1111-1111-111111111111', '77777777-7777-7777-7777-777777777777')
ON CONFLICT (user_id, branch_id) DO NOTHING;

INSERT INTO public.brands (id, company_id, name, slug)
VALUES
  ('77770000-0000-0000-0000-000000000001', '77777777-7777-7777-7777-777777777777', 'RLS Brand A', 'rls-brand-a'),
  ('88880000-0000-0000-0000-000000000001', '88888888-8888-8888-8888-888888888888', 'RLS Brand B', 'rls-brand-b');

INSERT INTO public.categories (id, company_id, name, slug)
VALUES
  ('77771000-0000-0000-0000-000000000001', '77777777-7777-7777-7777-777777777777', 'RLS Category A', 'rls-category-a'),
  ('88881000-0000-0000-0000-000000000001', '88888888-8888-8888-8888-888888888888', 'RLS Category B', 'rls-category-b');

INSERT INTO public.products (id, company_id, name, slug, brand_id, category_id)
VALUES
  ('77772000-0000-0000-0000-000000000001', '77777777-7777-7777-7777-777777777777', 'RLS Product A', 'rls-product-a',
   '77770000-0000-0000-0000-000000000001', '77771000-0000-0000-0000-000000000001'),
  ('88882000-0000-0000-0000-000000000001', '88888888-8888-8888-8888-888888888888', 'RLS Product B', 'rls-product-b',
   '88880000-0000-0000-0000-000000000001', '88881000-0000-0000-0000-000000000001');

INSERT INTO public.product_variants (id, company_id, product_id, sku, name)
VALUES
  ('77773000-0000-0000-0000-000000000001', '77777777-7777-7777-7777-777777777777', '77772000-0000-0000-0000-000000000001', 'INV-RLS-A', 'Inventory RLS Variant A'),
  ('88883000-0000-0000-0000-000000000001', '88888888-8888-8888-8888-888888888888', '88882000-0000-0000-0000-000000000001', 'INV-RLS-B', 'Inventory RLS Variant B');

INSERT INTO public.stock_lots (id, company_id, branch_id, variant_id, lot_code, expiration_date, received_qty, remaining_qty, status)
VALUES
  ('77774000-0000-0000-0000-000000000001', '77777777-7777-7777-7777-777777777777', '77771111-1111-1111-1111-111111111111', '77773000-0000-0000-0000-000000000001', 'LOT-NORTH', '2026-07-10', 8, 8, 'active'),
  ('77774000-0000-0000-0000-000000000002', '77777777-7777-7777-7777-777777777777', '77772222-2222-2222-2222-222222222222', '77773000-0000-0000-0000-000000000001', 'LOT-SOUTH', '2026-07-20', 5, 5, 'active'),
  ('88884000-0000-0000-0000-000000000001', '88888888-8888-8888-8888-888888888888', '88881111-1111-1111-1111-111111111111', '88883000-0000-0000-0000-000000000001', 'LOT-OTHER', '2026-07-30', 9, 9, 'active');

INSERT INTO public.stock_movements (id, company_id, branch_id, variant_id, lot_id, movement_type, delta_qty, created_by)
VALUES
  ('77775000-0000-0000-0000-000000000001', '77777777-7777-7777-7777-777777777777', '77771111-1111-1111-1111-111111111111', '77773000-0000-0000-0000-000000000001', '77774000-0000-0000-0000-000000000001', 'purchase_receipt', 8, '7777aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'),
  ('77775000-0000-0000-0000-000000000002', '77777777-7777-7777-7777-777777777777', '77772222-2222-2222-2222-222222222222', '77773000-0000-0000-0000-000000000001', '77774000-0000-0000-0000-000000000002', 'purchase_receipt', 5, '7777aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'),
  ('88885000-0000-0000-0000-000000000001', '88888888-8888-8888-8888-888888888888', '88881111-1111-1111-1111-111111111111', '88883000-0000-0000-0000-000000000001', '88884000-0000-0000-0000-000000000001', 'purchase_receipt', 9, '8888aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');

CREATE OR REPLACE FUNCTION _set_inventory_rls_context(p_company_id UUID, p_role TEXT, p_user_id UUID, p_branch_id UUID DEFAULT NULL)
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

CREATE OR REPLACE FUNCTION _reset_inventory_rls_context()
RETURNS VOID AS $$
BEGIN
  RESET ROLE;
  PERFORM set_config('request.jwt.claims', '', true);
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- Admin company isolation
-- ============================================================
SELECT _set_inventory_rls_context('77777777-7777-7777-7777-777777777777', 'admin', '7777aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'::UUID);

SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.stock_lots $$,
  ARRAY[2::bigint],
  'RLS stock_lots: admin sees own-company rows only'
);

SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.stock_movements $$,
  ARRAY[2::bigint],
  'RLS stock_movements: admin sees own-company rows only'
);

SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.stock_lots WHERE company_id = '88888888-8888-8888-8888-888888888888' $$,
  ARRAY[0::bigint],
  'RLS stock_lots: admin sees zero cross-tenant rows'
);

SELECT _reset_inventory_rls_context();

-- ============================================================
-- Cashier branch-scoped read-only access
-- ============================================================
SELECT _set_inventory_rls_context('77777777-7777-7777-7777-777777777777', 'cashier', '7777bbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'::UUID, '77771111-1111-1111-1111-111111111111'::UUID);

SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.stock_lots $$,
  ARRAY[1::bigint],
  'RLS stock_lots: cashier sees assigned-branch rows only'
);

SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.stock_movements $$,
  ARRAY[1::bigint],
  'RLS stock_movements: cashier sees assigned-branch movements only'
);

SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.stock_lots WHERE branch_id = '77772222-2222-2222-2222-222222222222' $$,
  ARRAY[0::bigint],
  'RLS stock_lots: cashier cannot see other branches in same company'
);

SELECT is(
  (SELECT physical_qty FROM public.v_stock_available
   WHERE company_id = '77777777-7777-7777-7777-777777777777'
     AND branch_id = '77771111-1111-1111-1111-111111111111'
     AND variant_id = '77773000-0000-0000-0000-000000000001'),
  8::numeric,
  'RLS v_stock_available: cashier sees assigned-branch aggregate only'
);

SELECT is(
  (SELECT count(*)::bigint FROM public.v_stock_expiring),
  1::bigint,
  'RLS v_stock_expiring: cashier sees one assigned-branch lot'
);

SELECT throws_ok(
  $$ INSERT INTO public.stock_lots (company_id, branch_id, variant_id, lot_code, received_qty, remaining_qty, status)
     VALUES ('77777777-7777-7777-7777-777777777777', '77771111-1111-1111-1111-111111111111', '77773000-0000-0000-0000-000000000001', 'LOT-CASHIER', 1, 1, 'active') $$,
  NULL,
  NULL,
  'RLS stock_lots: cashier cannot insert'
);

SELECT throws_ok(
  $$ INSERT INTO public.stock_movements (company_id, branch_id, variant_id, lot_id, movement_type, delta_qty, created_by)
     VALUES ('77777777-7777-7777-7777-777777777777', '77771111-1111-1111-1111-111111111111', '77773000-0000-0000-0000-000000000001', '77774000-0000-0000-0000-000000000001', 'purchase_receipt', 1, '7777bbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb') $$,
  NULL,
  NULL,
  'RLS stock_movements: cashier cannot insert'
);

SELECT throws_ok(
  $$ UPDATE public.stock_lots
     SET expiration_date = '2026-08-01'
     WHERE id = '77774000-0000-0000-0000-000000000001' $$,
  NULL,
  NULL,
  'RLS stock_lots: cashier cannot update base-table rows directly'
);

SELECT _reset_inventory_rls_context();

-- ============================================================
-- Unauthenticated users see nothing
-- ============================================================
SET ROLE anon;

SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.stock_lots $$,
  ARRAY[0::bigint],
  'RLS stock_lots: anon sees zero rows'
);

SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.stock_movements $$,
  ARRAY[0::bigint],
  'RLS stock_movements: anon sees zero rows'
);

RESET ROLE;

-- ============================================================
-- Admin direct-write denial + no delete policy
-- ============================================================
SELECT _set_inventory_rls_context('77777777-7777-7777-7777-777777777777', 'admin', '7777aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'::UUID);

SELECT throws_ok(
  $$ INSERT INTO public.stock_lots (id, company_id, branch_id, variant_id, lot_code, received_qty, remaining_qty, status)
     VALUES ('77774000-0000-0000-0000-000000000010', '77777777-7777-7777-7777-777777777777', '77771111-1111-1111-1111-111111111111', '77773000-0000-0000-0000-000000000001', 'LOT-ADMIN', 2, 2, 'active') $$,
  NULL,
  NULL,
  'RLS stock_lots: admin cannot insert directly and must use inventory RPCs'
);

SELECT throws_ok(
  $$ INSERT INTO public.stock_movements (id, company_id, branch_id, variant_id, lot_id, movement_type, delta_qty, created_by)
     VALUES ('77775000-0000-0000-0000-000000000010', '77777777-7777-7777-7777-777777777777', '77771111-1111-1111-1111-111111111111', '77773000-0000-0000-0000-000000000001', '77774000-0000-0000-0000-000000000010', 'purchase_receipt', 2, '7777aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa') $$,
  NULL,
  NULL,
  'RLS stock_movements: admin cannot insert directly and must use inventory RPCs'
);

SELECT throws_ok(
  $$ UPDATE public.stock_lots SET expiration_date = '2026-08-15' WHERE id = '77774000-0000-0000-0000-000000000001' $$,
  NULL,
  NULL,
  'RLS stock_lots: admin cannot update base-table rows directly'
);

SELECT throws_ok(
  $$ INSERT INTO public.stock_lots (company_id, branch_id, variant_id, lot_code, received_qty, remaining_qty, status)
     VALUES ('88888888-8888-8888-8888-888888888888', '88881111-1111-1111-1111-111111111111', '88883000-0000-0000-0000-000000000001', 'LOT-EVIL', 1, 1, 'active') $$,
  NULL,
  NULL,
  'RLS stock_lots: admin cannot insert into another company'
);

SELECT throws_ok(
  $$ DELETE FROM public.stock_lots WHERE id = '77774000-0000-0000-0000-000000000010' $$,
  NULL,
  NULL,
  'RLS stock_lots: admin cannot delete because no DELETE policy exists'
);

SELECT _reset_inventory_rls_context();

-- ============================================================
-- service_role bypass
-- ============================================================
SET ROLE service_role;

SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.stock_lots
     WHERE company_id IN ('77777777-7777-7777-7777-777777777777', '88888888-8888-8888-8888-888888888888') $$,
  ARRAY[3::bigint],
  'RLS stock_lots: service_role bypass sees all fixture rows'
);

SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.stock_movements
     WHERE company_id IN ('77777777-7777-7777-7777-777777777777', '88888888-8888-8888-8888-888888888888') $$,
  ARRAY[3::bigint],
  'RLS stock_movements: service_role bypass sees all fixture rows'
);

SELECT lives_ok(
  $$ INSERT INTO public.stock_movements (id, company_id, branch_id, variant_id, lot_id, movement_type, delta_qty, created_by)
     VALUES ('77775000-0000-0000-0000-000000000011', '77777777-7777-7777-7777-777777777777', '77771111-1111-1111-1111-111111111111', '77773000-0000-0000-0000-000000000001', '77774000-0000-0000-0000-000000000001', 'sale', -1, '7777aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa') $$,
  'RLS stock_movements: service_role bypass can insert directly'
);

RESET ROLE;

DROP FUNCTION _set_inventory_rls_context(UUID, TEXT, UUID, UUID);
DROP FUNCTION _reset_inventory_rls_context();

SELECT * FROM finish();
ROLLBACK;
