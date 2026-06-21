-- pgTAP: Purchasing domain constraint tests
-- Verifies composite FK enforcement, CHECK constraints, unique constraints,
-- critical column protection trigger, and set_updated_at trigger.
-- (source: purchasing-domain Phase 1)

BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap;

SELECT plan(29);

-- ============================================================
-- Setup: Create companies and reference data for constraint tests
-- ============================================================
INSERT INTO public.companies (id, name, slug)
VALUES
  ('99999999-9999-9999-9999-999999999999', 'Purchasing Constraint Co A', 'purchasing-constraint-co-a'),
  ('88888888-8888-8888-8888-aaaaaaaaaaaa', 'Purchasing Constraint Co B', 'purchasing-constraint-co-b');

INSERT INTO public.branches (id, company_id, name, slug)
VALUES
  ('99991111-1111-1111-1111-111111111111', '99999999-9999-9999-9999-999999999999', 'Branch A1', 'branch-a1'),
  ('88881111-1111-1111-1111-111111111111', '88888888-8888-8888-8888-aaaaaaaaaaaa', 'Branch B1', 'branch-b1');

INSERT INTO public.brands (id, company_id, name, slug)
VALUES
  ('99990000-0000-0000-0000-000000000001', '99999999-9999-9999-9999-999999999999', 'Brand A', 'brand-a'),
  ('88880000-0000-0000-0000-000000000001', '88888888-8888-8888-8888-aaaaaaaaaaaa', 'Brand B', 'brand-b');

INSERT INTO public.categories (id, company_id, name, slug)
VALUES
  ('99991000-0000-0000-0000-000000000001', '99999999-9999-9999-9999-999999999999', 'Cat A', 'cat-a'),
  ('88881000-0000-0000-0000-000000000001', '88888888-8888-8888-8888-aaaaaaaaaaaa', 'Cat B', 'cat-b');

INSERT INTO public.products (id, company_id, name, slug, brand_id, category_id)
VALUES
  ('99992000-0000-0000-0000-000000000001', '99999999-9999-9999-9999-999999999999',
   'Product A', 'product-a', '99990000-0000-0000-0000-000000000001', '99991000-0000-0000-0000-000000000001'),
  ('88882000-0000-0000-0000-000000000001', '88888888-8888-8888-8888-aaaaaaaaaaaa',
   'Product B', 'product-b', '88880000-0000-0000-0000-000000000001', '88881000-0000-0000-0000-000000000001');

INSERT INTO public.product_variants (id, company_id, product_id, sku, name)
VALUES
  ('99993000-0000-0000-0000-000000000001', '99999999-9999-9999-9999-999999999999',
   '99992000-0000-0000-0000-000000000001', 'PURCH-A-1', 'Purchasing Variant A'),
  ('88883000-0000-0000-0000-000000000001', '88888888-8888-8888-8888-aaaaaaaaaaaa',
   '88882000-0000-0000-0000-000000000001', 'PURCH-B-1', 'Purchasing Variant B');

INSERT INTO public.suppliers (id, company_id, name, slug)
VALUES
  ('99994000-0000-0000-0000-000000000001', '99999999-9999-9999-9999-999999999999', 'Supplier A', 'supplier-a'),
  ('88884000-0000-0000-0000-000000000001', '88888888-8888-8888-8888-aaaaaaaaaaaa', 'Supplier B', 'supplier-b');

INSERT INTO public.purchase_orders (id, company_id, branch_id, supplier_id, order_number, status)
VALUES
  ('99995000-0000-0000-0000-000000000001', '99999999-9999-9999-9999-999999999999',
   '99991111-1111-1111-1111-111111111111', '99994000-0000-0000-0000-000000000001',
   'PO-001', 'draft'),
  ('88885000-0000-0000-0000-000000000001', '88888888-8888-8888-8888-aaaaaaaaaaaa',
   '88881111-1111-1111-1111-111111111111', '88884000-0000-0000-0000-000000000001',
   'PO-002', 'draft');

