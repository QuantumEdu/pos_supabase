-- pgTAP: Catalog domain RLS isolation tests
-- Verifies that company A cannot see company B data for all 6 catalog tables,
-- unauthenticated users see nothing, admins see own-company rows,
-- service_role bypasses RLS, cross-tenant INSERT/UPDATE is blocked,
-- DELETE is blocked (no DELETE policies), and global base units are visible
-- but not editable by tenants.
-- (source: RC7, D13)

BEGIN;

-- Load pgTAP
CREATE EXTENSION IF NOT EXISTS pgtap;

SELECT plan(58);

-- ============================================================
-- Setup: Insert test data as postgres (bypasses RLS)
-- ============================================================

-- Companies
INSERT INTO public.companies (id, name, slug)
VALUES
  ('11111111-1111-1111-1111-111111111111', 'Company A', 'company-a'),
  ('22222222-2222-2222-2222-222222222222', 'Company B', 'company-b');

-- Create admin profile and company_users entry for Company A
-- This is needed so get_user_role() can work via JWT fallback
-- First create the auth user, then the profile, then company_users
INSERT INTO auth.users (id, email, raw_app_meta_data, raw_user_meta_data)
VALUES ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'admin-a@test.com',
        '{"company_id": "11111111-1111-1111-1111-111111111111", "role": "admin"}',
        '{"full_name": "Test Admin A"}')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.profiles (id, full_name)
VALUES ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'Test Admin A');

INSERT INTO public.company_users (user_id, company_id, role)
VALUES ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', '11111111-1111-1111-1111-111111111111', 'admin');

-- Create cashier for Company A
INSERT INTO auth.users (id, email, raw_app_meta_data, raw_user_meta_data)
VALUES ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'cashier-a@test.com',
        '{"company_id": "11111111-1111-1111-1111-111111111111", "role": "cashier"}',
        '{"full_name": "Test Cashier A"}')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.profiles (id, full_name)
VALUES ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'Test Cashier A');

INSERT INTO public.company_users (user_id, company_id, role)
VALUES ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', '11111111-1111-1111-1111-111111111111', 'cashier');

-- Brands
INSERT INTO public.brands (id, company_id, name, slug) VALUES
  ('a0000000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'Brand A1', 'brand-a1'),
  ('a0000000-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', 'Brand A2', 'brand-a2'),
  ('b0000000-0000-0000-0000-000000000001', '22222222-2222-2222-2222-222222222222', 'Brand B1', 'brand-b1');

-- Categories
INSERT INTO public.categories (id, company_id, name, slug) VALUES
  ('a1000000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'Cat A Root', 'cat-a-root'),
  ('b1000000-0000-0000-0000-000000000001', '22222222-2222-2222-2222-222222222222', 'Cat B Root', 'cat-b-root');

-- Products
INSERT INTO public.products (id, company_id, name, slug, brand_id, category_id) VALUES
  ('a2000000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'Product A1', 'product-a1',
   'a0000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000001'),
  ('b2000000-0000-0000-0000-000000000001', '22222222-2222-2222-2222-222222222222', 'Product B1', 'product-b1',
   'b0000000-0000-0000-0000-000000000001', 'b1000000-0000-0000-0000-000000000001');

-- Variants
INSERT INTO public.product_variants (id, company_id, product_id, sku, name) VALUES
  ('a3000000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111',
   'a2000000-0000-0000-0000-000000000001', 'SKU-A1', 'Variant A1'),
  ('b3000000-0000-0000-0000-000000000001', '22222222-2222-2222-2222-222222222222',
   'b2000000-0000-0000-0000-000000000001', 'SKU-B1', 'Variant B1');

-- Tenant-owned units for Company A
INSERT INTO public.units (id, company_id, name, abbreviation) VALUES
  ('a5000000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'Caja', 'Cja');

-- Prices
INSERT INTO public.product_prices (id, company_id, variant_id, price, currency, effective_from) VALUES
  ('a4000000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111',
   'a3000000-0000-0000-0000-000000000001', 99.99, 'MXN', now()),
  ('b4000000-0000-0000-0000-000000000001', '22222222-2222-2222-2222-222222222222',
   'b3000000-0000-0000-0000-000000000001', 49.99, 'MXN', now());

-- ============================================================
-- Helper functions for RLS context switching
-- ============================================================
CREATE OR REPLACE FUNCTION _set_rls_context(p_company_id UUID, p_role TEXT)
RETURNS VOID AS $$
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object(
    'sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    'role', 'authenticated',
    'app_metadata', json_build_object(
      'company_id', p_company_id,
      'role', p_role
    )
  )::text, true);
  SET ROLE authenticated;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION _reset_rls_context()
RETURNS VOID AS $$
BEGIN
  RESET ROLE;
  PERFORM set_config('request.jwt.claims', '', true);
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- Test 1-3: Brands RLS — Company A admin sees own, not cross-tenant
-- ============================================================
SELECT _set_rls_context('11111111-1111-1111-1111-111111111111', 'admin');

SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.brands $$,
  ARRAY[2::bigint],
  'RLS brands: Admin in Company A sees 2 own-company rows'
);

SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.brands WHERE company_id != '11111111-1111-1111-1111-111111111111' $$,
  ARRAY[0::bigint],
  'RLS brands: Admin in Company A sees 0 cross-tenant rows'
);

