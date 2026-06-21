-- pgTAP: Inventory domain constraint and view tests
-- Verifies lot uniqueness, quantity and movement checks, append-only movement
-- protection, direct remaining_qty/status edit blocking, and inventory views.
-- (source: RI1-RI3, RI7, RI11)

BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap;

SELECT plan(15);

-- ============================================================
-- Setup reference data
-- ============================================================
INSERT INTO public.companies (id, name, slug)
VALUES
  ('55555555-5555-5555-5555-555555555555', 'Inventory Constraint Co', 'inventory-constraint-co'),
  ('66666666-6666-6666-6666-666666666666', 'Inventory Other Co', 'inventory-other-co');

INSERT INTO public.branches (id, company_id, name, slug)
VALUES
  ('55555555-1111-1111-1111-111111111111', '55555555-5555-5555-5555-555555555555', 'Main Branch', 'main-branch'),
  ('55555555-2222-2222-2222-222222222222', '55555555-5555-5555-5555-555555555555', 'Alt Branch', 'alt-branch'),
  ('66666666-1111-1111-1111-111111111111', '66666666-6666-6666-6666-666666666666', 'Other Branch', 'other-branch');

INSERT INTO public.brands (id, company_id, name, slug)
VALUES ('55550000-0000-0000-0000-000000000001', '55555555-5555-5555-5555-555555555555', 'Inventory Brand', 'inventory-brand');

INSERT INTO public.categories (id, company_id, name, slug)
VALUES ('55551000-0000-0000-0000-000000000001', '55555555-5555-5555-5555-555555555555', 'Inventory Category', 'inventory-category');

INSERT INTO public.products (id, company_id, name, slug, brand_id, category_id)
VALUES ('55552000-0000-0000-0000-000000000001', '55555555-5555-5555-5555-555555555555', 'Inventory Product', 'inventory-product',
        '55550000-0000-0000-0000-000000000001', '55551000-0000-0000-0000-000000000001');

INSERT INTO public.product_variants (id, company_id, product_id, sku, name)
VALUES ('55553000-0000-0000-0000-000000000001', '55555555-5555-5555-5555-555555555555',
        '55552000-0000-0000-0000-000000000001', 'INV-CONSTRAINT-1', 'Inventory Variant');

INSERT INTO public.product_variants (id, company_id, product_id, sku, name)
VALUES ('55553000-0000-0000-0000-000000000002', '55555555-5555-5555-5555-555555555555',
        '55552000-0000-0000-0000-000000000001', 'INV-CONSTRAINT-2', 'Inventory Variant 2');

INSERT INTO auth.users (id, email, raw_app_meta_data, raw_user_meta_data)
VALUES ('5555aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'inventory-admin@test.com',
        '{"company_id": "55555555-5555-5555-5555-555555555555", "role": "admin", "branch_id": "55555555-1111-1111-1111-111111111111"}',
        '{"full_name": "Inventory Admin"}')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.profiles (id, full_name)
VALUES ('5555aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'Inventory Admin')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.company_users (user_id, company_id, role)
VALUES ('5555aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', '55555555-5555-5555-5555-555555555555', 'admin')
ON CONFLICT (user_id, company_id) DO NOTHING;

CREATE OR REPLACE FUNCTION _set_inventory_admin_context()
RETURNS VOID AS $$
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object(
    'sub', '5555aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    'role', 'authenticated',
    'app_metadata', json_build_object(
      'company_id', '55555555-5555-5555-5555-555555555555',
      'role', 'admin',
      'branch_id', '55555555-1111-1111-1111-111111111111'
    )
  )::text, true);
  SET ROLE authenticated;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION _reset_inventory_context()