INSERT INTO public.purchase_order_items (id, company_id, purchase_order_id, variant_id, ordered_qty, unit_cost)
VALUES
  ('99996000-0000-0000-0000-000000000001', '99999999-9999-9999-9999-999999999999',
   '99995000-0000-0000-0000-000000000001', '99993000-0000-0000-0000-000000000001',
   10, 25.50);

INSERT INTO public.purchase_receipts (id, company_id, branch_id, purchase_order_id, receipt_number)
VALUES
  ('99997000-0000-0000-0000-000000000001', '99999999-9999-9999-9999-999999999999',
   '99991111-1111-1111-1111-111111111111', '99995000-0000-0000-0000-000000000001',
   'REC-001');

INSERT INTO public.purchase_receipt_items (id, company_id, purchase_receipt_id, purchase_order_item_id, variant_id, received_qty, unit_cost, subtotal)
VALUES
  ('99998000-0000-0000-0000-000000000001', '99999999-9999-9999-9999-999999999999',
   '99997000-0000-0000-0000-000000000001', '99996000-0000-0000-0000-000000000001',
   '99993000-0000-0000-0000-000000000001', 5, 25.50, 127.50);

-- ============================================================
-- SUPPLIERS: Unique slug per company
-- ============================================================

-- Duplicate slug in same company should fail
SELECT throws_ok(
  $$ INSERT INTO public.suppliers (company_id, name, slug)
     VALUES ('99999999-9999-9999-9999-999999999999', 'Supplier A Dup', 'supplier-a') $$,
  NULL,
  NULL,
  'Suppliers unique: duplicate slug in same company should fail'
);

-- Same slug in different company should succeed
SELECT lives_ok(
  $$ INSERT INTO public.suppliers (company_id, name, slug)
     VALUES ('88888888-8888-8888-8888-aaaaaaaaaaaa', 'Supplier B Other', 'supplier-a') $$,
  'Suppliers unique: same slug in different company is allowed'
);

-- ============================================================
-- PURCHASE_ORDERS: Unique order_number per company
-- ============================================================

-- Duplicate order_number in same company should fail
SELECT throws_ok(
  $$ INSERT INTO public.purchase_orders (company_id, branch_id, supplier_id, order_number, status)
     VALUES ('99999999-9999-9999-9999-999999999999',
             '99991111-1111-1111-1111-111111111111',
             '99994000-0000-0000-0000-000000000001',
             'PO-001', 'draft') $$,
  NULL,
  NULL,
  'PO unique: duplicate order_number in same company should fail'
);

-- Same order_number in different company should succeed
SELECT lives_ok(
  $$ INSERT INTO public.purchase_orders (id, company_id, branch_id, supplier_id, order_number, status)
     VALUES ('88885000-0000-0000-0000-000000000002', '88888888-8888-8888-8888-aaaaaaaaaaaa',
             '88881111-1111-1111-1111-111111111111', '88884000-0000-0000-0000-000000000001',
             'PO-001', 'draft') $$,
  'PO unique: same order_number in different company is allowed'
);

-- ============================================================
-- PURCHASE_RECEIPTS: Unique receipt_number per company
-- ============================================================

-- Duplicate receipt_number in same company should fail
SELECT throws_ok(
  $$ INSERT INTO public.purchase_receipts (company_id, branch_id, purchase_order_id, receipt_number)
     VALUES ('99999999-9999-9999-9999-999999999999',
             '99991111-1111-1111-1111-111111111111',
             '99995000-0000-0000-0000-000000000001',
             'REC-001') $$,
  NULL,
  NULL,
  'Receipt unique: duplicate receipt_number in same company should fail'
);

-- Same receipt_number in different company should succeed
SELECT lives_ok(
  $$ INSERT INTO public.purchase_receipts (id, company_id, branch_id, purchase_order_id, receipt_number)
     VALUES ('88887000-0000-0000-0000-000000000001', '88888888-8888-8888-8888-aaaaaaaaaaaa',
             '88881111-1111-1111-1111-111111111111', '88885000-0000-0000-0000-000000000001',
             'REC-001') $$,
  'Receipt unique: same receipt_number in different company is allowed'
);