SELECT _reset_rls_context();

-- ============================================================
-- Test 4: Unauthenticated (anon) sees nothing (brands)
-- ============================================================
SET ROLE anon;

SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.brands $$,
  ARRAY[0::bigint],
  'RLS brands: Unauthenticated user sees 0 rows'
);

RESET ROLE;

-- ============================================================
-- Test 5-6: Categories RLS
-- ============================================================
SELECT _set_rls_context('11111111-1111-1111-1111-111111111111', 'admin');

SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.categories $$,
  ARRAY[1::bigint],
  'RLS categories: Admin in Company A sees 1 own-company row'
);

SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.categories WHERE company_id != '11111111-1111-1111-1111-111111111111' $$,
  ARRAY[0::bigint],
  'RLS categories: Admin in Company A sees 0 cross-tenant rows'
);

SELECT _reset_rls_context();

-- ============================================================
-- Test 7: Unauthenticated (anon) sees nothing (categories)
-- ============================================================
SET ROLE anon;

SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.categories $$,
  ARRAY[0::bigint],
  'RLS categories: Unauthenticated user sees 0 rows'
);

RESET ROLE;

-- ============================================================
-- Test 8-9: Units RLS — Company A sees own units + global base units
-- ============================================================
SELECT _set_rls_context('11111111-1111-1111-1111-111111111111', 'admin');

SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.units WHERE company_id = '11111111-1111-1111-1111-111111111111' $$,
  ARRAY[1::bigint],
  'RLS units: Admin in Company A sees 1 own-company unit'
);

-- Global base units are visible as templates via units_select_global_templates policy
SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.units WHERE company_id = '00000000-0000-0000-0000-000000000000' $$,
  ARRAY[8::bigint],
  'RLS units: Admin in Company A sees 8 global base unit templates'
);

SELECT _reset_rls_context();

-- ============================================================
-- Test 10: Unauthenticated (anon) sees nothing (units)
-- ============================================================
SET ROLE anon;

SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.units $$,
  ARRAY[0::bigint],
  'RLS units: Unauthenticated user sees 0 rows'
);

RESET ROLE;

-- ============================================================
-- Test 11-13: Products RLS
-- ============================================================
SELECT _set_rls_context('11111111-1111-1111-1111-111111111111', 'admin');

SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.products $$,
  ARRAY[1::bigint],
  'RLS products: Admin in Company A sees 1 own-company row'
);

SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.products WHERE company_id != '11111111-1111-1111-1111-111111111111' $$,
  ARRAY[0::bigint],
  'RLS products: Admin in Company A sees 0 cross-tenant rows'
);

SELECT _reset_rls_context();

SET ROLE anon;

SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.products $$,
  ARRAY[0::bigint],
  'RLS products: Unauthenticated user sees 0 rows'
);

RESET ROLE;

-- ============================================================
-- Test 14-16: Product Variants RLS
-- ============================================================
SELECT _set_rls_context('11111111-1111-1111-1111-111111111111', 'admin');

SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.product_variants $$,
  ARRAY[1::bigint],
  'RLS product_variants: Admin in Company A sees 1 own-company row'
);

SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.product_variants WHERE company_id != '11111111-1111-1111-1111-111111111111' $$,
  ARRAY[0::bigint],
  'RLS product_variants: Admin in Company A sees 0 cross-tenant rows'
);

SELECT _reset_rls_context();

SET ROLE anon;

SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.product_variants $$,
  ARRAY[0::bigint],
  'RLS product_variants: Unauthenticated user sees 0 rows'
);