RETURNS VOID AS $$
BEGIN
  RESET ROLE;
  PERFORM set_config('request.jwt.claims', '', true);
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- Base lots and movements
-- ============================================================
INSERT INTO public.stock_lots (id, company_id, branch_id, variant_id, lot_code, expiration_date, received_qty, remaining_qty, cost_per_unit, status)
VALUES
  ('55554000-0000-0000-0000-000000000001', '55555555-5555-5555-5555-555555555555', '55555555-1111-1111-1111-111111111111', '55553000-0000-0000-0000-000000000001', 'LOT-A', '2026-07-01', 10, 10, NULL, 'active'),
  ('55554000-0000-0000-0000-000000000002', '55555555-5555-5555-5555-555555555555', '55555555-2222-2222-2222-222222222222', '55553000-0000-0000-0000-000000000001', 'LOT-A', '2026-08-01', 5, 5, NULL, 'active'),
  ('55554000-0000-0000-0000-000000000003', '55555555-5555-5555-5555-555555555555', '55555555-1111-1111-1111-111111111111', '55553000-0000-0000-0000-000000000001', 'LOT-B', '2026-06-15', 10, 10, NULL, 'active'),
  ('55554000-0000-0000-0000-000000000004', '55555555-5555-5555-5555-555555555555', '55555555-1111-1111-1111-111111111111', '55553000-0000-0000-0000-000000000001', 'LOT-C', NULL, 5, 3, NULL, 'active'),
  ('55554000-0000-0000-0000-000000000005', '55555555-5555-5555-5555-555555555555', '55555555-1111-1111-1111-111111111111', '55553000-0000-0000-0000-000000000001', 'LOT-D', '2026-05-01', 4, 4, NULL, 'expired'),
  ('55554000-0000-0000-0000-000000000006', '55555555-5555-5555-5555-555555555555', '55555555-1111-1111-1111-111111111111', '55553000-0000-0000-0000-000000000001', 'LOT-E', '2026-05-20', 2, 0, NULL, 'depleted');

INSERT INTO public.stock_movements (id, company_id, branch_id, variant_id, lot_id, movement_type, delta_qty, created_by)
VALUES ('55555000-0000-0000-0000-000000000001', '55555555-5555-5555-5555-555555555555', '55555555-1111-1111-1111-111111111111', '55553000-0000-0000-0000-000000000001', '55554000-0000-0000-0000-000000000001', 'purchase_receipt', 10, '5555aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');

-- ============================================================
-- Constraint and protection tests
-- ============================================================
SELECT throws_ok(
  $$ INSERT INTO public.stock_lots (company_id, branch_id, variant_id, lot_code, received_qty, remaining_qty, status)
     VALUES ('55555555-5555-5555-5555-555555555555', '55555555-1111-1111-1111-111111111111', '55553000-0000-0000-0000-000000000001', 'LOT-A', 3, 3, 'active') $$,
  NULL,
  NULL,
  'Lot uniqueness: duplicate lot_code in same company + branch + variant is rejected'
);

SELECT lives_ok(
  $$ INSERT INTO public.stock_lots (company_id, branch_id, variant_id, lot_code, received_qty, remaining_qty, status)
     VALUES ('55555555-5555-5555-5555-555555555555', '55555555-1111-1111-1111-111111111111', '55553000-0000-0000-0000-000000000002', 'LOT-A', 3, 3, 'active') $$,
  'Lot uniqueness: same lot_code is allowed for a different variant in the same branch'
);

SELECT throws_ok(
  $$ INSERT INTO public.stock_lots (company_id, branch_id, variant_id, lot_code, received_qty, remaining_qty, status)
     VALUES ('55555555-5555-5555-5555-555555555555', '55555555-1111-1111-1111-111111111111', '55553000-0000-0000-0000-000000000001', 'LOT-NEG', 1, -1, 'active') $$,
  NULL,
  NULL,
  'Lot constraint: remaining_qty cannot be negative'
);

SELECT throws_ok(
  $$ INSERT INTO public.stock_lots (company_id, branch_id, variant_id, lot_code, received_qty, remaining_qty, status)
     VALUES ('55555555-5555-5555-5555-555555555555', '55555555-1111-1111-1111-111111111111', '55553000-0000-0000-0000-000000000001', 'LOT-ZERO', 0, 0, 'depleted') $$,
  NULL,
  NULL,
  'Lot constraint: received_qty must be greater than zero'
);

SELECT throws_ok(
  $$ INSERT INTO public.stock_movements (company_id, branch_id, variant_id, lot_id, movement_type, delta_qty, created_by)
     VALUES ('55555555-5555-5555-5555-555555555555', '55555555-1111-1111-1111-111111111111', '55553000-0000-0000-0000-000000000001', '55554000-0000-0000-0000-000000000001', 'bogus_type', 1, '5555aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa') $$,
  NULL,
  NULL,
  'Movement constraint: invalid movement_type is rejected'
);