-- ============================================================
-- PURCHASE_ORDERS: Invalid status CHECK constraint
-- ============================================================

SELECT throws_ok(
  $$ INSERT INTO public.purchase_orders (id, company_id, branch_id, supplier_id, order_number, status)
     VALUES ('99995000-0000-0000-0000-000000000002', '99999999-9999-9999-9999-999999999999',
             '99991111-1111-1111-1111-111111111111', '99994000-0000-0000-0000-000000000001',
             'PO-INVALID', 'bogus_status') $$,
  NULL,
  NULL,
  'PO status: invalid status value should be rejected'
);

-- ============================================================
-- PURCHASE_ORDER_ITEMS: ordered_qty > 0 CHECK
-- ============================================================

SELECT throws_ok(
  $$ INSERT INTO public.purchase_order_items (company_id, purchase_order_id, variant_id, ordered_qty, unit_cost)
     VALUES ('99999999-9999-9999-9999-999999999999',
             '99995000-0000-0000-0000-000000000001',
             '99993000-0000-0000-0000-000000000001',
             0, 25.50) $$,
  NULL,
  NULL,
  'PO items: ordered_qty <= 0 should be rejected'
);

-- ============================================================
-- PURCHASE_ORDER_ITEMS: received_qty >= 0 CHECK
-- ============================================================

SELECT throws_ok(
  $$ INSERT INTO public.purchase_order_items (id, company_id, purchase_order_id, variant_id, ordered_qty, received_qty, unit_cost)
     VALUES ('99996000-0000-0000-0000-000000000002', '99999999-9999-9999-9999-999999999999',
             '99995000-0000-0000-0000-000000000001', '99993000-0000-0000-0000-000000000001',
             10, -1, 25.50) $$,
  NULL,
  NULL,
  'PO items: received_qty < 0 should be rejected'
);

-- ============================================================
-- PURCHASE_ORDER_ITEMS: received_qty <= ordered_qty CHECK
-- ============================================================

SELECT throws_ok(
  $$ INSERT INTO public.purchase_order_items (id, company_id, purchase_order_id, variant_id, ordered_qty, received_qty, unit_cost)
     VALUES ('99996000-0000-0000-0000-000000000003', '99999999-9999-9999-9999-999999999999',
             '99995000-0000-0000-0000-000000000001', '99993000-0000-0000-0000-000000000001',
             10, 11, 25.50) $$,
  NULL,
  NULL,
  'PO items: received_qty > ordered_qty should be rejected'
);

-- ============================================================
-- PURCHASE_RECEIPT_ITEMS: received_qty > 0 CHECK
-- ============================================================

SELECT throws_ok(
  $$ INSERT INTO public.purchase_receipt_items (id, company_id, purchase_receipt_id, purchase_order_item_id, variant_id, received_qty, unit_cost, subtotal)
     VALUES ('99998000-0000-0000-0000-000000000002', '99999999-9999-9999-9999-999999999999',
             '99997000-0000-0000-0000-000000000001', '99996000-0000-0000-0000-000000000001',
             '99993000-0000-0000-0000-000000000001', 0, 25.50, 0) $$,
  NULL,
  NULL,
  'Receipt items: received_qty <= 0 should be rejected'
);

-- ============================================================
-- PURCHASE_RECEIPTS: Invalid status CHECK constraint
-- ============================================================

SELECT throws_ok(
  $$ INSERT INTO public.purchase_receipts (id, company_id, branch_id, purchase_order_id, receipt_number, status)
     VALUES ('99997000-0000-0000-0000-000000000002', '99999999-9999-9999-9999-999999999999',
             '99991111-1111-1111-1111-111111111111', '99995000-0000-0000-0000-000000000001',
             'REC-INVALID', 'bogus_status') $$,
  NULL,
  NULL,
  'Receipt status: invalid status value should be rejected'
);

-- ============================================================
-- COMPOSITE FK: Cross-tenant purchase_order referencing supplier from other company
-- ============================================================

