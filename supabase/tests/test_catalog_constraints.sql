-- pgTAP: Catalog domain constraint tests
-- Verifies SKU case-insensitive unique, NULL barcode non-conflict,
-- active price uniqueness, category cycle detection, depth limit,
-- cross-tenant reference integrity (composite FKs), global base unit protection,
-- and product_prices.company_id matching variant's company_id.
-- (source: RC2, RC4, RC5, RC7, D10, D11, D12)

BEGIN;

-- Load pgTAP
CREATE EXTENSION IF NOT EXISTS pgtap;

SELECT plan(24);

-- ============================================================
-- Setup: Create companies and reference data for constraint tests
-- ============================================================
INSERT INTO public.companies (id, name, slug)
VALUES
  ('33333333-3333-3333-3333-333333333333', 'Constraint Test Co', 'constraint-test-co'),
  ('44444444-4444-4444-4444-444444444444', 'Other Co', 'other-co');

-- Shared reference data for Company A
INSERT INTO public.brands (id, company_id, name, slug)
VALUES ('c0000000-0000-0000-0000-000000000001', '33333333-3333-3333-3333-333333333333', 'Brand C1', 'brand-c1');

INSERT INTO public.categories (id, company_id, name, slug)
VALUES ('c1000000-0000-0000-0000-000000000001', '33333333-3333-3333-3333-333333333333', 'Cat C1', 'cat-c1');

INSERT INTO public.products (id, company_id, name, slug, brand_id, category_id)
VALUES ('c2000000-0000-0000-0000-000000000001', '33333333-3333-3333-3333-333333333333',
        'Product C1', 'product-c1',
        'c0000000-0000-0000-0000-000000000001', 'c1000000-0000-0000-0000-000000000001');

-- Shared reference data for Company B
INSERT INTO public.brands (id, company_id, name, slug)
VALUES ('d0000000-0000-0000-0000-000000000001', '44444444-4444-4444-4444-444444444444', 'Brand D1', 'brand-d1');

INSERT INTO public.categories (id, company_id, name, slug)
VALUES ('d1000000-0000-0000-0000-000000000001', '44444444-4444-4444-4444-444444444444', 'Cat D1', 'cat-d1');

INSERT INTO public.products (id, company_id, name, slug, brand_id, category_id)
VALUES ('d2000000-0000-0000-0000-000000000001', '44444444-4444-4444-4444-444444444444',
        'Product D1', 'product-d1',
        'd0000000-0000-0000-0000-000000000001', 'd1000000-0000-0000-0000-000000000001');

-- ============================================================
-- SKU: Case-insensitive uniqueness
-- ============================================================

-- Insert variant with SKU 'ABC-123'
INSERT INTO public.product_variants (id, company_id, product_id, sku, name)
VALUES ('c3000000-0000-0000-0000-000000000001', '33333333-3333-3333-3333-333333333333',
        'c2000000-0000-0000-0000-000000000001', 'ABC-123', 'Variant C1');

-- Try inserting variant with lowercase 'abc-123' — should fail (case-insensitive unique)
SELECT throws_ok(
  $$ INSERT INTO public.product_variants (id, company_id, product_id, sku, name)
     VALUES ('c3000000-0000-0000-0000-000000000002', '33333333-3333-3333-3333-333333333333',
            'c2000000-0000-0000-0000-000000000001', 'abc-123', 'Variant C2') $$,
  NULL,
  NULL,
  'SKU constraint: inserting "abc-123" after "ABC-123" should fail (case-insensitive unique)'
);

-- Different company can use same SKU value (different company_id)
SELECT lives_ok(
  $$ INSERT INTO public.product_variants (id, company_id, product_id, sku, name)
     VALUES ('d3000000-0000-0000-0000-000000000001', '44444444-4444-4444-4444-444444444444',
            'd2000000-0000-0000-0000-000000000001', 'abc-123', 'Variant D1') $$,
  'SKU constraint: same SKU value in different company is allowed'
);

-- NULL SKU are allowed (multiple NULLs, partial index excludes NULL)
SELECT lives_ok(
  $$ INSERT INTO public.product_variants (id, company_id, product_id, sku, name)
     VALUES ('c3000000-0000-0000-0000-000000000003', '33333333-3333-3333-3333-333333333333',
            'c2000000-0000-0000-0000-000000000001', NULL, 'Variant C2 No SKU') $$,
  'SKU constraint: NULL SKU is allowed (first NULL)'
);

SELECT lives_ok(
  $$ INSERT INTO public.product_variants (id, company_id, product_id, sku, name)
     VALUES ('c3000000-0000-0000-0000-000000000004', '33333333-3333-3333-3333-333333333333',
            'c2000000-0000-0000-0000-000000000001', NULL, 'Variant C3 No SKU') $$,
  'SKU constraint: NULL SKU is allowed (second NULL, no conflict)'
);

