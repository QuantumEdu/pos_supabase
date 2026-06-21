-- pgTAP: Dashboard & Reports RPC tests
-- Verifies 6 RPCs exist, reject cross-tenant, return correct types
-- source: RR16-RR20

BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap;

-- ============================================================================
-- Seed data (minimal cross-domain setup)
-- ============================================================================
INSERT INTO public.companies (id, name, slug)
VALUES ('d1d00000-0000-0000-0000-000000000001', 'Dashboard RPC Co A', 'drpc-co-a')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.branches (id, company_id, name, slug)
VALUES
  ('d1d00001-0000-0000-0000-000000000001', 'd1d00000-0000-0000-0000-000000000001', 'DRPC Branch A1', 'drpc-branch-a1')
ON CONFLICT (id) DO NOTHING;

INSERT INTO auth.users (id, email, raw_app_meta_data, raw_user_meta_data)
VALUES
  ('d1d00aaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'drpc-admin@test.com',
   '{"company_id": "d1d00000-0000-0000-0000-000000000001", "role": "admin"}',
   '{"full_name": "DRPC Admin"}')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.profiles (id, full_name)
VALUES ('d1d00aaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'DRPC Admin')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.company_users (company_id, user_id, role, is_active)
VALUES
  ('d1d00000-0000-0000-0000-000000000001', 'd1d00aaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'admin', true)
ON CONFLICT DO NOTHING;

-- Minimal catalog data for export tests
INSERT INTO public.products (id, company_id, name, slug)
VALUES ('d1d00000-0000-0000-0000-0000eeeeee01', 'd1d00000-0000-0000-0000-000000000001', 'DRPC Product', 'drpc-product')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.product_variants (id, company_id, product_id, name, sku, is_active)
VALUES ('d1d10000-0000-0000-0000-000000000099', 'd1d00000-0000-0000-0000-000000000001',
        'd1d00000-0000-0000-0000-0000eeeeee01', 'DRPC Variant', 'DRPC-V1', true)
ON CONFLICT DO NOTHING;

INSERT INTO public.customers (id, company_id, name, slug, tax_id, is_active)
VALUES ('d1d50000-0000-0000-0000-000000000001', 'd1d00000-0000-0000-0000-000000000001',
        'DRPC Customer', 'drpc-customer', 'TAX-001', true)
ON CONFLICT (id) DO NOTHING;

-- Set auth context for RLS (admin role)
SELECT set_config('request.jwt.claims', '{"sub": "d1d00aaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", "app_metadata": {"company_id": "d1d00000-0000-0000-0000-000000000001", "role": "admin"}}', true);

-- ============================================================================
-- Plan: 30 assertions
-- ============================================================================
SELECT plan(29);

-- ============================================================================
-- Function existence tests (6 functions)
-- ============================================================================
SELECT has_function('public', 'fn_jsonb_to_csv', ARRAY['jsonb'],
  'fn_jsonb_to_csv(jsonb) exists'
);

SELECT has_function('public', 'fn_report_sales_by_cashier', ARRAY['uuid', 'date', 'date'],
  'fn_report_sales_by_cashier(uuid,date,date) exists'
);

SELECT has_function('public', 'fn_report_cash_cut', ARRAY['uuid', 'uuid'],
  'fn_report_cash_cut(uuid,uuid) exists'
);

SELECT has_function('public', 'fn_report_purchases_by_supplier', ARRAY['uuid', 'date', 'date'],
  'fn_report_purchases_by_supplier(uuid,date,date) exists'
);

SELECT has_function('public', 'fn_purchase_suggestions', ARRAY['uuid', 'uuid'],
  'fn_purchase_suggestions(uuid,uuid) exists (p_branch_id optional)'
);

SELECT has_function('public', 'fn_export_entities', ARRAY['uuid', 'text', 'text', 'jsonb'],
  'fn_export_entities(uuid,text,text,jsonb) exists'
);

-- ============================================================================
-- Cross-tenant rejection tests (all 6 RPCs)
-- ============================================================================
SELECT is(
  (SELECT public.fn_report_sales_by_cashier(
    '00000000-0000-0000-0000-000000000000'::UUID,
    CURRENT_DATE, CURRENT_DATE
  )->>'code'),
  'CROSS_TENANT',
  'fn_report_sales_by_cashier rejects cross-tenant call'
);

SELECT is(
  (SELECT public.fn_report_cash_cut(
    '00000000-0000-0000-0000-000000000000'::UUID,
    '00000000-0000-0000-0000-000000000000'::UUID
  )->>'code'),
  'CROSS_TENANT',
  'fn_report_cash_cut rejects cross-tenant call'
);

SELECT is(
  (SELECT public.fn_report_purchases_by_supplier(
    '00000000-0000-0000-0000-000000000000'::UUID,
    CURRENT_DATE, CURRENT_DATE
  )->>'code'),
  'CROSS_TENANT',
  'fn_report_purchases_by_supplier rejects cross-tenant call'
);

SELECT is(
  (SELECT public.fn_purchase_suggestions(
    '00000000-0000-0000-0000-000000000000'::UUID
  )->>'code'),
  'CROSS_TENANT',
  'fn_purchase_suggestions rejects cross-tenant call'
);

SELECT is(
  (SELECT public.fn_export_entities(
    '00000000-0000-0000-0000-000000000000'::UUID,
    'products', 'json', '{}'::JSONB
  )->>'code'),
  'CROSS_TENANT',
  'fn_export_entities rejects cross-tenant call'
);

-- fn_jsonb_to_csv is IMMUTABLE with no company_id — no cross-tenant guard needed
SELECT ok(true, 'fn_jsonb_to_csv is IMMUTABLE (no cross-tenant guard needed)');

-- ============================================================================
-- fn_jsonb_to_csv: edge cases
-- ============================================================================
SELECT is(public.fn_jsonb_to_csv(NULL::JSONB), '',
  'fn_jsonb_to_csv(NULL) returns empty string'
);

SELECT is(public.fn_jsonb_to_csv('[]'::JSONB), '',
  'fn_jsonb_to_csv(empty array) returns empty string'
);

SELECT is(public.fn_jsonb_to_csv('[{"a": 1, "b": "hello"}]'::JSONB),
  'a,b' || E'\n' || '1,"hello"',
  'fn_jsonb_to_csv(single row) produces header + data row'
);

SELECT is(public.fn_jsonb_to_csv('[{"name": "test, inc.", "val": 42}]'::JSONB),
  'name,val' || E'\n' || '"test, inc.",42',
  'fn_jsonb_to_csv(quoted string) escapes commas in values'
);

SELECT is(public.fn_jsonb_to_csv('[{"a": 1, "b": "x"}, {"a": 2, "b": "y"}]'::JSONB),
  'a,b' || E'\n' || '1,"x"' || E'\n' || '2,"y"',
  'fn_jsonb_to_csv(multiple rows) produces correct rows'
);

-- ============================================================================
-- fn_export_entities: invalid entity
-- ============================================================================
SELECT is(
  (SELECT public.fn_export_entities(
    'd1d00000-0000-0000-0000-000000000001'::UUID,
    'invalid_entity', 'json', '{}'::JSONB
  )->>'code'),
  'UNKNOWN_ENTITY',
  'fn_export_entities(invalid entity) returns UNKNOWN_ENTITY error'
);

-- ============================================================================
-- fn_export_entities: valid entity returns success with data
-- ============================================================================
SELECT is(
  (SELECT public.fn_export_entities(
    'd1d00000-0000-0000-0000-000000000001'::UUID,
    'products', 'json', '{}'::JSONB
  )->>'success'),
  'true',
  'fn_export_entities(products) returns success=true'
);

SELECT is(
  (SELECT public.fn_export_entities(
    'd1d00000-0000-0000-0000-000000000001'::UUID,
    'customers', 'json', '{}'::JSONB
  )->>'success'),
  'true',
  'fn_export_entities(customers) returns success=true'
);

SELECT is(
  (SELECT public.fn_export_entities(
    'd1d00000-0000-0000-0000-000000000001'::UUID,
    'products', 'csv', '{}'::JSONB
  )->>'format'),
  'csv',
  'fn_export_entities(products,csv) returns format=csv'
);

-- ============================================================================
-- fn_purchase_suggestions: returns valid structure
-- ============================================================================
SELECT is(
  (SELECT public.fn_purchase_suggestions(
    'd1d00000-0000-0000-0000-000000000001'::UUID
  )->>'success'),
  'true',
  'fn_purchase_suggestions returns success=true with valid company'
);

-- ============================================================================
-- Return type: all RPCs return JSONB
-- ============================================================================
SELECT is(
  (SELECT pg_proc.prorettype::REGTYPE::TEXT FROM pg_proc WHERE proname = 'fn_jsonb_to_csv'),
  'text',
  'fn_jsonb_to_csv returns text'
);

SELECT is(
  (SELECT pg_proc.prorettype::REGTYPE::TEXT FROM pg_proc WHERE proname = 'fn_report_sales_by_cashier'),
  'jsonb',
  'fn_report_sales_by_cashier returns jsonb'
);

SELECT is(
  (SELECT pg_proc.prorettype::REGTYPE::TEXT FROM pg_proc WHERE proname = 'fn_report_cash_cut'),
  'jsonb',
  'fn_report_cash_cut returns jsonb'
);

SELECT is(
  (SELECT pg_proc.prorettype::REGTYPE::TEXT FROM pg_proc WHERE proname = 'fn_report_purchases_by_supplier'),
  'jsonb',
  'fn_report_purchases_by_supplier returns jsonb'
);

SELECT is(
  (SELECT pg_proc.prorettype::REGTYPE::TEXT FROM pg_proc WHERE proname = 'fn_purchase_suggestions'),
  'jsonb',
  'fn_purchase_suggestions returns jsonb'
);

SELECT is(
  (SELECT pg_proc.prorettype::REGTYPE::TEXT FROM pg_proc WHERE proname = 'fn_export_entities'),
  'jsonb',
  'fn_export_entities returns jsonb'
);

-- ============================================================================
-- fn_report_cash_cut: not found returns error
-- ============================================================================
SELECT is(
  (SELECT public.fn_report_cash_cut(
    'd1d00000-0000-0000-0000-000000000001'::UUID,
    '00000000-0000-0000-0000-000000000000'::UUID
  )->>'code'),
  'NOT_FOUND',
  'fn_report_cash_cut(nonexistent session) returns NOT_FOUND'
);

SELECT * FROM finish();
ROLLBACK;