SELECT throws_ok(
  $$ INSERT INTO public.purchase_orders (id, company_id, branch_id, supplier_id, order_number, status)
     VALUES ('99995000-0000-0000-0000-000000000003', '99999999-9999-9999-9999-999999999999',
             '99991111-1111-1111-1111-111111111111',
             '88884000-0000-0000-0000-000000000001', -- Company B's supplier
             'PO-CROSS-SUP', 'draft') $$,
  NULL,
  NULL,
  'Cross-tenant FK: PO referencing another company supplier should fail'
);

-- ============================================================
-- COMPOSITE FK: Cross-tenant purchase_order referencing branch from other company
-- ============================================================

SELECT throws_ok(
  $$ INSERT INTO public.purchase_orders (id, company_id, branch_id, supplier_id, order_number, status)
     VALUES ('99995000-0000-0000-0000-000000000004', '99999999-9999-9999-9999-999999999999',
             '88881111-1111-1111-1111-111111111111', -- Company B's branch
             '99994000-0000-0000-0000-000000000001',
             'PO-CROSS-BRANCH', 'draft') $$,
  NULL,
  NULL,
  'Cross-tenant FK: PO referencing another company branch should fail'
);

-- ============================================================
-- COMPOSITE FK: purchase_order_item referencing variant from other company
-- ============================================================

SELECT throws_ok(
  $$ INSERT INTO public.purchase_order_items (id, company_id, purchase_order_id, variant_id, ordered_qty, unit_cost)
     VALUES ('99996000-0000-0000-0000-000000000004', '99999999-9999-9999-9999-999999999999',
             '99995000-0000-0000-0000-000000000001',
             '88883000-0000-0000-0000-000000000001', -- Company B's variant
             5, 30.00) $$,
  NULL,
  NULL,
  'Cross-tenant FK: PO item referencing another company variant should fail'
);

-- ============================================================
-- COMPOSITE FK: purchase_order_item referencing PO from other company
-- ============================================================

SELECT throws_ok(
  $$ INSERT INTO public.purchase_order_items (id, company_id, purchase_order_id, variant_id, ordered_qty, unit_cost)
     VALUES ('99996000-0000-0000-0000-000000000005', '99999999-9999-9999-9999-999999999999',
             '88885000-0000-0000-0000-000000000001', -- Company B's PO
             '99993000-0000-0000-0000-000000000001',
             5, 30.00) $$,
  NULL,
  NULL,
  'Cross-tenant FK: PO item referencing another company PO should fail'
);

-- ============================================================
-- COMPOSITE FK: purchase_receipt referencing PO from other company
-- ============================================================

SELECT throws_ok(
  $$ INSERT INTO public.purchase_receipts (id, company_id, branch_id, purchase_order_id, receipt_number)
     VALUES ('99997000-0000-0000-0000-000000000003', '99999999-9999-9999-9999-999999999999',
             '99991111-1111-1111-1111-111111111111',
             '88885000-0000-0000-0000-000000000001', -- Company B's PO
             'REC-CROSS-PO') $$,
  NULL,
  NULL,
  'Cross-tenant FK: receipt referencing another company PO should fail'
);

-- ============================================================
-- COMPOSITE FK: purchase_receipt referencing branch from other company
-- ============================================================

SELECT throws_ok(
  $$ INSERT INTO public.purchase_receipts (id, company_id, branch_id, purchase_order_id, receipt_number)
     VALUES ('99997000-0000-0000-0000-000000000004', '99999999-9999-9999-9999-999999999999',
             '88881111-1111-1111-1111-111111111111', -- Company B's branch
             '99995000-0000-0000-0000-000000000001',
             'REC-CROSS-BRANCH') $$,
  NULL,
  NULL,
  'Cross-tenant FK: receipt referencing another company branch should fail'
);

-- ============================================================
-- COMPOSITE FK: purchase_receipt_item referencing receipt from other company
-- ============================================================

-- First create a receipt in Company B for the cross-company test
INSERT INTO public.purchase_receipts (id, company_id, branch_id, purchase_order_id, receipt_number)
VALUES ('88887000-0000-0000-0000-000000000002', '88888888-8888-8888-8888-aaaaaaaaaaaa',
        '88881111-1111-1111-1111-111111111111', '88885000-0000-0000-0000-000000000001',
        'REC-CROSS-TEST');