RESET ROLE;

-- ============================================================
-- Test 17-19: Product Prices RLS
-- ============================================================
SELECT _set_rls_context('11111111-1111-1111-1111-111111111111', 'admin');

SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.product_prices $$,
  ARRAY[1::bigint],
  'RLS product_prices: Admin in Company A sees 1 own-company row'
);

SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.product_prices WHERE company_id != '11111111-1111-1111-1111-111111111111' $$,
  ARRAY[0::bigint],
  'RLS product_prices: Admin in Company A sees 0 cross-tenant rows'
);

SELECT _reset_rls_context();

SET ROLE anon;

SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.product_prices $$,
  ARRAY[0::bigint],
  'RLS product_prices: Unauthenticated user sees 0 rows'
);

RESET ROLE;

-- ============================================================
-- Test 20: Admin can INSERT into own company (brands)
-- ============================================================
SELECT _set_rls_context('11111111-1111-1111-1111-111111111111', 'admin');

SELECT lives_ok(
  $$ INSERT INTO public.brands (company_id, name, slug) VALUES ('11111111-1111-1111-1111-111111111111', 'Brand A3 RLS', 'brand-a3-rls') $$,
  'RLS brands: Admin can insert into own company'
);

SELECT _reset_rls_context();

-- Clean up test insert as postgres (bypasses RLS)
DELETE FROM public.brands WHERE slug = 'brand-a3-rls';

-- ============================================================
-- Test 21: Admin cannot INSERT into different company (brands)
-- ============================================================
SELECT _set_rls_context('11111111-1111-1111-1111-111111111111', 'admin');

SELECT throws_ok(
  $$ INSERT INTO public.brands (company_id, name, slug) VALUES ('22222222-2222-2222-2222-222222222222', 'Brand Cross', 'brand-cross-rls') $$,
  NULL,
  NULL,
  'RLS brands: Admin cannot insert into different company (WITH CHECK violation)'
);

SELECT _reset_rls_context();

-- ============================================================
-- Test 22: Cashier cannot INSERT (brands)
-- ============================================================
SELECT _set_rls_context('11111111-1111-1111-1111-111111111111', 'cashier');

SELECT throws_ok(
  $$ INSERT INTO public.brands (company_id, name, slug) VALUES ('11111111-1111-1111-1111-111111111111', 'Brand Cashier', 'brand-cashier') $$,
  NULL,
  NULL,
  'RLS brands: Cashier cannot insert (is_admin check fails)'
);

SELECT _reset_rls_context();

-- ============================================================
-- Test 23-24: Admin can INSERT categories/units into own company
-- ============================================================
SELECT _set_rls_context('11111111-1111-1111-1111-111111111111', 'admin');

SELECT lives_ok(
  $$ INSERT INTO public.categories (company_id, name, slug) VALUES ('11111111-1111-1111-1111-111111111111', 'Cat RLS Test', 'cat-rls-test') $$,
  'RLS categories: Admin can insert into own company'
);

SELECT lives_ok(
  $$ INSERT INTO public.units (company_id, name, abbreviation) VALUES ('11111111-1111-1111-1111-111111111111', 'Unit RLS Test', 'urt') $$,
  'RLS units: Admin can insert into own company'
);

SELECT _reset_rls_context();

-- Clean up
DELETE FROM public.categories WHERE slug = 'cat-rls-test';
DELETE FROM public.units WHERE name = 'Unit RLS Test';

-- ============================================================
-- Test 25-27: Admin can INSERT products/variants/prices into own company
-- ============================================================
SELECT _set_rls_context('11111111-1111-1111-1111-111111111111', 'admin');

SELECT lives_ok(
  $$ INSERT INTO public.products (company_id, name, slug) VALUES ('11111111-1111-1111-1111-111111111111', 'Product RLS Test', 'product-rls-test') $$,
  'RLS products: Admin can insert into own company'
);

SELECT lives_ok(
  $$ INSERT INTO public.product_variants (id, company_id, product_id, sku, name)
     VALUES ('a3011000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111',
             'a2000000-0000-0000-0000-000000000001', 'SKU-RLS-TEST', 'Variant RLS Test') $$,
  'RLS product_variants: Admin can insert into own company'
);