-- ============================================================
-- Barcode: NULL barcodes do not conflict; non-NULL values unique per company
-- ============================================================

-- Insert variant with barcode in Company C
INSERT INTO public.product_variants (id, company_id, product_id, sku, barcode, name)
VALUES ('c3000000-0000-0000-0000-000000000010', '33333333-3333-3333-3333-333333333333',
        'c2000000-0000-0000-0000-000000000001', 'SKU-C5', '9876543210', 'Variant C5 With Barcode');

-- Duplicate barcode within same company (C) — should FAIL
SELECT throws_ok(
  $$ INSERT INTO public.product_variants (id, company_id, product_id, sku, barcode, name)
     VALUES ('c3000000-0000-0000-0000-000000000011', '33333333-3333-3333-3333-333333333333',
            'c2000000-0000-0000-0000-000000000001', 'SKU-C6', '9876543210', 'Variant C6 Dupe Barcode') $$,
  NULL,
  NULL,
  'Barcode: Duplicate non-NULL barcode in same company should fail'
);

-- Same barcode value in different company (D) — should SUCCEED (cross-company allowed)
SELECT lives_ok(
  $$ INSERT INTO public.product_variants (id, company_id, product_id, sku, barcode, name)
     VALUES ('d3000000-0000-0000-0000-000000000002', '44444444-4444-4444-4444-444444444444',
            'd2000000-0000-0000-0000-000000000001', 'SKU-D2', '9876543210', 'Variant D2 Same Barcode Diff Company') $$,
  'Barcode: Same barcode in different company is allowed (cross-company)'
);

-- ============================================================
-- Active price uniqueness: only one effective_until IS NULL per variant
-- ============================================================
INSERT INTO public.product_variants (id, company_id, product_id, sku, name)
VALUES ('c3000000-0000-0000-0000-000000000006', '33333333-3333-3333-3333-333333333333',
        'c2000000-0000-0000-0000-000000000001', 'SKU-PRICE', 'Variant With Price');

-- Insert first active price (effective_until IS NULL)
INSERT INTO public.product_prices (id, company_id, variant_id, price, currency, effective_from)
VALUES ('c4000000-0000-0000-0000-000000000001', '33333333-3333-3333-3333-333333333333',
        'c3000000-0000-0000-0000-000000000006', 10.00, 'MXN', now());

-- Try inserting second active price for same variant (effective_until IS NULL) — should fail
SELECT throws_ok(
  $$ INSERT INTO public.product_prices (id, company_id, variant_id, price, currency, effective_from)
     VALUES ('c4000000-0000-0000-0000-000000000002', '33333333-3333-3333-3333-333333333333',
            'c3000000-0000-0000-0000-000000000006', 12.00, 'MXN', now()) $$,
  NULL,
  NULL,
  'Active price uniqueness: second active price for same variant should fail'
);

-- Insert a closed price (effective_until set) — should succeed
SELECT lives_ok(
  $$ INSERT INTO public.product_prices (id, company_id, variant_id, price, currency, effective_from, effective_until)
     VALUES ('c4000000-0000-0000-0000-000000000003', '33333333-3333-3333-3333-333333333333',
            'c3000000-0000-0000-0000-000000000006', 8.00, 'MXN',
            now() - interval '1 month', now() - interval '1 day') $$,
  'Active price uniqueness: closed price (effective_until set) coexists with active price'
);

-- ============================================================
-- Category cycle detection
-- ============================================================

-- Root category
INSERT INTO public.categories (id, company_id, name, slug)
VALUES ('c5000000-0000-0000-0000-000000000001', '33333333-3333-3333-3333-333333333333', 'Cycle Root', 'cycle-root');

-- Direct self-reference cycle — should be rejected
SELECT throws_ok(
  $$ UPDATE public.categories SET parent_id = id WHERE id = 'c5000000-0000-0000-0000-000000000001' $$,
  NULL,
  NULL,
  'Category cycle: self-reference should be rejected'
);

-- Build chain: Root → A
INSERT INTO public.categories (id, company_id, name, slug, parent_id)
VALUES ('c5000000-0000-0000-0000-000000000002', '33333333-3333-3333-3333-333333333333', 'Cycle A', 'cycle-a', 'c5000000-0000-0000-0000-000000000001');

-- Try to update root to point to A (would create Root → A → Root)
SELECT throws_ok(
  $$ UPDATE public.categories SET parent_id = 'c5000000-0000-0000-0000-000000000002' WHERE id = 'c5000000-0000-0000-0000-000000000001' $$,
  NULL,
  NULL,
  'Category cycle: circular parent reference should be rejected'
);