SELECT throws_ok(
  $$ INSERT INTO public.purchase_receipt_items (id, company_id, purchase_receipt_id, purchase_order_item_id, variant_id, received_qty, unit_cost, subtotal)
     VALUES ('99998000-0000-0000-0000-000000000003', '99999999-9999-9999-9999-999999999999',
             '88887000-0000-0000-0000-000000000002', -- Company B's receipt
             '99996000-0000-0000-0000-000000000001',
             '99993000-0000-0000-0000-000000000001', 3, 25.50, 76.50) $$,
  NULL,
  NULL,
  'Cross-tenant FK: receipt item referencing another company receipt should fail'
);

-- ============================================================
-- COMPOSITE FK: purchase_receipt_item referencing variant from other company
-- ============================================================

SELECT throws_ok(
  $$ INSERT INTO public.purchase_receipt_items (id, company_id, purchase_receipt_id, purchase_order_item_id, variant_id, received_qty, unit_cost, subtotal)
     VALUES ('99998000-0000-0000-0000-000000000004', '99999999-9999-9999-9999-999999999999',
             '99997000-0000-0000-0000-000000000001',
             '99996000-0000-0000-0000-000000000001',
             '88883000-0000-0000-0000-000000000001', -- Company B's variant
             3, 25.50, 76.50) $$,
  NULL,
  NULL,
  'Cross-tenant FK: receipt item referencing another company variant should fail'
);

-- ============================================================
-- COMPOSITE FK: purchase_receipt_item referencing purchase_order_item from other company
-- ============================================================

-- First create a purchase_order_item in Company B for the cross-company test
INSERT INTO public.purchase_order_items (id, company_id, purchase_order_id, variant_id, ordered_qty, unit_cost)
VALUES ('88886000-0000-0000-0000-000000000001', '88888888-8888-8888-8888-aaaaaaaaaaaa',
        '88885000-0000-0000-0000-000000000001', '88883000-0000-0000-0000-000000000001',
        5, 30.00);

SELECT throws_ok(
  $$ INSERT INTO public.purchase_receipt_items (id, company_id, purchase_receipt_id, purchase_order_item_id, variant_id, received_qty, unit_cost, subtotal)
     VALUES ('99998000-0000-0000-0000-000000000005', '99999999-9999-9999-9999-999999999999',
             '99997000-0000-0000-0000-000000000001',
             '88886000-0000-0000-0000-000000000001', -- Company B's PO item
             '99993000-0000-0000-0000-000000000001',
             3, 25.50, 76.50) $$,
  NULL,
  NULL,
  'Cross-tenant FK: receipt item referencing another company PO item should fail'
);

-- ============================================================
-- COMPOSITE FK: Valid same-company references should succeed
-- ============================================================

SELECT lives_ok(
  $$ INSERT INTO public.purchase_order_items (id, company_id, purchase_order_id, variant_id, ordered_qty, unit_cost)
     VALUES ('99996000-0000-0000-0000-000000000006', '99999999-9999-9999-9999-999999999999',
             '99995000-0000-0000-0000-000000000001',
             '99993000-0000-0000-0000-000000000001',
             3, 15.00) $$,
  'Cross-tenant FK: valid same-company PO item should succeed'
);

-- ============================================================
-- CRITICAL COLUMN PROTECTION: purchase_order_items.received_qty
-- Requires authenticated context — use helper function pattern
-- ============================================================

CREATE OR REPLACE FUNCTION _set_purchasing_admin_context(p_company_id UUID)
RETURNS VOID AS $$
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object(
    'sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    'role', 'authenticated',
    'app_metadata', json_build_object(
      'company_id', p_company_id,
      'role', 'admin'
    )
  )::text, true);
  SET ROLE authenticated;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION _reset_purchasing_context()
RETURNS VOID AS $$
BEGIN
  RESET ROLE;
  PERFORM set_config('request.jwt.claims', '', true);
END;
$$ LANGUAGE plpgsql;