-- Insert a closed price (effective_until set) to avoid unique constraint conflict
SELECT lives_ok(
  $$ INSERT INTO public.product_prices (id, company_id, variant_id, price, currency, effective_from, effective_until)
     VALUES ('a4011000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111',
             'a3011000-0000-0000-0000-000000000001', 5.00, 'MXN',
             now() - interval '2 days', now() - interval '1 day') $$,
  'RLS product_prices: Admin can insert into own company'
);

SELECT _reset_rls_context();

-- Clean up
DELETE FROM public.product_prices WHERE id = 'a4011000-0000-0000-0000-000000000001';
DELETE FROM public.product_variants WHERE id = 'a3011000-0000-0000-0000-000000000001';
DELETE FROM public.products WHERE slug = 'product-rls-test';

-- ============================================================
-- Test 28-31: Admin cannot INSERT into different company (4 tables)
-- ============================================================
SELECT _set_rls_context('11111111-1111-1111-1111-111111111111', 'admin');

SELECT throws_ok(
  $$ INSERT INTO public.categories (company_id, name, slug) VALUES ('22222222-2222-2222-2222-222222222222', 'Evil Cat', 'evil-cat') $$,
  NULL,
  NULL,
  'RLS categories: Admin cannot insert into different company'
);

SELECT throws_ok(
  $$ INSERT INTO public.units (company_id, name, abbreviation) VALUES ('22222222-2222-2222-2222-222222222222', 'Evil Unit', 'eu') $$,
  NULL,
  NULL,
  'RLS units: Admin cannot insert into different company'
);

SELECT throws_ok(
  $$ INSERT INTO public.products (company_id, name, slug) VALUES ('22222222-2222-2222-2222-222222222222', 'Evil Product', 'evil-product') $$,
  NULL,
  NULL,
  'RLS products: Admin cannot insert into different company'
);

SELECT throws_ok(
  $$ INSERT INTO public.product_variants (company_id, product_id, sku, name)
     VALUES ('22222222-2222-2222-2222-222222222222',
             'a2000000-0000-0000-0000-000000000001', 'SKU-EVIL', 'Evil Variant') $$,
  NULL,
  NULL,
  'RLS product_variants: Admin cannot insert into different company'
);

-- Cross-tenant INSERT: product_prices — Company A admin tries to insert price for Company B variant
SELECT throws_ok(
  $$ INSERT INTO public.product_prices (company_id, variant_id, price, currency, effective_from)
     VALUES ('22222222-2222-2222-2222-222222222222',
             'b3000000-0000-0000-0000-000000000001', 19.99, 'MXN', now()) $$,
  NULL,
  NULL,
  'RLS product_prices: Admin cannot insert into different company'
);

SELECT _reset_rls_context();

-- ============================================================
-- Test 32-34: Cashier cannot INSERT into categories, products, units
-- ============================================================
SELECT _set_rls_context('11111111-1111-1111-1111-111111111111', 'cashier');

SELECT throws_ok(
  $$ INSERT INTO public.categories (company_id, name, slug) VALUES ('11111111-1111-1111-1111-111111111111', 'Cat Cashier', 'cat-cashier') $$,
  NULL,
  NULL,
  'RLS categories: Cashier cannot insert (is_admin check fails)'
);

SELECT throws_ok(
  $$ INSERT INTO public.products (company_id, name, slug) VALUES ('11111111-1111-1111-1111-111111111111', 'Product Cashier', 'product-cashier') $$,
  NULL,
  NULL,
  'RLS products: Cashier cannot insert (is_admin check fails)'
);

SELECT throws_ok(
  $$ INSERT INTO public.units (company_id, name, abbreviation) VALUES ('11111111-1111-1111-1111-111111111111', 'Unit Cashier', 'uc') $$,
  NULL,
  NULL,
  'RLS units: Cashier cannot insert (is_admin check fails)'
);

SELECT throws_ok(
  $$ INSERT INTO public.product_variants (company_id, product_id, sku, name)
     VALUES ('11111111-1111-1111-1111-111111111111',
             'a2000000-0000-0000-0000-000000000001', 'SKU-CASHIER', 'Cashier Variant') $$,
  NULL,
  NULL,
  'RLS product_variants: Cashier cannot insert (is_admin check fails)'
);

SELECT throws_ok(
  $$ INSERT INTO public.product_prices (company_id, variant_id, price, currency, effective_from)
     VALUES ('11111111-1111-1111-1111-111111111111',
             'a3000000-0000-0000-0000-000000000001', 5.00, 'MXN', now()) $$,
  NULL,
  NULL,
  'RLS product_prices: Cashier cannot insert (is_admin check fails)'
);