-- ============================================================
-- Category depth limit: max depth 5
-- ============================================================

-- Build a chain of depth 5 (root → level 2 → level 3 → level 4 → level 5)
INSERT INTO public.categories (id, company_id, name, slug, parent_id)
VALUES
  ('c5100000-0000-0000-0000-000000000001', '33333333-3333-3333-3333-333333333333', 'Depth 1', 'depth-1', NULL),
  ('c5100000-0000-0000-0000-000000000002', '33333333-3333-3333-3333-333333333333', 'Depth 2', 'depth-2', 'c5100000-0000-0000-0000-000000000001'),
  ('c5100000-0000-0000-0000-000000000003', '33333333-3333-3333-3333-333333333333', 'Depth 3', 'depth-3', 'c5100000-0000-0000-0000-000000000002'),
  ('c5100000-0000-0000-0000-000000000004', '33333333-3333-3333-3333-333333333333', 'Depth 4', 'depth-4', 'c5100000-0000-0000-0000-000000000003'),
  ('c5100000-0000-0000-0000-000000000005', '33333333-3333-3333-3333-333333333333', 'Depth 5', 'depth-5', 'c5100000-0000-0000-0000-000000000004');

-- Depth 5 is allowed, but depth 6 should be rejected
SELECT throws_ok(
  $$ INSERT INTO public.categories (id, company_id, name, slug, parent_id)
     VALUES ('c5100000-0000-0000-0000-000000000006', '33333333-3333-3333-3333-333333333333', 'Depth 6', 'depth-6', 'c5100000-0000-0000-0000-000000000005') $$,
  NULL,
  NULL,
  'Category depth: depth > 5 should be rejected'
);

-- Verify depth 5 was inserted successfully
SELECT is(
  (SELECT count(*)::bigint FROM public.categories WHERE slug = 'depth-5'),
  1::bigint,
  'Category depth: depth 5 was successfully inserted'
);

-- ============================================================
-- product_variants.name NOT NULL constraint
-- ============================================================
SELECT throws_ok(
  $$ INSERT INTO public.product_variants (id, company_id, product_id, sku, name)
     VALUES ('c3000000-0000-0000-0000-000000000099', '33333333-3333-3333-3333-333333333333',
            'c2000000-0000-0000-0000-000000000001', 'SKU-NOTNULL', NULL) $$,
  NULL,
  NULL,
  'Variant name: NOT NULL constraint should reject NULL name'
);

-- ============================================================
-- product_prices currency defaults to MXN
-- ============================================================
INSERT INTO public.product_variants (id, company_id, product_id, sku, name)
VALUES ('c3000000-0000-0000-0000-000000000007', '33333333-3333-3333-3333-333333333333',
        'c2000000-0000-0000-0000-000000000001', 'SKU-CURR', 'Variant Currency Test');

INSERT INTO public.product_prices (id, company_id, variant_id, price, effective_from)
VALUES ('c4000000-0000-0000-0000-000000000010', '33333333-3333-3333-3333-333333333333',
        'c3000000-0000-0000-0000-000000000007', 5.00, now());

SELECT is(
  (SELECT currency FROM public.product_prices WHERE id = 'c4000000-0000-0000-0000-000000000010'),
  'MXN',
  'Price currency: defaults to MXN'
);

-- ============================================================
-- Cross-tenant reference integrity: composite FKs
-- A row in Company A MUST NOT reference a row in Company B.
-- These constraints enforce tenant isolation beyond RLS visibility.
-- (source: RC7 security remediation)
-- ============================================================

-- 1. Product referencing cross-tenant brand should fail
SELECT throws_ok(
  $$ INSERT INTO public.products (id, company_id, name, slug, brand_id, category_id)
     VALUES ('cccc0000-0000-0000-0000-000000000001', '33333333-3333-3333-3333-333333333333',
             'Evil Product', 'evil-product',
             'd0000000-0000-0000-0000-000000000001',  -- Company D's brand
             'c1000000-0000-0000-0000-000000000001') $$,
  NULL,
  NULL,
  'Cross-tenant FK: product referencing another company brand should fail'
);

-- 2. Product referencing cross-tenant category should fail
SELECT throws_ok(
  $$ INSERT INTO public.products (id, company_id, name, slug, brand_id, category_id)
     VALUES ('cccc0000-0000-0000-0000-000000000002', '33333333-3333-3333-3333-333333333333',
             'Evil Product 2', 'evil-product-2',
             'c0000000-0000-0000-0000-000000000001',  -- Company C's brand (same company — OK)
             'd1000000-0000-0000-0000-000000000001') $$,  -- Company D's category
  NULL,
  NULL,
  'Cross-tenant FK: product referencing another company category should fail'
);