-- Create auth user + profile + company_users needed by RLS helpers
INSERT INTO auth.users (id, email, raw_app_meta_data, raw_user_meta_data)
VALUES ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'purchasing-admin@test.com',
        '{"company_id": "99999999-9999-9999-9999-999999999999", "role": "admin"}',
        '{"full_name": "Purchasing Admin"}')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.profiles (id, full_name)
VALUES ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'Purchasing Admin')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.company_users (user_id, company_id, role)
VALUES ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', '99999999-9999-9999-9999-999999999999', 'admin')
ON CONFLICT (user_id, company_id) DO NOTHING;

-- Authenticated admin: direct received_qty update should fail
SELECT _set_purchasing_admin_context('99999999-9999-9999-9999-999999999999');

SELECT throws_ok(
  $$ UPDATE public.purchase_order_items
     SET received_qty = 5
     WHERE id = '99996000-0000-0000-0000-000000000001' $$,
  NULL,
  'Direct received_qty edits on purchase_order_items are prohibited; use purchasing RPCs',
  'Critical col protection: authenticated received_qty update should fail'
);

-- Authenticated admin: direct status update on purchase_orders should fail
SELECT throws_ok(
  $$ UPDATE public.purchase_orders
     SET status = 'received'
     WHERE id = '99995000-0000-0000-0000-000000000001' $$,
  NULL,
  'Direct status edits on purchase_orders are prohibited; use purchasing RPCs',
  'Critical col protection: authenticated status update should fail'
);

SELECT _reset_purchasing_context();

-- ============================================================
-- set_updated_at TRIGGER: verifies updated_at changes on UPDATE
-- ============================================================

-- Update a non-critical column (notes) and verify updated_at changes
UPDATE public.purchase_orders
SET notes = 'Trigger test note'
WHERE id = '99995000-0000-0000-0000-000000000001';

SELECT is(
  (SELECT (updated_at > created_at) FROM public.purchase_orders WHERE id = '99995000-0000-0000-0000-000000000001'),
  TRUE,
  'set_updated_at trigger: updated_at was updated on purchase_orders'
);

-- Verify set_updated_at on suppliers
UPDATE public.suppliers
SET notes = 'Trigger test'
WHERE id = '99994000-0000-0000-0000-000000000001';

SELECT is(
  (SELECT (updated_at > created_at) FROM public.suppliers WHERE id = '99994000-0000-0000-0000-000000000001'),
  TRUE,
  'set_updated_at trigger: updated_at was updated on suppliers'
);

-- Verify set_updated_at on purchase_order_items
UPDATE public.purchase_order_items
SET unit_cost = 26.00
WHERE id = '99996000-0000-0000-0000-000000000001';

SELECT is(
  (SELECT (updated_at > created_at) FROM public.purchase_order_items WHERE id = '99996000-0000-0000-0000-000000000001'),
  TRUE,
  'set_updated_at trigger: updated_at was updated on purchase_order_items'
);

-- Verify set_updated_at on purchase_receipts
UPDATE public.purchase_receipts
SET notes = 'Trigger test receipt'
WHERE id = '99997000-0000-0000-0000-000000000001';

SELECT is(
  (SELECT (updated_at > created_at) FROM public.purchase_receipts WHERE id = '99997000-0000-0000-0000-000000000001'),
  TRUE,
  'set_updated_at trigger: updated_at was updated on purchase_receipts'
);

-- Verify set_updated_at on purchase_receipt_items
UPDATE public.purchase_receipt_items
SET lot_code = 'LOT-TRIGGER'
WHERE id = '99998000-0000-0000-0000-000000000001';

SELECT is(
  (SELECT (updated_at > created_at) FROM public.purchase_receipt_items WHERE id = '99998000-0000-0000-0000-000000000001'),
  TRUE,
  'set_updated_at trigger: updated_at was updated on purchase_receipt_items'
);

-- ============================================================
-- Cleanup helper functions
-- ============================================================
DROP FUNCTION _set_purchasing_admin_context(UUID);
DROP FUNCTION _reset_purchasing_context();

-- ============================================================
-- Finish
-- ============================================================
SELECT * FROM finish();
ROLLBACK;