SELECT _reset_rls_context();

-- ============================================================
-- Test 35-40: Admin can UPDATE own-company rows (6 tables)
-- ============================================================
SELECT _set_rls_context('11111111-1111-1111-1111-111111111111', 'admin');

SELECT lives_ok(
  $$ UPDATE public.brands SET name = 'Brand A1 Updated' WHERE id = 'a0000000-0000-0000-0000-000000000001' $$,
  'RLS brands: Admin can update own-company row'
);

SELECT lives_ok(
  $$ UPDATE public.categories SET name = 'Cat A Root Updated' WHERE id = 'a1000000-0000-0000-0000-000000000001' $$,
  'RLS categories: Admin can update own-company row'
);

SELECT lives_ok(
  $$ UPDATE public.units SET abbreviation = 'Cja2' WHERE id = 'a5000000-0000-0000-0000-000000000001' $$,
  'RLS units: Admin can update own-company row'
);

SELECT lives_ok(
  $$ UPDATE public.products SET name = 'Product A1 Updated' WHERE id = 'a2000000-0000-0000-0000-000000000001' $$,
  'RLS products: Admin can update own-company row'
);

SELECT lives_ok(
  $$ UPDATE public.product_variants SET name = 'Variant A1 Updated' WHERE id = 'a3000000-0000-0000-0000-000000000001' $$,
  'RLS product_variants: Admin can update own-company row'
);

SELECT lives_ok(
  $$ UPDATE public.product_prices SET price = 89.99 WHERE id = 'a4000000-0000-0000-0000-000000000001' $$,
  'RLS product_prices: Admin can update own-company row'
);

SELECT _reset_rls_context();

-- Revert updates (as postgres, bypasses RLS)
UPDATE public.brands SET name = 'Brand A1' WHERE id = 'a0000000-0000-0000-0000-000000000001';
UPDATE public.categories SET name = 'Cat A Root' WHERE id = 'a1000000-0000-0000-0000-000000000001';
UPDATE public.units SET abbreviation = 'Cja' WHERE id = 'a5000000-0000-0000-0000-000000000001';
UPDATE public.products SET name = 'Product A1' WHERE id = 'a2000000-0000-0000-0000-000000000001';
UPDATE public.product_variants SET name = 'Variant A1' WHERE id = 'a3000000-0000-0000-0000-000000000001';
UPDATE public.product_prices SET price = 99.99 WHERE id = 'a4000000-0000-0000-0000-000000000001';

-- ============================================================
-- Test 41-46: Admin cannot UPDATE cross-tenant rows (6 tables)
-- UPDATE on Company B rows is silently blocked by USING clause (0 rows affected).
-- We verify rows are unchanged by checking as postgres (no RLS).
-- ============================================================
SELECT _set_rls_context('11111111-1111-1111-1111-111111111111', 'admin');

-- Update attempts on Company B rows: RLS USING clause filters them out
UPDATE public.brands SET name = 'Hacked Brand' WHERE id = 'b0000000-0000-0000-0000-000000000001';
UPDATE public.categories SET name = 'Hacked Cat' WHERE id = 'b1000000-0000-0000-0000-000000000001';
UPDATE public.products SET name = 'Hacked Product' WHERE id = 'b2000000-0000-0000-0000-000000000001';
UPDATE public.product_variants SET name = 'Hacked Variant' WHERE id = 'b3000000-0000-0000-0000-000000000001';
UPDATE public.units SET name = 'Hacked Unit' WHERE id IN (SELECT id FROM public.units WHERE company_id = '22222222-2222-2222-2222-222222222222' LIMIT 1);
UPDATE public.product_prices SET price = 0.01 WHERE id = 'b4000000-0000-0000-0000-000000000001';

SELECT _reset_rls_context();

-- Now check as postgres (no RLS) that rows are unchanged
SELECT is(
  (SELECT name FROM public.brands WHERE id = 'b0000000-0000-0000-0000-000000000001'),
  'Brand B1',
  'RLS brands: Admin cannot update Company B rows (name unchanged)'
);

SELECT is(
  (SELECT name FROM public.categories WHERE id = 'b1000000-0000-0000-0000-000000000001'),
  'Cat B Root',
  'RLS categories: Admin cannot update Company B rows (name unchanged)'
);

SELECT is(
  (SELECT name FROM public.products WHERE id = 'b2000000-0000-0000-0000-000000000001'),
  'Product B1',
  'RLS products: Admin cannot update Company B rows (name unchanged)'
);