-- 3. Variant referencing cross-tenant product should fail
SELECT throws_ok(
  $$ INSERT INTO public.product_variants (id, company_id, product_id, sku, name)
     VALUES ('cccc0000-0000-0000-0000-000000000003', '33333333-3333-3333-3333-333333333333',
             'd2000000-0000-0000-0000-000000000001',  -- Company D's product
             'SKU-EVIL', 'Evil Variant') $$,
  NULL,
  NULL,
  'Cross-tenant FK: variant referencing another company product should fail'
);

-- 4. Variant referencing global base unit should fail (company mismatch)
-- Global units have company_id = '00000000-...' which differs from any tenant
SELECT throws_ok(
  $$ INSERT INTO public.product_variants (id, company_id, product_id, sku, name, unit_id)
     VALUES ('cccc0000-0000-0000-0000-000000000004', '33333333-3333-3333-3333-333333333333',
             'c2000000-0000-0000-0000-000000000001',  -- Company C's product (same company — OK)
             'SKU-GLOBAL-UNIT', 'Variant With Global Unit',
             (SELECT id FROM public.units WHERE company_id = '00000000-0000-0000-0000-000000000000' LIMIT 1)) $$,
  NULL,
  NULL,
  'Cross-tenant FK: variant referencing global base unit should fail (company mismatch)'
);

-- 5. Category parent referencing cross-tenant category should fail
SELECT throws_ok(
  $$ INSERT INTO public.categories (id, company_id, name, slug, parent_id)
     VALUES ('cccc0000-0000-0000-0000-000000000005', '33333333-3333-3333-3333-333333333333',
             'Evil Category', 'evil-category',
             'd1000000-0000-0000-0000-000000000001') $$,  -- Company D's category
  NULL,
  NULL,
  'Cross-tenant FK: category parent referencing another company category should fail'
);

-- 6. Price referencing cross-tenant variant should fail
SELECT throws_ok(
  $$ INSERT INTO public.product_prices (id, company_id, variant_id, price, currency, effective_from)
     VALUES ('cccc0000-0000-0000-0000-000000000006', '33333333-3333-3333-3333-333333333333',
             'd3000000-0000-0000-0000-000000000001',  -- Company D's variant
             99.99, 'MXN', now()) $$,
  NULL,
  NULL,
  'Cross-tenant FK: price referencing another company variant should fail'
);

-- 7. Price with mismatched company_id vs variant should fail
-- (variant belongs to Company C, but price claims Company D)
SELECT throws_ok(
  $$ INSERT INTO public.product_prices (id, company_id, variant_id, price, currency, effective_from)
     VALUES ('cccc0000-0000-0000-0000-000000000007', '44444444-4444-4444-4444-444444444444',
             'c3000000-0000-0000-0000-000000000001',  -- Company C's variant
             19.99, 'MXN', now()) $$,
  NULL,
  NULL,
  'Cross-tenant FK: price with different company_id than variant should fail'
);

-- 8. Valid same-company references should succeed
SELECT lives_ok(
  $$ INSERT INTO public.product_variants (id, company_id, product_id, sku, name, unit_id)
     VALUES ('c3000000-0000-0000-0000-000000000020', '33333333-3333-3333-3333-333333333333',
             'c2000000-0000-0000-0000-000000000001',  -- same company
             'SKU-SAME-CO', 'Same Company Variant', NULL) $$,
  'Cross-tenant FK: variant with same-company product_id should succeed'
);

-- 9. Valid same-company category parent reference should succeed
SELECT lives_ok(
  $$ INSERT INTO public.categories (id, company_id, name, slug, parent_id)
     VALUES ('cccc0000-0000-0000-0000-000000000008', '33333333-3333-3333-3333-333333333333',
             'Valid Child Cat', 'valid-child-cat',
             'c1000000-0000-0000-0000-000000000001') $$,
  'Cross-tenant FK: category parent referencing same-company category should succeed'
);

-- ============================================================
-- Global base unit deletion protection
-- Physical DELETE of global units (company_id = '00000000-...') must be blocked
-- by trigger, even for service_role or postgres.
-- ============================================================
SELECT throws_ok(
  $$ DELETE FROM public.units WHERE company_id = '00000000-0000-0000-0000-000000000000' $$,
  NULL,
  NULL,
  'Global unit protection: physical DELETE of global base units should fail'
);

-- ============================================================
-- Finish
-- ============================================================
SELECT * FROM finish();
ROLLBACK;