SELECT throws_ok(
  $$ INSERT INTO public.stock_movements (company_id, branch_id, variant_id, lot_id, movement_type, delta_qty, created_by)
     VALUES ('55555555-5555-5555-5555-555555555555', '55555555-1111-1111-1111-111111111111', '55553000-0000-0000-0000-000000000001', '55554000-0000-0000-0000-000000000001', 'purchase_receipt', -1, '5555aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa') $$,
  NULL,
  NULL,
  'Movement constraint: purchase_receipt must have positive delta_qty'
);

SELECT throws_ok(
  $$ INSERT INTO public.stock_movements (company_id, branch_id, variant_id, lot_id, movement_type, delta_qty, created_by)
     VALUES ('55555555-5555-5555-5555-555555555555', '55555555-1111-1111-1111-111111111111', '55553000-0000-0000-0000-000000000001', '55554000-0000-0000-0000-000000000001', 'sale', 1, '5555aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa') $$,
  NULL,
  NULL,
  'Movement constraint: sale must have negative delta_qty'
);

SELECT throws_ok(
  $$ UPDATE public.stock_movements SET notes = 'mutated' WHERE id = '55555000-0000-0000-0000-000000000001' $$,
  NULL,
  'stock_movements is append-only',
  'Movement protection: UPDATE is rejected'
);

SELECT throws_ok(
  $$ DELETE FROM public.stock_movements WHERE id = '55555000-0000-0000-0000-000000000001' $$,
  NULL,
  'stock_movements is append-only',
  'Movement protection: DELETE is rejected'
);

SELECT _set_inventory_admin_context();

SELECT throws_ok(
  $$ UPDATE public.stock_lots SET remaining_qty = 9 WHERE id = '55554000-0000-0000-0000-000000000001' $$,
  NULL,
  NULL,
  'Lot protection: direct remaining_qty update is rejected for authenticated admin'
);

SELECT throws_ok(
  $$ UPDATE public.stock_lots SET status = 'depleted' WHERE id = '55554000-0000-0000-0000-000000000001' $$,
  NULL,
  NULL,
  'Lot protection: direct status update is rejected for authenticated admin'
);

SELECT _reset_inventory_context();

SELECT is(
  (SELECT physical_qty FROM public.v_stock_available
   WHERE company_id = '55555555-5555-5555-5555-555555555555'
     AND branch_id = '55555555-1111-1111-1111-111111111111'
     AND variant_id = '55553000-0000-0000-0000-000000000001'),
  23::numeric,
  'v_stock_available: sums active lots only (10 + 10 + 3 = 23)'
);

SELECT is(
  ARRAY(
    SELECT lot_code
    FROM public.v_stock_expiring
    WHERE company_id = '55555555-5555-5555-5555-555555555555'
      AND branch_id = '55555555-1111-1111-1111-111111111111'
      AND variant_id = '55553000-0000-0000-0000-000000000001'
  )::text[],
  ARRAY['LOT-B','LOT-A','LOT-C']::text[],
  'v_stock_expiring: orders active lots by expiration_date ASC with NULL last'
);

SELECT throws_ok(
  $$ INSERT INTO public.stock_movements (company_id, branch_id, variant_id, lot_id, movement_type, delta_qty, created_by)
     VALUES ('55555555-5555-5555-5555-555555555555', '55555555-2222-2222-2222-222222222222', '55553000-0000-0000-0000-000000000001', '55554000-0000-0000-0000-000000000001', 'sale', -1, '5555aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa') $$,
  NULL,
  NULL,
  'Movement constraint: lot_id must match the same company + branch + variant scope'
);

SELECT is(
  (SELECT count(*)::bigint FROM public.v_stock_expiring
   WHERE company_id = '55555555-5555-5555-5555-555555555555'
     AND branch_id = '55555555-1111-1111-1111-111111111111'
     AND variant_id = '55553000-0000-0000-0000-000000000001'),
  3::bigint,
  'v_stock_expiring: excludes expired and depleted lots'
);

DROP FUNCTION _set_inventory_admin_context();
DROP FUNCTION _reset_inventory_context();

SELECT * FROM finish();
ROLLBACK;