SELECT is(
  (SELECT name FROM public.product_variants WHERE id = 'b3000000-0000-0000-0000-000000000001'),
  'Variant B1',
  'RLS product_variants: Admin cannot update Company B rows (name unchanged)'
);

SELECT is(
  (SELECT count(*)::bigint FROM public.units WHERE company_id = '22222222-2222-2222-2222-222222222222' AND name = 'Hacked Unit'),
  0::bigint,
  'RLS units: Admin cannot update Company B rows (0 rows changed)'
);

SELECT is(
  (SELECT price FROM public.product_prices WHERE id = 'b4000000-0000-0000-0000-000000000001'),
  49.99,
  'RLS product_prices: Admin cannot update Company B rows (price unchanged)'
);

-- ============================================================
-- Test 44: Admin cannot UPDATE global base units
-- ============================================================
SELECT _set_rls_context('11111111-1111-1111-1111-111111111111', 'admin');

UPDATE public.units SET abbreviation = 'HACKED' WHERE company_id = '00000000-0000-0000-0000-000000000000';

SELECT _reset_rls_context();

-- Verify as postgres that global units were not modified
SELECT is(
  (SELECT count(*)::bigint FROM public.units WHERE company_id = '00000000-0000-0000-0000-000000000000' AND abbreviation = 'HACKED'),
  0::bigint,
  'RLS units: Admin cannot update global base unit templates (0 rows changed)'
);

-- ============================================================
-- Test: DELETE is blocked for all catalog tables (no DELETE GRANTs)
-- No DELETE privilege is granted to authenticated role on catalog tables.
-- Logical deletion (is_active=false) is the only supported path.
-- ============================================================

-- All 6 catalog tables: authenticated role has no DELETE privilege
SET ROLE authenticated;

SELECT throws_ok(
  $$ DELETE FROM public.brands WHERE id = 'a0000000-0000-0000-0000-000000000001' $$,
  '42501',
  NULL,
  'RLS brands: DELETE blocked (insufficient privilege)'
);

SELECT throws_ok(
  $$ DELETE FROM public.categories WHERE id = 'a1000000-0000-0000-0000-000000000001' $$,
  '42501',
  NULL,
  'RLS categories: DELETE blocked (insufficient privilege)'
);

SELECT throws_ok(
  $$ DELETE FROM public.products WHERE id = 'a2000000-0000-0000-0000-000000000001' $$,
  '42501',
  NULL,
  'RLS products: DELETE blocked (insufficient privilege)'
);

SELECT throws_ok(
  $$ DELETE FROM public.product_variants WHERE id = 'a3000000-0000-0000-0000-000000000001' $$,
  '42501',
  NULL,
  'RLS product_variants: DELETE blocked (insufficient privilege)'
);

-- Units: authenticated role has no DELETE privilege (tested separately because
-- global units also have a trigger preventing physical deletion even for superusers)
SELECT throws_ok(
  $$ DELETE FROM public.units WHERE id = 'a5000000-0000-0000-0000-000000000001' $$,
  '42501',
  NULL,
  'RLS units: DELETE blocked (insufficient privilege)'
);

SELECT throws_ok(
  $$ DELETE FROM public.product_prices WHERE id = 'a4000000-0000-0000-0000-000000000001' $$,
  '42501',
  NULL,
  'RLS product_prices: DELETE blocked (insufficient privilege)'
);

RESET ROLE;

-- ============================================================
-- Test 47-49: service_role can see all rows
-- ============================================================
SET ROLE service_role;

SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.brands
     WHERE company_id IN ('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222') $$,
  ARRAY[3::bigint],
  'RLS brands: service_role can see all fixture rows (3 brands)'
);

SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.categories
     WHERE company_id IN ('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222') $$,
  ARRAY[2::bigint],
  'RLS categories: service_role can see all fixture rows (2 categories)'
);

SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.units
     WHERE company_id IN ('00000000-0000-0000-0000-000000000000', '11111111-1111-1111-1111-111111111111') $$,
  ARRAY[9::bigint],
  'RLS units: service_role can see all fixture rows (8 global + 1 Company A)'
);

RESET ROLE;

-- Drop helper functions
DROP FUNCTION _set_rls_context(UUID, TEXT);
DROP FUNCTION _reset_rls_context();

-- ============================================================
-- Finish
-- ============================================================
SELECT * FROM finish();
ROLLBACK;
