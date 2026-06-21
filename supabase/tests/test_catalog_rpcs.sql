-- pgTAP: Catalog domain RPC function tests
-- Verifies create_product_with_variant atomicity, deactivate_product cascading,
-- set_variant_price closing + concurrency, and CRUD RPC company isolation.
-- (source: RC1–RC5, D10–D12)

BEGIN;

-- Load pgTAP
CREATE EXTENSION IF NOT EXISTS pgtap;

SELECT plan(82);

-- ============================================================
-- Setup: Insert test data as postgres (bypasses RLS)
-- ============================================================

-- Create test companies
INSERT INTO public.companies (id, name, slug)
VALUES
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01', 'RPC Test Co A', 'rpc-test-co-a'),
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa02', 'RPC Test Co B', 'rpc-test-co-b');

-- Create admin user for Company A
INSERT INTO auth.users (id, email, raw_app_meta_data, raw_user_meta_data)
VALUES ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaa0001', 'admin-rpc-a@test.com',
        '{"company_id": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01", "role": "admin"}',
        '{"full_name": "RPC Admin A"}')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.profiles (id, full_name)
VALUES ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaa0001', 'RPC Admin A');

INSERT INTO public.company_users (user_id, company_id, role)
VALUES ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaa0001', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01', 'admin');

-- Create cashier user for Company A
INSERT INTO auth.users (id, email, raw_app_meta_data, raw_user_meta_data)
VALUES ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaa0002', 'cashier-rpc-a@test.com',
        '{"company_id": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01", "role": "cashier"}',
        '{"full_name": "RPC Cashier A"}')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.profiles (id, full_name)
VALUES ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaa0002', 'RPC Cashier A');

INSERT INTO public.company_users (user_id, company_id, role)
VALUES ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaa0002', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01', 'cashier');

-- Create admin user for Company B
INSERT INTO auth.users (id, email, raw_app_meta_data, raw_user_meta_data)
VALUES ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaa0003', 'admin-rpc-b@test.com',
        '{"company_id": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa02", "role": "admin"}',
        '{"full_name": "RPC Admin B"}')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.profiles (id, full_name)
VALUES ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaa0003', 'RPC Admin B');

INSERT INTO public.company_users (user_id, company_id, role)
VALUES ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaa0003', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa02', 'admin');

-- Reference data for Company A
INSERT INTO public.brands (id, company_id, name, slug)
VALUES ('bbbb0000-0000-0000-0000-000000000001', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01', 'RPC Brand A1', 'rpc-brand-a1');

INSERT INTO public.categories (id, company_id, name, slug)
VALUES ('bbbb1000-0000-0000-0000-000000000001', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01', 'RPC Cat A1', 'rpc-cat-a1');

-- Tenant-owned unit for Company A (not a global unit)
INSERT INTO public.units (id, company_id, name, abbreviation)
VALUES ('bbbb5000-0000-0000-0000-000000000001', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01', 'Caja', 'Cja');

-- Reference data for Company B
INSERT INTO public.brands (id, company_id, name, slug)
VALUES ('cccc0000-0000-0000-0000-000000000001', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa02', 'RPC Brand B1', 'rpc-brand-b1');

INSERT INTO public.categories (id, company_id, name, slug)
VALUES ('cccc1000-0000-0000-0000-000000000001', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa02', 'RPC Cat B1', 'rpc-cat-b1');

-- ============================================================
-- Helper functions for RLS context switching
-- ============================================================
CREATE OR REPLACE FUNCTION _set_rls_context(p_company_id UUID, p_role TEXT, p_user_id UUID DEFAULT 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaa0001'::UUID)
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

CREATE OR REPLACE FUNCTION _reset_rls_context()
RETURNS VOID AS $$
BEGIN
  RESET ROLE;
  PERFORM set_config('request.jwt.claims', '', true);
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- Persistent result storage (accessible across role switches)
-- ============================================================
CREATE TABLE IF NOT EXISTS public._rpc_test_results (
  key TEXT PRIMARY KEY,
  product_id UUID,
  variant_id UUID,
  price_id UUID,
  sku TEXT,
  id UUID
);
TRUNCATE public._rpc_test_results;
GRANT ALL ON public._rpc_test_results TO authenticated;
GRANT ALL ON public._rpc_test_results TO anon;

-- ============================================================
-- Test 1: create_product_with_variant — basic atomicity
-- Product + variant + price created together in one call
-- ============================================================
SELECT _set_rls_context('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01', 'admin', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaa0001'::UUID);

SELECT lives_ok(
  $$ SELECT public.create_product_with_variant(
     '{"company_id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01","name":"Atomic Test Product","slug":"atomic-test-product","brand_id":"bbbb0000-0000-0000-0000-000000000001","category_id":"bbbb1000-0000-0000-0000-000000000001","variant_name":"Default Variant","sku":"SKU-ATOMIC-1","price":99.99,"currency":"MXN"}'::JSONB) $$,
  'RPC create_product_with_variant: creates product+variant+price atomically'
);

-- Store result for subsequent tests
INSERT INTO _rpc_test_results (key, product_id, variant_id, price_id, sku)
SELECT 'atomic', (r->>'product_id')::UUID, (r->>'variant_id')::UUID, (r->>'price_id')::UUID, r->>'sku'
FROM public.create_product_with_variant(
  '{"company_id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01","name":"Atomic Product 2","slug":"atomic-product-2","variant_name":"Variant 2","sku":"SKU-ATOMIC-2","price":88.88}'::JSONB
) AS r;

-- Verify product was created
SELECT is(
  (SELECT count(*)::bigint FROM public.products WHERE slug = 'atomic-test-product' AND company_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01'),
  1::bigint,
  'RPC create_product_with_variant: product created'
);

-- Verify variant was created
SELECT is(
  (SELECT count(*)::bigint FROM public.product_variants WHERE sku = 'SKU-ATOMIC-1' AND company_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01'),
  1::bigint,
  'RPC create_product_with_variant: variant created with provided SKU'
);

-- Verify price was created and active (effective_until IS NULL)
SELECT is(
  (SELECT count(*)::bigint FROM public.product_prices pp
   JOIN public.product_variants pv ON pp.variant_id = pv.id
   WHERE pv.sku = 'SKU-ATOMIC-1' AND pv.company_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01'
     AND pp.effective_until IS NULL),
  1::bigint,
  'RPC create_product_with_variant: initial price created with effective_until IS NULL'
);

SELECT _reset_rls_context();

-- ============================================================
-- Test 2: create_product_with_variant — auto-generate SKU when null
-- ============================================================
SELECT _set_rls_context('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01', 'admin', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaa0001'::UUID);

INSERT INTO _rpc_test_results (key, product_id, variant_id, price_id, sku)
SELECT 'auto_sku', (r->>'product_id')::UUID, (r->>'variant_id')::UUID, (r->>'price_id')::UUID, r->>'sku'
FROM public.create_product_with_variant(
  '{"company_id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01","name":"Auto SKU Product","slug":"auto-sku-product","variant_name":"Auto SKU Variant","price":49.99}'::JSONB
) AS r;

-- Verify auto-generated SKU starts with product slug
SELECT ok(
  (SELECT sku FROM _rpc_test_results WHERE key = 'auto_sku') LIKE 'auto-sku-product-%',
  'RPC create_product_with_variant: auto-generated SKU starts with product slug'
);

-- Verify the returned product_id is not null
SELECT ok(
  (SELECT product_id FROM _rpc_test_results WHERE key = 'auto_sku') IS NOT NULL,
  'RPC create_product_with_variant: returns product_id'
);

SELECT _reset_rls_context();

-- ============================================================
-- Test 3: create_product_with_variant — reject wrong company_id
-- ============================================================
SELECT _set_rls_context('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01', 'admin', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaa0001'::UUID);

SELECT throws_ok(
  $$ SELECT public.create_product_with_variant(
     '{"company_id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa02","name":"Evil Product","slug":"evil-product","variant_name":"Evil Variant","price":10.00}'::JSONB) $$,
  NULL,
  NULL,
  'RPC create_product_with_variant: rejects wrong company_id'
);

SELECT _reset_rls_context();

-- ============================================================
-- Test 4: create_product_with_variant — reject non-admin (cashier)
-- ============================================================
SELECT _set_rls_context('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01', 'cashier', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaa0002'::UUID);

SELECT throws_ok(
  $$ SELECT public.create_product_with_variant(
     '{"company_id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01","name":"Cashier Product","slug":"cashier-product","variant_name":"Cashier Variant","price":10.00}'::JSONB) $$,
  NULL,
  NULL,
  'RPC create_product_with_variant: rejects cashier (non-admin)'
);

SELECT _reset_rls_context();

-- ============================================================
-- Test 5: create_product_with_variant — SKU collision auto-retry
-- The function retries on SKU collision internally; second call succeeds with new suffix
-- ============================================================
SELECT _set_rls_context('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01', 'admin', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaa0001'::UUID);

-- Create first product with specific SKU
INSERT INTO _rpc_test_results (key, product_id, variant_id, price_id, sku)
SELECT 'collision_1', (r->>'product_id')::UUID, (r->>'variant_id')::UUID, (r->>'price_id')::UUID, r->>'sku'
FROM public.create_product_with_variant(
  '{"company_id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01","name":"Collision Product 1","slug":"collision-product-1","variant_name":"Collision Variant 1","sku":"SKU-COLLISION-TEST","price":30.00}'::JSONB
) AS r;

-- Create second product with the SAME SKU — function should auto-retry and succeed
SELECT lives_ok(
  $$ SELECT public.create_product_with_variant(
     '{"company_id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01","name":"Collision Product 2","slug":"collision-product-2","variant_name":"Collision Variant 2","sku":"SKU-COLLISION-TEST","price":40.00}'::JSONB) $$,
  'RPC create_product_with_variant: auto-retries on SKU collision and succeeds'
);

-- Verify both products exist (no rollback)
SELECT is(
  (SELECT count(*)::bigint FROM public.products WHERE slug IN ('collision-product-1', 'collision-product-2') AND company_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01'),
  2::bigint,
  'RPC create_product_with_variant: both products exist after SKU collision auto-retry'
);

SELECT _reset_rls_context();

-- ============================================================
-- Test 6: create_product_with_variant — atomicity (product+variant+price all created)
-- ============================================================
SELECT is(
  (SELECT price_id FROM _rpc_test_results WHERE key = 'collision_1') IS NOT NULL,
  TRUE,
  'RPC create_product_with_variant: price_id returned (atomic creation confirmed)'
);

-- ============================================================
-- Test 7: deactivate_product — cascading deactivation
-- ============================================================
SELECT _set_rls_context('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01', 'admin', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaa0001'::UUID);

-- Create a product+variant+price to deactivate
INSERT INTO _rpc_test_results (key, product_id, variant_id, price_id, sku)
SELECT 'deactivate', (r->>'product_id')::UUID, (r->>'variant_id')::UUID, (r->>'price_id')::UUID, r->>'sku'
FROM public.create_product_with_variant(
  '{"company_id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01","name":"Product To Deactivate","slug":"product-to-deactivate","variant_name":"Variant To Deactivate","sku":"SKU-DEACTIVATE","price":25.00}'::JSONB
) AS r;

-- Call deactivate_product using the stored product_id
SELECT lives_ok(
  format(
    'SELECT public.deactivate_product(''{"company_id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01","product_id":"%s"}''::JSONB)',
    (SELECT product_id FROM _rpc_test_results WHERE key = 'deactivate')
  ),
  'RPC deactivate_product: deactivates product and all variants'
);

-- Verify product is inactive
SELECT is(
  (SELECT is_active FROM public.products WHERE id = (SELECT product_id FROM _rpc_test_results WHERE key = 'deactivate')),
  FALSE,
  'RPC deactivate_product: product is_active set to false'
);

-- Verify variant is also inactive
SELECT is(
  (SELECT count(*)::bigint FROM public.product_variants
   WHERE product_id = (SELECT product_id FROM _rpc_test_results WHERE key = 'deactivate')
     AND is_active = FALSE),
  1::bigint,
  'RPC deactivate_product: variant is_active set to false'
);

-- Verify deleted_at is set
SELECT ok(
  (SELECT deleted_at FROM public.products WHERE id = (SELECT product_id FROM _rpc_test_results WHERE key = 'deactivate')) IS NOT NULL,
  'RPC deactivate_product: product deleted_at is set'
);

SELECT _reset_rls_context();

-- ============================================================
-- Test 8: deactivate_product — reject wrong company
-- ============================================================
SELECT _set_rls_context('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa02', 'admin', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaa0003'::UUID);

SELECT throws_ok(
  format(
    'SELECT public.deactivate_product(''{"company_id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa02","product_id":"%s"}''::JSONB)',
    (SELECT product_id FROM _rpc_test_results WHERE key = 'deactivate')
  ),
  NULL,
  NULL,
  'RPC deactivate_product: rejects deactivation of product from different company'
);

SELECT _reset_rls_context();

-- ============================================================
-- Test 9: deactivate_product — reject already inactive product
-- ============================================================
SELECT _set_rls_context('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01', 'admin', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaa0001'::UUID);

SELECT throws_ok(
  format(
    'SELECT public.deactivate_product(''{"company_id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01","product_id":"%s"}''::JSONB)',
    (SELECT product_id FROM _rpc_test_results WHERE key = 'deactivate')
  ),
  NULL,
  NULL,
  'RPC deactivate_product: rejects deactivation of already inactive product'
);

SELECT _reset_rls_context();

-- ============================================================
-- Test 10: set_variant_price — closing previous active price + creating new
-- ============================================================
SELECT _set_rls_context('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01', 'admin', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaa0001'::UUID);

-- Create a product with initial price
INSERT INTO _rpc_test_results (key, product_id, variant_id, price_id, sku)
SELECT 'price_test', (r->>'product_id')::UUID, (r->>'variant_id')::UUID, (r->>'price_id')::UUID, r->>'sku'
FROM public.create_product_with_variant(
  '{"company_id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01","name":"Price Test Product","slug":"price-test-product","variant_name":"Price Test Variant","sku":"SKU-PRICE-TEST","price":100.00}'::JSONB
) AS r;

-- Set a new price — previous should be closed
SELECT lives_ok(
  format(
    'SELECT public.set_variant_price(''{"company_id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01","variant_id":"%s","price":120.00,"currency":"MXN"}''::JSONB)',
    (SELECT variant_id FROM _rpc_test_results WHERE key = 'price_test')
  ),
  'RPC set_variant_price: sets new price and closes previous'
);

-- Verify previous price is closed (effective_until IS NOT NULL)
SELECT is(
  (SELECT count(*)::bigint FROM public.product_prices pp
   WHERE pp.variant_id = (SELECT variant_id FROM _rpc_test_results WHERE key = 'price_test')
     AND pp.effective_until IS NOT NULL),
  1::bigint,
  'RPC set_variant_price: previous price is closed (effective_until set)'
);

-- Verify new active price exists
SELECT is(
  (SELECT count(*)::bigint FROM public.product_prices pp
   WHERE pp.variant_id = (SELECT variant_id FROM _rpc_test_results WHERE key = 'price_test')
     AND pp.effective_until IS NULL
     AND pp.price = 120.00),
  1::bigint,
  'RPC set_variant_price: new active price at 120.00'
);

-- Verify new price defaults to MXN
SELECT is(
  (SELECT pp.currency FROM public.product_prices pp
   WHERE pp.variant_id = (SELECT variant_id FROM _rpc_test_results WHERE key = 'price_test')
     AND pp.effective_until IS NULL
     AND pp.price = 120.00),
  'MXN',
  'RPC set_variant_price: currency defaults to MXN'
);

SELECT _reset_rls_context();

-- ============================================================
-- Test 11: set_variant_price — reject wrong company
-- ============================================================
SELECT _set_rls_context('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa02', 'admin', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaa0003'::UUID);

SELECT throws_ok(
  format(
    'SELECT public.set_variant_price(''{"company_id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa02","variant_id":"%s","price":999.00}''::JSONB)',
    (SELECT variant_id FROM _rpc_test_results WHERE key = 'price_test')
  ),
  NULL,
  NULL,
  'RPC set_variant_price: rejects price change for variant from different company'
);

SELECT _reset_rls_context();

-- ============================================================
-- Test 12: set_variant_price — reject non-admin (cashier)
-- ============================================================
SELECT _set_rls_context('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01', 'cashier', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaa0002'::UUID);

SELECT throws_ok(
  format(
    'SELECT public.set_variant_price(''{"company_id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01","variant_id":"%s","price":200.00}''::JSONB)',
    (SELECT variant_id FROM _rpc_test_results WHERE key = 'price_test')
  ),
  NULL,
  NULL,
  'RPC set_variant_price: rejects cashier (non-admin)'
);

SELECT _reset_rls_context();

-- ============================================================
-- Test 13: set_variant_price — future-dated price
-- ============================================================
SELECT _set_rls_context('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01', 'admin', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaa0001'::UUID);

SELECT lives_ok(
  format(
    'SELECT public.set_variant_price(''{"company_id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01","variant_id":"%s","price":150.00,"effective_from":"2099-01-01T00:00:00Z"}''::JSONB)',
    (SELECT variant_id FROM _rpc_test_results WHERE key = 'price_test')
  ),
  'RPC set_variant_price: accepts future effective_from'
);

-- Verify we now have two closed prices (100.00 closed by 120.00, 120.00 closed by 150.00)
SELECT is(
  (SELECT count(*)::bigint FROM public.product_prices pp
   WHERE pp.variant_id = (SELECT variant_id FROM _rpc_test_results WHERE key = 'price_test')
     AND pp.effective_until IS NOT NULL),
  2::bigint,
  'RPC set_variant_price: two closed prices after setting future price'
);

-- Verify active price (effective_until IS NULL)
SELECT is(
  (SELECT count(*)::bigint FROM public.product_prices pp
   WHERE pp.variant_id = (SELECT variant_id FROM _rpc_test_results WHERE key = 'price_test')
     AND pp.effective_until IS NULL),
  1::bigint,
  'RPC set_variant_price: exactly one active price (effective_until IS NULL)'
);

SELECT _reset_rls_context();

-- ============================================================
-- Test 14: create_brand — company isolation
-- ============================================================
SELECT _set_rls_context('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01', 'admin', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaa0001'::UUID);

SELECT lives_ok(
  $$ SELECT public.create_brand(
     '{"company_id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01","name":"New Brand A","slug":"new-brand-a-rpc"}'::JSONB) $$,
  'RPC create_brand: creates brand for own company'
);

SELECT is(
  (SELECT count(*)::bigint FROM public.brands WHERE slug = 'new-brand-a-rpc' AND company_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01'),
  1::bigint,
  'RPC create_brand: brand exists in correct company'
);

SELECT _reset_rls_context();

-- Company B admin cannot create brand for Company A
SELECT _set_rls_context('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa02', 'admin', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaa0003'::UUID);

SELECT throws_ok(
  $$ SELECT public.create_brand(
     '{"company_id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01","name":"Evil Brand","slug":"evil-brand"}'::JSONB) $$,
  NULL,
  NULL,
  'RPC create_brand: rejects wrong company_id'
);

SELECT _reset_rls_context();

-- ============================================================
-- Test 15: update_brand — company isolation
-- ============================================================
SELECT _set_rls_context('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01', 'admin', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaa0001'::UUID);

SELECT lives_ok(
  $$ SELECT public.update_brand(
     '{"company_id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01","id":"bbbb0000-0000-0000-0000-000000000001","name":"RPC Brand A1 Updated"}'::JSONB) $$,
  'RPC update_brand: updates brand in own company'
);

SELECT is(
  (SELECT name FROM public.brands WHERE id = 'bbbb0000-0000-0000-0000-000000000001'),
  'RPC Brand A1 Updated',
  'RPC update_brand: brand name updated'
);

SELECT _reset_rls_context();

-- Company B admin cannot update Company A's brand
SELECT _set_rls_context('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa02', 'admin', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaa0003'::UUID);

SELECT throws_ok(
  $$ SELECT public.update_brand(
     '{"company_id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa02","id":"bbbb0000-0000-0000-0000-000000000001","name":"Hacked Brand"}'::JSONB) $$,
  NULL,
  NULL,
  'RPC update_brand: rejects update of brand from different company'
);

SELECT _reset_rls_context();

-- ============================================================
-- Test 16: deactivate_brand — company isolation
-- ============================================================
SELECT _set_rls_context('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01', 'admin', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaa0001'::UUID);

INSERT INTO _rpc_test_results (key, id)
SELECT 'brand_deactivate', (r->>'id')::UUID
FROM public.create_brand(
  '{"company_id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01","name":"Brand To Deactivate","slug":"brand-to-deactivate"}'::JSONB
) AS r;

SELECT lives_ok(
  format(
    'SELECT public.deactivate_brand(''{"company_id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01","id":"%s"}''::JSONB)',
    (SELECT id FROM _rpc_test_results WHERE key = 'brand_deactivate')
  ),
  'RPC deactivate_brand: deactivates brand in own company'
);

SELECT _reset_rls_context();

-- ============================================================
-- Test 17: create_category — company isolation
-- ============================================================
SELECT _set_rls_context('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01', 'admin', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaa0001'::UUID);

INSERT INTO _rpc_test_results (key, id)
SELECT 'cat_create', (r->>'id')::UUID
FROM public.create_category(
  '{"company_id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01","name":"New Category A","slug":"new-category-a-rpc"}'::JSONB
) AS r;

SELECT ok(
  (SELECT id FROM _rpc_test_results WHERE key = 'cat_create') IS NOT NULL,
  'RPC create_category: creates category for own company'
);

SELECT _reset_rls_context();

-- Company B cannot create category in Company A
SELECT _set_rls_context('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa02', 'admin', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaa0003'::UUID);

SELECT throws_ok(
  $$ SELECT public.create_category(
     '{"company_id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01","name":"Evil Category","slug":"evil-category"}'::JSONB) $$,
  NULL,
  NULL,
  'RPC create_category: rejects wrong company_id'
);

SELECT _reset_rls_context();

-- ============================================================
-- Test 18: update_category — company isolation
-- ============================================================
SELECT _set_rls_context('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01', 'admin', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaa0001'::UUID);

SELECT lives_ok(
  format(
    'SELECT public.update_category(''{"company_id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01","id":"%s","name":"Updated Category A"}''::JSONB)',
    (SELECT id FROM _rpc_test_results WHERE key = 'cat_create')
  ),
  'RPC update_category: updates category in own company'
);

SELECT _reset_rls_context();

-- ============================================================
-- Test 19: deactivate_category — company isolation
-- ============================================================
SELECT _set_rls_context('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01', 'admin', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaa0001'::UUID);

SELECT lives_ok(
  format(
    'SELECT public.deactivate_category(''{"company_id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01","id":"%s"}''::JSONB)',
    (SELECT id FROM _rpc_test_results WHERE key = 'cat_create')
  ),
  'RPC deactivate_category: deactivates category in own company'
);

SELECT _reset_rls_context();

-- ============================================================
-- Test 20: create_unit — tenant-owned, company isolation
-- ============================================================
SELECT _set_rls_context('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01', 'admin', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaa0001'::UUID);

INSERT INTO _rpc_test_results (key, id)
SELECT 'unit_create', (r->>'id')::UUID
FROM public.create_unit(
  '{"company_id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01","name":"Litro Created","abbreviation":"Lc"}'::JSONB
) AS r;

SELECT ok(
  (SELECT id FROM _rpc_test_results WHERE key = 'unit_create') IS NOT NULL,
  'RPC create_unit: creates tenant-owned unit'
);

SELECT _reset_rls_context();

-- Company B cannot create unit in Company A
SELECT _set_rls_context('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa02', 'admin', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaa0003'::UUID);

SELECT throws_ok(
  $$ SELECT public.create_unit(
     '{"company_id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01","name":"Evil Unit","abbreviation":"EU"}'::JSONB) $$,
  NULL,
  NULL,
  'RPC create_unit: rejects wrong company_id'
);

SELECT _reset_rls_context();

-- ============================================================
-- Test 21: update_unit — tenant-owned unit updates
-- ============================================================
SELECT _set_rls_context('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01', 'admin', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaa0001'::UUID);

-- Update own tenant-owned unit should succeed
SELECT lives_ok(
  $$ SELECT public.update_unit(
     '{"company_id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01","id":"bbbb5000-0000-0000-0000-000000000001","abbreviation":"Cja2"}'::JSONB) $$,
  'RPC update_unit: updates tenant-owned unit'
);

SELECT _reset_rls_context();

-- ============================================================
-- Test 22: deactivate_unit — tenant-owned unit deactivation
-- ============================================================
SELECT _set_rls_context('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01', 'admin', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaa0001'::UUID);

-- Deactivate own tenant unit
SELECT lives_ok(
  $$ SELECT public.deactivate_unit(
     '{"company_id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01","id":"bbbb5000-0000-0000-0000-000000000001"}'::JSONB) $$,
  'RPC deactivate_unit: deactivates tenant-owned unit'
);

SELECT _reset_rls_context();

-- ============================================================
-- Test 23: Cashier cannot call any CRUD RPCs
-- ============================================================
SELECT _set_rls_context('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01', 'cashier', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaa0002'::UUID);

SELECT throws_ok(
  $$ SELECT public.create_brand(
     '{"company_id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01","name":"Cashier Brand","slug":"cashier-brand"}'::JSONB) $$,
  NULL,
  NULL,
  'RPC create_brand: rejects cashier'
);

SELECT throws_ok(
  $$ SELECT public.create_category(
     '{"company_id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01","name":"Cashier Category","slug":"cashier-category"}'::JSONB) $$,
  NULL,
  NULL,
  'RPC create_category: rejects cashier'
);

SELECT throws_ok(
  $$ SELECT public.create_unit(
     '{"company_id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01","name":"Cashier Unit","abbreviation":"CU"}'::JSONB) $$,
  NULL,
  NULL,
  'RPC create_unit: rejects cashier'
);

SELECT throws_ok(
  $$ SELECT public.deactivate_product(
     '{"company_id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01","product_id":"00000000-0000-0000-0000-000000000000"}'::JSONB) $$,
  NULL,
  NULL,
  'RPC deactivate_product: rejects cashier'
);

SELECT throws_ok(
  $$ SELECT public.set_variant_price(
     '{"company_id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01","variant_id":"00000000-0000-0000-0000-000000000000","price":1.00}'::JSONB) $$,
  NULL,
  NULL,
  'RPC set_variant_price: rejects cashier'
);

SELECT _reset_rls_context();

-- ============================================================
-- Test 24: deactivate_product — cascading on product with multiple variants
-- ============================================================
SELECT _set_rls_context('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01', 'admin', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaa0001'::UUID);

-- Create a product with one variant
INSERT INTO _rpc_test_results (key, product_id, variant_id, price_id, sku)
SELECT 'multi_variant', (r->>'product_id')::UUID, (r->>'variant_id')::UUID, (r->>'price_id')::UUID, r->>'sku'
FROM public.create_product_with_variant(
  '{"company_id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01","name":"Multi Variant Product","slug":"multi-variant-product","variant_name":"Variant 1","sku":"SKU-MULTI-1","price":50.00}'::JSONB
) AS r;

-- Add a second variant to the same product (as postgres, bypass RLS for setup)
RESET ROLE;
INSERT INTO public.product_variants (company_id, product_id, sku, name, created_by)
VALUES (
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01',
  (SELECT product_id FROM _rpc_test_results WHERE key = 'multi_variant'),
  'SKU-MULTI-2',
  'Variant 2',
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaa0001'
);

-- Re-set RLS context after RESET ROLE
SELECT _set_rls_context('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01', 'admin', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaa0001'::UUID);

-- Verify we now have 2 active variants
SELECT is(
  (SELECT count(*)::bigint FROM public.product_variants
   WHERE product_id = (SELECT product_id FROM _rpc_test_results WHERE key = 'multi_variant')
     AND is_active = TRUE),
  2::bigint,
  'RPC deactivate_product: product has 2 active variants before deactivation'
);

-- Deactivate the product
SELECT lives_ok(
  format(
    'SELECT public.deactivate_product(''{"company_id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01","product_id":"%s"}''::JSONB)',
    (SELECT product_id FROM _rpc_test_results WHERE key = 'multi_variant')
  ),
  'RPC deactivate_product: deactivates product with multiple variants'
);

-- Verify ALL variants are now inactive
SELECT is(
  (SELECT count(*)::bigint FROM public.product_variants
   WHERE product_id = (SELECT product_id FROM _rpc_test_results WHERE key = 'multi_variant')
     AND is_active = FALSE),
  2::bigint,
  'RPC deactivate_product: all variants deactivated (cascading)'
);

SELECT _reset_rls_context();

-- ============================================================
-- Test 25: create_product_with_variant — reject global base unit as variant unit_id
-- Global base units (company_id = '00000000-...') must not be directly usable.
-- ============================================================
SELECT _set_rls_context('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01', 'admin', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaa0001'::UUID);

SELECT throws_ok(
  format(
    'SELECT public.create_product_with_variant(''{"company_id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01","name":"Global Unit Product","slug":"global-unit-product","variant_name":"Variant With Global Unit","sku":"SKU-GLOBAL-UNIT","price":5.00,"unit_id":"%s"}''::JSONB)',
    (SELECT id FROM public.units WHERE company_id = '00000000-0000-0000-0000-000000000000' LIMIT 1)
  ),
  NULL,
  NULL,
  'RPC create_product_with_variant: rejects global base unit as variant unit_id'
);

SELECT _reset_rls_context();

-- ============================================================
-- Test 26: create_product_with_variant — reject brand_id not owned by company
-- ============================================================
SELECT _set_rls_context('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01', 'admin', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaa0001'::UUID);

SELECT throws_ok(
  $$ SELECT public.create_product_with_variant(
     '{"company_id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01","name":"Wrong Brand Product","slug":"wrong-brand-product","variant_name":"Variant","sku":"SKU-WRONG-BRAND","price":5.00,"brand_id":"cccc0000-0000-0000-0000-000000000001"}'::JSONB) $$,
  NULL,
  NULL,
  'RPC create_product_with_variant: rejects brand_id from different company'
);

SELECT _reset_rls_context();

-- ============================================================
-- Test 27: create_product_with_variant — reject category_id not owned by company
-- ============================================================
SELECT _set_rls_context('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01', 'admin', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaa0001'::UUID);

SELECT throws_ok(
  $$ SELECT public.create_product_with_variant(
     '{"company_id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01","name":"Wrong Cat Product","slug":"wrong-cat-product","variant_name":"Variant","sku":"SKU-WRONG-CAT","price":5.00,"category_id":"cccc1000-0000-0000-0000-000000000001"}'::JSONB) $$,
  NULL,
  NULL,
  'RPC create_product_with_variant: rejects category_id from different company'
);

SELECT _reset_rls_context();

-- ============================================================
-- Test 28: create_product_with_variant — reject unit_id not owned by company (tenant, wrong company)
-- ============================================================
SELECT _set_rls_context('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01', 'admin', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaa0001'::UUID);

-- Create a tenant unit for Company B to test cross-tenant rejection
RESET ROLE;
INSERT INTO public.units (id, company_id, name, abbreviation)
VALUES ('dddd0000-0000-0000-0000-000000000001', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa02', 'Company B Unit', 'CBU');

SELECT _set_rls_context('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01', 'admin', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaa0001'::UUID);

SELECT throws_ok(
  $$ SELECT public.create_product_with_variant(
     '{"company_id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01","name":"Wrong Unit Product","slug":"wrong-unit-product","variant_name":"Variant","sku":"SKU-WRONG-UNIT","price":5.00,"unit_id":"dddd0000-0000-0000-0000-000000000001"}'::JSONB) $$,
  NULL,
  NULL,
  'RPC create_product_with_variant: rejects unit_id from different company'
);

SELECT _reset_rls_context();

-- ============================================================
-- Test 29: create_category — reject parent_id not owned by company
-- ============================================================
SELECT _set_rls_context('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01', 'admin', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaa0001'::UUID);

SELECT throws_ok(
  $$ SELECT public.create_category(
     '{"company_id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01","name":"Wrong Parent Cat","slug":"wrong-parent-cat","parent_id":"cccc1000-0000-0000-0000-000000000001"}'::JSONB) $$,
  NULL,
  NULL,
  'RPC create_category: rejects parent_id from different company'
);

SELECT _reset_rls_context();

-- ============================================================
-- Test 30: PUBLIC/anon EXECUTE restrictions on mutation RPCs
-- Unauthenticated (anon) role must NOT be able to call any catalog RPC.
-- ============================================================
SET ROLE anon;

SELECT throws_ok(
  $$ SELECT public.create_product_with_variant(
     '{"company_id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01","name":"Anon Product","slug":"anon-product","variant_name":"Variant","price":10.00}'::JSONB) $$,
  '42501',
  NULL,
  'RPC EXECUTE restriction: anon cannot execute create_product_with_variant (insufficient privilege)'
);

SELECT throws_ok(
  $$ SELECT public.create_brand(
     '{"company_id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01","name":"Anon Brand","slug":"anon-brand"}'::JSONB) $$,
  '42501',
  NULL,
  'RPC EXECUTE restriction: anon cannot execute create_brand (insufficient privilege)'
);

SELECT throws_ok(
  $$ SELECT public.set_variant_price(
     '{"company_id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01","variant_id":"00000000-0000-0000-0000-000000000000","price":1.00}'::JSONB) $$,
  '42501',
  NULL,
  'RPC EXECUTE restriction: anon cannot execute set_variant_price (insufficient privilege)'
);

RESET ROLE;

-- ============================================================
-- Test 31: Fixed search_path on SECURITY DEFINER RPCs
-- All SECURITY DEFINER catalog RPCs must have a fixed search_path
-- (proconfig should contain '{search_path=public}').
-- ============================================================
SELECT ok(
  (SELECT count(*)::bigint FROM pg_proc p
   JOIN pg_namespace n ON p.pronamespace = n.oid
   WHERE n.nspname = 'public'
     AND p.proname IN (
       'create_product_with_variant',
       'deactivate_product',
       'update_product',
       'set_variant_price',
       'create_brand',
       'update_brand',
       'deactivate_brand',
       'create_category',
       'update_category',
       'deactivate_category',
       'create_unit',
       'update_unit',
       'deactivate_unit'
     )
     AND p.prosecdef = TRUE
     AND p.proconfig IS NOT NULL
     AND '{search_path=public}'::text[] <@ p.proconfig
  ) = 13::bigint,
  'All 13 SECURITY DEFINER catalog RPCs have fixed search_path = public'
);

-- ============================================================
-- Test 32: set_variant_price — reject overlapping future price intervals
-- Future prices must not overlap with existing closed intervals.
-- ============================================================
SELECT _set_rls_context('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01', 'admin', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaa0001'::UUID);

-- Create a product for overlap testing
INSERT INTO _rpc_test_results (key, product_id, variant_id, price_id, sku)
SELECT 'overlap_test', (r->>'product_id')::UUID, (r->>'variant_id')::UUID, (r->>'price_id')::UUID, r->>'sku'
FROM public.create_product_with_variant(
  '{"company_id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01","name":"Overlap Test Product","slug":"overlap-test-product","variant_name":"Overlap Variant","sku":"SKU-OVERLAP-TEST","price":200.00}'::JSONB
) AS r;

-- Set a future price that closes the current price
SELECT lives_ok(
  format(
    'SELECT public.set_variant_price(''{"company_id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01","variant_id":"%s","price":250.00,"effective_from":"2098-07-01T00:00:00Z"}''::JSONB)',
    (SELECT variant_id FROM _rpc_test_results WHERE key = 'overlap_test')
  ),
  'RPC set_variant_price: accepts future price 2098-07-01'
);

-- Set another future price AFTER the first future price (non-overlapping, should succeed)
SELECT lives_ok(
  format(
    'SELECT public.set_variant_price(''{"company_id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01","variant_id":"%s","price":275.00,"effective_from":"2098-08-01T00:00:00Z"}''::JSONB)',
    (SELECT variant_id FROM _rpc_test_results WHERE key = 'overlap_test')
  ),
  'RPC set_variant_price: accepts non-overlapping future price 2098-08-01'
);

-- Attempt to set a price WITHIN an existing closed interval (should be rejected)
SELECT throws_ok(
  format(
    'SELECT public.set_variant_price(''{"company_id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01","variant_id":"%s","price":999.00,"effective_from":"2098-07-15T00:00:00Z"}''::JSONB)',
    (SELECT variant_id FROM _rpc_test_results WHERE key = 'overlap_test')
  ),
  NULL,
  NULL,
  'RPC set_variant_price: rejects price that would overlap existing closed interval'
);

SELECT _reset_rls_context();

-- ============================================================
-- Test 33: create_product_with_variant — rollback-on-failure atomicity
-- Verify that when an RPC fails, no partial rows remain from the transaction.
-- (Since pgTAP runs inside a transaction, we verify by checking that a
--  completely invalid call does not leave any rows.)
-- ============================================================
SELECT _set_rls_context('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01', 'admin', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaa0001'::UUID);

-- Verify no product with slug 'rollback-atomic' exists before the attempt
SELECT is(
  (SELECT count(*)::bigint FROM public.products WHERE slug = 'rollback-atomic' AND company_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01'),
  0::bigint,
  'RPC atomicity: no phantom product before rollback test'
);

-- Call create_product_with_variant with a brand_id from another company
-- This should fail inside the RPC after product creation attempt.
-- Since SECURITY DEFINER runs in its own context, we need to verify that
-- the exception causes full rollback.
SELECT throws_ok(
  $$ SELECT public.create_product_with_variant(
     '{"company_id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01","name":"Atomic Fail Product","slug":"rollback-atomic","variant_name":"Rollback Variant","sku":"SKU-ROLLBACK-ATOMIC","price":5.00,"brand_id":"cccc0000-0000-0000-0000-000000000001"}'::JSONB) $$,
  NULL,
  NULL,
  'RPC atomicity: create_product_with_variant with cross-tenant brand_id fails'
);

-- Verify no phantom product row was left behind
SELECT is(
  (SELECT count(*)::bigint FROM public.products WHERE slug = 'rollback-atomic' AND company_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01'),
  0::bigint,
  'RPC atomicity: no phantom product left after failed create_product_with_variant'
);

SELECT _reset_rls_context();

-- ============================================================
-- Test 34: update_category — reject inactive same-company parent_id
-- A category with is_active=false in the same company must not be
-- assignable as a parent via update_category.
-- ============================================================
SELECT _set_rls_context('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01', 'admin', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaa0001'::UUID);

-- Create a new category to update
INSERT INTO _rpc_test_results (key, id)
SELECT 'update_cat', (r->>'id')::UUID
FROM public.create_category(
  '{"company_id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01","name":"Category To Update Parent","slug":"cat-update-parent"}'::JSONB
) AS r;

-- Create an inactive category (deactivate it)
INSERT INTO _rpc_test_results (key, id)
SELECT 'inactive_cat', (r->>'id')::UUID
FROM public.create_category(
  '{"company_id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01","name":"Inactive Category","slug":"inactive-cat-parent"}'::JSONB
) AS r;

SELECT lives_ok(
  format(
    'SELECT public.deactivate_category(''{"company_id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01","id":"%s"}''::JSONB)',
    (SELECT id FROM _rpc_test_results WHERE key = 'inactive_cat')
  ),
  'RPC update_category: deactivate category for parent rejection test'
);

-- Now attempt to set the inactive category as parent_id via update_category
SELECT throws_ok(
  format(
    'SELECT public.update_category(''{"company_id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01","id":"%s","parent_id":"%s"}''::JSONB)',
    (SELECT id FROM _rpc_test_results WHERE key = 'update_cat'),
    (SELECT id FROM _rpc_test_results WHERE key = 'inactive_cat')
  ),
  NULL,
  NULL,
  'RPC update_category: rejects inactive same-company parent_id'
);

SELECT _reset_rls_context();

-- ============================================================
-- Test 35: update_category — reject cross-company parent_id
-- A category from Company B must not be assignable as parent for
-- a Company A category via update_category.
-- ============================================================
SELECT _set_rls_context('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01', 'admin', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaa0001'::UUID);

-- Attempt to set Company B's category (cccc1000-...) as parent for a Company A category
SELECT throws_ok(
  format(
    'SELECT public.update_category(''{"company_id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01","id":"%s","parent_id":"cccc1000-0000-0000-0000-000000000001"}''::JSONB)',
    (SELECT id FROM _rpc_test_results WHERE key = 'update_cat')
  ),
  NULL,
  NULL,
  'RPC update_category: rejects cross-company parent_id'
);

SELECT _reset_rls_context();

-- ============================================================
-- Test 36: update_product — basic field update
-- Updates name, slug, description on an active product.
-- ============================================================
SELECT _set_rls_context('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01', 'admin', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaa0001'::UUID);

-- Create a product to update
INSERT INTO _rpc_test_results (key, product_id, variant_id, price_id, sku)
SELECT 'update_test', (r->>'product_id')::UUID, (r->>'variant_id')::UUID, (r->>'price_id')::UUID, r->>'sku'
FROM public.create_product_with_variant(
  '{"company_id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01","name":"Product To Update","slug":"product-to-update","variant_name":"Default Variant","sku":"SKU-UPDATE-TEST","price":75.00}'::JSONB
) AS r;

-- Update the product name and description
SELECT lives_ok(
  format(
    'SELECT public.update_product(''{"company_id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01","product_id":"%s","name":"Updated Product Name","description":"Updated description"}''::JSONB)',
    (SELECT product_id FROM _rpc_test_results WHERE key = 'update_test')
  ),
  'RPC update_product: updates name and description'
);

-- Verify the product was updated
SELECT is(
  (SELECT name FROM public.products WHERE id = (SELECT product_id FROM _rpc_test_results WHERE key = 'update_test')),
  'Updated Product Name',
  'RPC update_product: product name was updated'
);

SELECT is(
  (SELECT description FROM public.products WHERE id = (SELECT product_id FROM _rpc_test_results WHERE key = 'update_test')),
  'Updated description',
  'RPC update_product: product description was updated'
);

SELECT _reset_rls_context();

-- ============================================================
-- Test 37: update_product — update brand_id and category_id
-- ============================================================
SELECT _set_rls_context('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01', 'admin', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaa0001'::UUID);

-- Update brand_id and category_id
SELECT lives_ok(
  format(
    'SELECT public.update_product(''{"company_id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01","product_id":"%s","brand_id":"bbbb0000-0000-0000-0000-000000000001","category_id":"bbbb1000-0000-0000-0000-000000000001"}''::JSONB)',
    (SELECT product_id FROM _rpc_test_results WHERE key = 'update_test')
  ),
  'RPC update_product: updates brand_id and category_id'
);

SELECT is(
  (SELECT brand_id FROM public.products WHERE id = (SELECT product_id FROM _rpc_test_results WHERE key = 'update_test')),
  'bbbb0000-0000-0000-0000-000000000001'::UUID,
  'RPC update_product: brand_id was updated'
);

SELECT is(
  (SELECT category_id FROM public.products WHERE id = (SELECT product_id FROM _rpc_test_results WHERE key = 'update_test')),
  'bbbb1000-0000-0000-0000-000000000001'::UUID,
  'RPC update_product: category_id was updated'
);

SELECT _reset_rls_context();

-- ============================================================
-- Test 38: update_product — clear brand_id and category_id (set to null)
-- ============================================================
SELECT _set_rls_context('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01', 'admin', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaa0001'::UUID);

-- Clear brand_id by passing null
SELECT lives_ok(
  format(
    'SELECT public.update_product(''{"company_id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01","product_id":"%s","brand_id":null,"category_id":null}''::JSONB)',
    (SELECT product_id FROM _rpc_test_results WHERE key = 'update_test')
  ),
  'RPC update_product: clears brand_id and category_id with null'
);

SELECT is(
  (SELECT brand_id FROM public.products WHERE id = (SELECT product_id FROM _rpc_test_results WHERE key = 'update_test')) IS NULL,
  TRUE,
  'RPC update_product: brand_id was cleared to null'
);

SELECT is(
  (SELECT category_id FROM public.products WHERE id = (SELECT product_id FROM _rpc_test_results WHERE key = 'update_test')) IS NULL,
  TRUE,
  'RPC update_product: category_id was cleared to null'
);

SELECT _reset_rls_context();

-- ============================================================
-- Test 39: update_product — reject wrong company
-- ============================================================
SELECT _set_rls_context('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa02', 'admin', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaa0003'::UUID);

SELECT throws_ok(
  format(
    'SELECT public.update_product(''{"company_id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa02","product_id":"%s","name":"Hacked Name"}''::JSONB)',
    (SELECT product_id FROM _rpc_test_results WHERE key = 'update_test')
  ),
  NULL,
  NULL,
  'RPC update_product: rejects update of product from different company'
);

SELECT _reset_rls_context();

-- ============================================================
-- Test 40: update_product — reject cross-company brand_id
-- ============================================================
SELECT _set_rls_context('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01', 'admin', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaa0001'::UUID);

SELECT throws_ok(
  format(
    'SELECT public.update_product(''{"company_id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01","product_id":"%s","brand_id":"cccc0000-0000-0000-0000-000000000001"}''::JSONB)',
    (SELECT product_id FROM _rpc_test_results WHERE key = 'update_test')
  ),
  NULL,
  NULL,
  'RPC update_product: rejects brand_id from different company'
);

SELECT _reset_rls_context();

-- ============================================================
-- Test 41: update_product — reject cross-company category_id
-- ============================================================
SELECT _set_rls_context('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01', 'admin', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaa0001'::UUID);

SELECT throws_ok(
  format(
    'SELECT public.update_product(''{"company_id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01","product_id":"%s","category_id":"cccc1000-0000-0000-0000-000000000001"}''::JSONB)',
    (SELECT product_id FROM _rpc_test_results WHERE key = 'update_test')
  ),
  NULL,
  NULL,
  'RPC update_product: rejects category_id from different company'
);

SELECT _reset_rls_context();

-- ============================================================
-- Test 42: update_product — reject non-admin (cashier)
-- ============================================================
SELECT _set_rls_context('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01', 'cashier', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaa0002'::UUID);

SELECT throws_ok(
  format(
    'SELECT public.update_product(''{"company_id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01","product_id":"%s","name":"Cashier Update"}''::JSONB)',
    (SELECT product_id FROM _rpc_test_results WHERE key = 'update_test')
  ),
  NULL,
  NULL,
  'RPC update_product: rejects cashier (non-admin)'
);

SELECT _reset_rls_context();

-- ============================================================
-- Test 43: update_product — anonymous EXECUTE restriction
-- Verify that anon role cannot call update_product RPC.
-- ============================================================
-- Pre-fetch product_id before switching to anon role
SELECT product_id FROM _rpc_test_results WHERE key = 'update_test' \gset

SET ROLE anon;

SELECT throws_ok(
  format(
    'SELECT public.update_product(''{"company_id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa01","product_id":"%s","name":"Anon Update"}''::JSONB)',
    :'product_id'
  ),
  '42501',
  NULL,
  'RPC EXECUTE restriction: anon cannot execute update_product (insufficient privilege)'
);

RESET ROLE;

-- ============================================================
-- Test 44: update_product — search_path hardening
-- Verify that update_product has SECURITY DEFINER with fixed search_path.
-- (Counted alongside the 12 existing RPCs in test 31, now 13 total.)
-- ============================================================

-- Updated to 13 RPCs (including update_product)
-- Separate count for update_product specifically
SELECT ok(
  (SELECT count(*)::bigint FROM pg_proc p
   JOIN pg_namespace n ON p.pronamespace = n.oid
   WHERE n.nspname = 'public'
     AND p.proname = 'update_product'
     AND p.prosecdef = TRUE
     AND p.proconfig IS NOT NULL
     AND '{search_path=public}'::text[] <@ p.proconfig
  ) = 1::bigint,
  'update_product RPC has SECURITY DEFINER with fixed search_path = public'
);

-- ============================================================
-- Clean up helper table and functions
-- ============================================================
DROP TABLE IF EXISTS public._rpc_test_results;
DROP FUNCTION _set_rls_context(UUID, TEXT, UUID);
DROP FUNCTION _reset_rls_context();

-- ============================================================
-- Finish
-- ============================================================
SELECT * FROM finish();
ROLLBACK;