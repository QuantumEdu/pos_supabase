-- pgTAP: Purchasing domain RPC tests
-- Verifies create_purchase_order, receive_purchase_transaction,
-- cancel_purchase_order, manage_supplier, and RPC hardening.
-- (source: purchasing-domain Phase 2)

BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap;

SELECT plan(68);

-- ============================================================
-- Setup: Insert test data as postgres (bypasses RLS)
-- ============================================================

INSERT INTO public.companies (id, name, slug)
VALUES
  ('77771111-1111-1111-1111-111111111111', 'Purchasing RPC Co A', 'purchasing-rpc-co-a'),
  ('77772222-2222-2222-2222-222222222222', 'Purchasing RPC Co B', 'purchasing-rpc-co-b');

INSERT INTO public.branches (id, company_id, name, slug)
VALUES
  ('7777aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', '77771111-1111-1111-1111-111111111111', 'RPC Main Branch A', 'rpc-main-branch-a'),
  ('7777bbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', '77772222-2222-2222-2222-222222222222', 'RPC Main Branch B', 'rpc-main-branch-b');

INSERT INTO public.brands (id, company_id, name, slug)
VALUES
  ('7777c000-0000-0000-0000-000000000001', '77771111-1111-1111-1111-111111111111', 'RPC Brand A', 'rpc-brand-a'),
  ('7777c000-0000-0000-0000-000000000002', '77772222-2222-2222-2222-222222222222', 'RPC Brand B', 'rpc-brand-b');

INSERT INTO public.categories (id, company_id, name, slug)
VALUES
  ('7777d000-0000-0000-0000-000000000001', '77771111-1111-1111-1111-111111111111', 'RPC Category A', 'rpc-category-a'),
  ('7777d000-0000-0000-0000-000000000002', '77772222-2222-2222-2222-222222222222', 'RPC Category B', 'rpc-category-b');

INSERT INTO public.products (id, company_id, name, slug, brand_id, category_id)
VALUES
  ('7777e000-0000-0000-0000-000000000001', '77771111-1111-1111-1111-111111111111', 'RPC Product A', 'rpc-product-a', '7777c000-0000-0000-0000-000000000001', '7777d000-0000-0000-0000-000000000001'),
  ('7777e000-0000-0000-0000-000000000002', '77772222-2222-2222-2222-222222222222', 'RPC Product B', 'rpc-product-b', '7777c000-0000-0000-0000-000000000002', '7777d000-0000-0000-0000-000000000002');

INSERT INTO public.product_variants (id, company_id, product_id, sku, name)
VALUES
  ('7777f000-0000-0000-0000-000000000001', '77771111-1111-1111-1111-111111111111', '7777e000-0000-0000-0000-000000000001', 'RPC-VAR-A1', 'RPC Variant A1'),
  ('7777f000-0000-0000-0000-000000000002', '77771111-1111-1111-1111-111111111111', '7777e000-0000-0000-0000-000000000001', 'RPC-VAR-A2', 'RPC Variant A2'),
  ('7777f000-0000-0000-0000-000000000003', '77772222-2222-2222-2222-222222222222', '7777e000-0000-0000-0000-000000000002', 'RPC-VAR-B1', 'RPC Variant B1');

INSERT INTO auth.users (id, email, raw_app_meta_data, raw_user_meta_data)
VALUES
  ('7777000a-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'purchasing-rpc-admin-a@test.com',
   '{"company_id": "77771111-1111-1111-1111-111111111111", "role": "admin"}',
   '{"full_name": "Purchasing RPC Admin A"}'),
  ('7777000b-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'purchasing-rpc-cashier-a@test.com',
   '{"company_id": "77771111-1111-1111-1111-111111111111", "role": "cashier"}',
   '{"full_name": "Purchasing RPC Cashier A"}'),
  ('7777000c-cccc-cccc-cccc-cccccccccccc', 'purchasing-rpc-admin-b@test.com',
   '{"company_id": "77772222-2222-2222-2222-222222222222", "role": "admin"}',
   '{"full_name": "Purchasing RPC Admin B"}')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.profiles (id, full_name)
VALUES
  ('7777000a-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'Purchasing RPC Admin A'),
  ('7777000b-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'Purchasing RPC Cashier A'),
  ('7777000c-cccc-cccc-cccc-cccccccccccc', 'Purchasing RPC Admin B')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.company_users (user_id, company_id, role)
VALUES
  ('7777000a-aaaa-aaaa-aaaa-aaaaaaaaaaaa', '77771111-1111-1111-1111-111111111111', 'admin'),
  ('7777000b-bbbb-bbbb-bbbb-bbbbbbbbbbbb', '77771111-1111-1111-1111-111111111111', 'cashier'),
  ('7777000c-cccc-cccc-cccc-cccccccccccc', '77772222-2222-2222-2222-222222222222', 'admin')
ON CONFLICT (user_id, company_id) DO NOTHING;

-- ============================================================
-- Helper functions for RLS context switching
-- ============================================================
CREATE OR REPLACE FUNCTION _set_purchasing_rpc_context(
  p_company_id UUID,
  p_role TEXT,
  p_user_id UUID
)
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

CREATE OR REPLACE FUNCTION _reset_purchasing_rpc_context()
RETURNS VOID AS $$
BEGIN
  RESET ROLE;
  PERFORM set_config('request.jwt.claims', '', true);
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- Persistent result storage (accessible across role switches)
-- ============================================================
CREATE TABLE IF NOT EXISTS public._purchasing_rpc_test_results (
  key TEXT PRIMARY KEY,
  payload JSONB,
  supplier_id UUID,
  po_id UUID,
  receipt_id UUID
);
TRUNCATE public._purchasing_rpc_test_results;
GRANT ALL ON public._purchasing_rpc_test_results TO authenticated;
GRANT ALL ON public._purchasing_rpc_test_results TO anon;

-- ============================================================
-- SETUP: Create test suppliers and POs as admin (needed by tests)
-- ============================================================
SELECT _set_purchasing_rpc_context('77771111-1111-1111-1111-111111111111', 'admin', '7777000a-aaaa-aaaa-aaaa-aaaaaaaaaaaa'::UUID);

-- Create supplier A1
INSERT INTO public._purchasing_rpc_test_results (key, payload, supplier_id)
SELECT 'supplier_a1_create',
       r,
       (r->>'supplier_id')::UUID
FROM public.manage_supplier(
  '{"action":"create","company_id":"77771111-1111-1111-1111-111111111111","name":"ACME Corp","slug":"acme-corp","tax_id":"TAX001","contact_name":"John Doe","phone":"555-0100","email":"john@acme.com"}'::JSONB
) AS r;

-- Create supplier A2 (to be deactivated later)
INSERT INTO public._purchasing_rpc_test_results (key, payload, supplier_id)
SELECT 'supplier_a2_create',
       r,
       (r->>'supplier_id')::UUID
FROM public.manage_supplier(
  '{"action":"create","company_id":"77771111-1111-1111-1111-111111111111","name":"Global Supplies","slug":"global-supplies","contact_name":"Jane Smith"}'::JSONB
) AS r;

-- Switch context to Company B and create supplier
SELECT _reset_purchasing_rpc_context();
SELECT _set_purchasing_rpc_context('77772222-2222-2222-2222-222222222222', 'admin', '7777000c-cccc-cccc-cccc-cccccccccccc'::UUID);

INSERT INTO public._purchasing_rpc_test_results (key, payload, supplier_id)
SELECT 'supplier_b1_create',
       r,
       (r->>'supplier_id')::UUID
FROM public.manage_supplier(
  '{"action":"create","company_id":"77772222-2222-2222-2222-222222222222","name":"B Supplier","slug":"b-supplier","contact_name":"B Contact"}'::JSONB
) AS r;

-- Switch back to Company A for remaining setup
SELECT _reset_purchasing_rpc_context();
SELECT _set_purchasing_rpc_context('77771111-1111-1111-1111-111111111111', 'admin', '7777000a-aaaa-aaaa-aaaa-aaaaaaaaaaaa'::UUID);

-- Create a PO in 'draft' for cancel tests
DO $$
DECLARE
  v_po_id UUID;
  v_supplier_id UUID;
  v_result JSONB;
BEGIN
  SELECT supplier_id INTO v_supplier_id FROM public._purchasing_rpc_test_results WHERE key = 'supplier_a1_create';

  v_result := public.create_purchase_order(
    jsonb_build_object(
      'company_id', '77771111-1111-1111-1111-111111111111',
      'branch_id', '7777aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      'supplier_id', v_supplier_id,
      'order_number', 'PO-001-DRAFT',
      'order_date', '2026-06-01',
      'items', jsonb_build_array(
        jsonb_build_object('variant_id', '7777f000-0000-0000-0000-000000000001', 'ordered_qty', 10, 'unit_cost', 50.00, 'tax_rate', 0.1600),
        jsonb_build_object('variant_id', '7777f000-0000-0000-0000-000000000002', 'ordered_qty', 5, 'unit_cost', 30.00)
      )
    )
  );

  v_po_id := (v_result->>'purchase_order_id')::UUID;

  INSERT INTO public._purchasing_rpc_test_results (key, payload, po_id)
  VALUES ('po_draft', v_result, v_po_id);
END;
$$;

-- Create a PO in 'sent' for receive tests
DO $$
DECLARE
  v_po_id UUID;
  v_supplier_id UUID;
  v_result JSONB;
BEGIN
  SELECT supplier_id INTO v_supplier_id FROM public._purchasing_rpc_test_results WHERE key = 'supplier_a1_create';

  v_result := public.create_purchase_order(
    jsonb_build_object(
      'company_id', '77771111-1111-1111-1111-111111111111',
      'branch_id', '7777aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      'supplier_id', v_supplier_id,
      'order_number', 'PO-002-SENT',
      'items', jsonb_build_array(
        jsonb_build_object('variant_id', '7777f000-0000-0000-0000-000000000001', 'ordered_qty', 10, 'unit_cost', 100.00, 'tax_rate', 0.1600),
        jsonb_build_object('variant_id', '7777f000-0000-0000-0000-000000000002', 'ordered_qty', 20, 'unit_cost', 50.00, 'tax_rate', 0.1600)
      )
    )
  );

  v_po_id := (v_result->>'purchase_order_id')::UUID;

  INSERT INTO public._purchasing_rpc_test_results (key, payload, po_id)
  VALUES ('po_sent', v_result, v_po_id);
END;
$$;

-- Create a PO for overshoot test (ordered_qty=5)
DO $$
DECLARE
  v_po_id UUID;
  v_supplier_id UUID;
  v_result JSONB;
BEGIN
  SELECT supplier_id INTO v_supplier_id FROM public._purchasing_rpc_test_results WHERE key = 'supplier_a1_create';

  v_result := public.create_purchase_order(
    jsonb_build_object(
      'company_id', '77771111-1111-1111-1111-111111111111',
      'branch_id', '7777aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      'supplier_id', v_supplier_id,
      'order_number', 'PO-003-OVER',
      'items', jsonb_build_array(
        jsonb_build_object('variant_id', '7777f000-0000-0000-0000-000000000001', 'ordered_qty', 5, 'unit_cost', 100.00)
      )
    )
  );

  v_po_id := (v_result->>'purchase_order_id')::UUID;

  INSERT INTO public._purchasing_rpc_test_results (key, payload, po_id)
  VALUES ('po_overshoot', v_result, v_po_id);
END;
$$;

-- Create a PO in 'received' for cancel rejection test
DO $$
DECLARE
  v_po_id UUID;
  v_supplier_id UUID;
  v_result JSONB;
BEGIN
  SELECT supplier_id INTO v_supplier_id FROM public._purchasing_rpc_test_results WHERE key = 'supplier_a1_create';

  v_result := public.create_purchase_order(
    jsonb_build_object(
      'company_id', '77771111-1111-1111-1111-111111111111',
      'branch_id', '7777aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      'supplier_id', v_supplier_id,
      'order_number', 'PO-004-RCVD',
      'items', jsonb_build_array(
        jsonb_build_object('variant_id', '7777f000-0000-0000-0000-000000000001', 'ordered_qty', 1, 'unit_cost', 10.00)
      )
    )
  );

  v_po_id := (v_result->>'purchase_order_id')::UUID;

  INSERT INTO public._purchasing_rpc_test_results (key, payload, po_id)
  VALUES ('po_received', v_result, v_po_id);
END;
$$;

-- Create a PO for partial receipt/cancel test
DO $$
DECLARE
  v_po_id UUID;
  v_supplier_id UUID;
  v_result JSONB;
  v_po_item_id UUID;
BEGIN
  SELECT supplier_id INTO v_supplier_id FROM public._purchasing_rpc_test_results WHERE key = 'supplier_a1_create';

  v_result := public.create_purchase_order(
    jsonb_build_object(
      'company_id', '77771111-1111-1111-1111-111111111111',
      'branch_id', '7777aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      'supplier_id', v_supplier_id,
      'order_number', 'PO-005-PART',
      'items', jsonb_build_array(
        jsonb_build_object('variant_id', '7777f000-0000-0000-0000-000000000001', 'ordered_qty', 20, 'unit_cost', 25.00)
      )
    )
  );

  v_po_id := (v_result->>'purchase_order_id')::UUID;

  INSERT INTO public._purchasing_rpc_test_results (key, payload, po_id)
  VALUES ('po_partial', v_result, v_po_id);
END;
$$;

-- ============================================================
-- SETUP (postgres role): Transition PO statuses for test scenarios.
-- These bypass the critical column trigger.
-- ============================================================
SELECT _reset_purchasing_rpc_context();

UPDATE public.purchase_orders SET status = 'sent'
WHERE id = (SELECT po_id FROM public._purchasing_rpc_test_results WHERE key = 'po_sent');

UPDATE public.purchase_orders SET status = 'sent'
WHERE id = (SELECT po_id FROM public._purchasing_rpc_test_results WHERE key = 'po_overshoot');

UPDATE public.purchase_orders SET status = 'received'
WHERE id = (SELECT po_id FROM public._purchasing_rpc_test_results WHERE key = 'po_received');

-- Set po_partial to 'sent' then do partial receipt
UPDATE public.purchase_orders SET status = 'sent'
WHERE id = (SELECT po_id FROM public._purchasing_rpc_test_results WHERE key = 'po_partial');

-- Do partial receipt for po_partial
SELECT _set_purchasing_rpc_context('77771111-1111-1111-1111-111111111111', 'admin', '7777000a-aaaa-aaaa-aaaa-aaaaaaaaaaaa'::UUID);

DO $$
DECLARE
  v_po_id UUID;
  v_po_item_id UUID;
BEGIN
  SELECT po_id INTO v_po_id FROM public._purchasing_rpc_test_results WHERE key = 'po_partial';
  SELECT id INTO v_po_item_id FROM public.purchase_order_items WHERE purchase_order_id = v_po_id LIMIT 1;

  PERFORM public.receive_purchase_transaction(
    jsonb_build_object(
      'company_id', '77771111-1111-1111-1111-111111111111',
      'branch_id', '7777aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      'purchase_order_id', v_po_id,
      'receipt_number', 'RCV-PARTIAL-1',
      'items', jsonb_build_array(
        jsonb_build_object('purchase_order_item_id', v_po_item_id, 'received_qty', 5)
      )
    )
  );
END;
$$;

SELECT _reset_purchasing_rpc_context();

-- ============================================================
-- Test 1: RPC hardening — all 4 purchasing RPCs are SECURITY DEFINER
-- with fixed search_path = public
-- ============================================================
SELECT ok(
  (SELECT count(*)::bigint FROM pg_proc p
   JOIN pg_namespace n ON p.pronamespace = n.oid
   WHERE n.nspname = 'public'
     AND p.proname IN (
       'create_purchase_order',
       'receive_purchase_transaction',
       'cancel_purchase_order',
       'manage_supplier'
     )
     AND p.prosecdef = TRUE
     AND p.proconfig IS NOT NULL
     AND '{search_path=public}'::text[] <@ p.proconfig
  ) = 4::bigint,
  'All 4 purchasing RPCs have SECURITY DEFINER with fixed search_path = public'
);

-- ============================================================
-- Test 2: Authenticated role has EXECUTE on all 4 RPCs
-- ============================================================
SELECT ok(
  (SELECT count(*)::bigint FROM pg_proc p
   JOIN pg_namespace n ON p.pronamespace = n.oid
   WHERE n.nspname = 'public'
     AND p.proname IN (
       'create_purchase_order',
       'receive_purchase_transaction',
       'cancel_purchase_order',
       'manage_supplier'
     )
     AND has_function_privilege('authenticated', format('public.%I(jsonb)', p.proname), 'EXECUTE')
  ) = 4::bigint,
  'Authenticated role has EXECUTE on all 4 purchasing RPCs'
);

-- ============================================================
-- Test 3: Anon role has no EXECUTE privileges on purchasing RPCs
-- ============================================================
SELECT ok(
  (SELECT count(*)::bigint FROM pg_proc p
   JOIN pg_namespace n ON p.pronamespace = n.oid
   WHERE n.nspname = 'public'
     AND p.proname IN (
       'create_purchase_order',
       'receive_purchase_transaction',
       'cancel_purchase_order',
       'manage_supplier'
     )
     AND has_function_privilege('anon', format('public.%I(jsonb)', p.proname), 'EXECUTE')
  ) = 0::bigint,
  'Anon role has no EXECUTE privileges on purchasing RPCs'
);

-- ============================================================
-- Test 4: Anon cannot execute create_purchase_order
-- ============================================================
SET ROLE anon;

SELECT throws_ok(
  $$ SELECT public.create_purchase_order('{"company_id":"77771111-1111-1111-1111-111111111111","branch_id":"7777aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","supplier_id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","order_number":"PO-ANON","items":[{"variant_id":"7777f000-0000-0000-0000-000000000001","ordered_qty":1,"unit_cost":1.00}]}'::JSONB) $$,
  '42501',
  NULL,
  'RPC EXECUTE restriction: anon cannot execute create_purchase_order'
);

RESET ROLE;

-- ============================================================
-- Test 5: create_purchase_order — valid creation + server-computed totals
-- ============================================================
SELECT _set_purchasing_rpc_context('77771111-1111-1111-1111-111111111111', 'admin', '7777000a-aaaa-aaaa-aaaa-aaaaaaaaaaaa'::UUID);

DO $$
DECLARE
  v_supplier_id UUID;
  v_result JSONB;
  v_po_id UUID;
BEGIN
  SELECT supplier_id INTO v_supplier_id FROM public._purchasing_rpc_test_results WHERE key = 'supplier_a1_create';

  v_result := public.create_purchase_order(
    jsonb_build_object(
      'company_id', '77771111-1111-1111-1111-111111111111',
      'branch_id', '7777aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      'supplier_id', v_supplier_id,
      'order_number', 'PO-VALID-001',
      'payment_method', 'Transfer',
      'notes', 'First valid PO',
      'items', jsonb_build_array(
        jsonb_build_object('variant_id', '7777f000-0000-0000-0000-000000000001', 'ordered_qty', 5, 'unit_cost', 100.00, 'tax_rate', 0.1600),
        jsonb_build_object('variant_id', '7777f000-0000-0000-0000-000000000002', 'ordered_qty', 3, 'unit_cost', 50.00, 'tax_rate', 0.1600)
      )
    )
  );

  v_po_id := (v_result->>'purchase_order_id')::UUID;

  INSERT INTO public._purchasing_rpc_test_results (key, payload, po_id)
  VALUES ('create_valid', v_result, v_po_id);
END;
$$;

SELECT ok(
  (SELECT payload->>'purchase_order_id' FROM public._purchasing_rpc_test_results WHERE key = 'create_valid') IS NOT NULL,
  'create_purchase_order: returns purchase_order_id'
);

SELECT is(
  (SELECT payload->>'status' FROM public._purchasing_rpc_test_results WHERE key = 'create_valid'),
  'draft',
  'create_purchase_order: status is draft'
);

SELECT is(
  (SELECT (payload->>'items_count')::INT FROM public._purchasing_rpc_test_results WHERE key = 'create_valid'),
  2,
  'create_purchase_order: items_count is 2'
);

-- Server-computed totals: item1=5*100=500, item2=3*50=150, subtotal=650
-- tax: item1=500*0.16=80.00, item2=150*0.16=24.00, tax_total=104.00
-- total=650+104=754.00
SELECT is(
  (SELECT (payload->>'total')::NUMERIC FROM public._purchasing_rpc_test_results WHERE key = 'create_valid'),
  754.00::NUMERIC,
  'create_purchase_order: server-computed total is 754.00 (650+104)'
);

-- Verify PO header was inserted
SELECT is(
  (SELECT count(*)::bigint FROM public.purchase_orders WHERE order_number = 'PO-VALID-001' AND company_id = '77771111-1111-1111-1111-111111111111'),
  1::bigint,
  'create_purchase_order: PO header inserted with correct order_number'
);

-- Verify PO items were inserted
SELECT is(
  (SELECT count(*)::bigint FROM public.purchase_order_items WHERE purchase_order_id = (SELECT po_id FROM public._purchasing_rpc_test_results WHERE key = 'create_valid')),
  2::bigint,
  'create_purchase_order: 2 PO items inserted'
);

-- Verify received_qty starts at 0
SELECT is(
  (SELECT SUM(received_qty) FROM public.purchase_order_items WHERE purchase_order_id = (SELECT po_id FROM public._purchasing_rpc_test_results WHERE key = 'create_valid')),
  0::NUMERIC,
   'create_purchase_order: all received_qty = 0'
);

-- Verify server-computed subtotal and tax_total (W4: client overrides ignored)
SELECT is(
  (SELECT subtotal FROM public.purchase_orders WHERE id = (SELECT po_id FROM public._purchasing_rpc_test_results WHERE key = 'create_valid')),
  650.00::NUMERIC,
  'create_purchase_order: server-computed subtotal = 650.00 (500+150)'
);

SELECT is(
  (SELECT tax_total FROM public.purchase_orders WHERE id = (SELECT po_id FROM public._purchasing_rpc_test_results WHERE key = 'create_valid')),
  104.00::NUMERIC,
  'create_purchase_order: server-computed tax_total = 104.00 (80+24)'
);

-- Verify item-level subtotal and tax_amount are server-computed
SELECT is(
  (SELECT subtotal FROM public.purchase_order_items WHERE purchase_order_id = (SELECT po_id FROM public._purchasing_rpc_test_results WHERE key = 'create_valid') AND variant_id = '7777f000-0000-0000-0000-000000000001'),
  500.00::NUMERIC,
  'create_purchase_order: item1 subtotal server-computed = 500.00 (5*100)'
);

SELECT is(
  (SELECT tax_amount FROM public.purchase_order_items WHERE purchase_order_id = (SELECT po_id FROM public._purchasing_rpc_test_results WHERE key = 'create_valid') AND variant_id = '7777f000-0000-0000-0000-000000000001'),
  80.00::NUMERIC,
  'create_purchase_order: item1 tax_amount server-computed = 80.00 (500*0.16)'
);

SELECT _reset_purchasing_rpc_context();

-- ============================================================
-- Test 6: create_purchase_order — empty items rejection
-- ============================================================
SELECT _set_purchasing_rpc_context('77771111-1111-1111-1111-111111111111', 'admin', '7777000a-aaaa-aaaa-aaaa-aaaaaaaaaaaa'::UUID);

SELECT throws_ok(
  $$ SELECT public.create_purchase_order('{"company_id":"77771111-1111-1111-1111-111111111111","branch_id":"7777aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","supplier_id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","order_number":"PO-EMPTY","items":[]}'::JSONB) $$,
  NULL,
  'At least one item is required',
  'create_purchase_order: rejects empty items array'
);

SELECT _reset_purchasing_rpc_context();

-- ============================================================
-- Test 7: create_purchase_order — cross-company supplier rejection
-- ============================================================
SELECT _set_purchasing_rpc_context('77771111-1111-1111-1111-111111111111', 'admin', '7777000a-aaaa-aaaa-aaaa-aaaaaaaaaaaa'::UUID);

SELECT throws_ok(
  format(
    'SELECT public.create_purchase_order(''{"company_id":"77771111-1111-1111-1111-111111111111","branch_id":"7777aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","supplier_id":"%s","order_number":"PO-CROSS","items":[{"variant_id":"7777f000-0000-0000-0000-000000000001","ordered_qty":1,"unit_cost":1.00}]}''::JSONB)',
    (SELECT supplier_id::text FROM public._purchasing_rpc_test_results WHERE key = 'supplier_b1_create')
  ),
  NULL,
  NULL,
  'create_purchase_order: rejects supplier from different company'
);

SELECT _reset_purchasing_rpc_context();

-- ============================================================
-- Test 8: create_purchase_order — cross-company variant rejection
-- ============================================================
SELECT _set_purchasing_rpc_context('77771111-1111-1111-1111-111111111111', 'admin', '7777000a-aaaa-aaaa-aaaa-aaaaaaaaaaaa'::UUID);

SELECT throws_ok(
  format(
    'SELECT public.create_purchase_order(''{"company_id":"77771111-1111-1111-1111-111111111111","branch_id":"7777aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","supplier_id":"%s","order_number":"PO-CROSS-VAR","items":[{"variant_id":"7777f000-0000-0000-0000-000000000003","ordered_qty":1,"unit_cost":1.00}]}''::JSONB)',
    (SELECT supplier_id::text FROM public._purchasing_rpc_test_results WHERE key = 'supplier_a1_create')
  ),
  NULL,
  NULL,
  'create_purchase_order: rejects variant from different company'
);

SELECT _reset_purchasing_rpc_context();

-- ============================================================
-- Test 9: create_purchase_order — reject wrong company_id
-- ============================================================
SELECT _set_purchasing_rpc_context('77771111-1111-1111-1111-111111111111', 'admin', '7777000a-aaaa-aaaa-aaaa-aaaaaaaaaaaa'::UUID);

SELECT throws_ok(
  $$ SELECT public.create_purchase_order('{"company_id":"77772222-2222-2222-2222-222222222222","branch_id":"7777aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","supplier_id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","order_number":"PO-EVIL","items":[{"variant_id":"7777f000-0000-0000-0000-000000000001","ordered_qty":1,"unit_cost":1.00}]}'::JSONB) $$,
  NULL,
  NULL,
  'create_purchase_order: rejects wrong company_id'
);

SELECT _reset_purchasing_rpc_context();

-- ============================================================
-- Test 10: create_purchase_order — reject cashier (non-admin)
-- ============================================================
SELECT _set_purchasing_rpc_context('77771111-1111-1111-1111-111111111111', 'cashier', '7777000b-bbbb-bbbb-bbbb-bbbbbbbbbbbb'::UUID);

SELECT throws_ok(
  $$ SELECT public.create_purchase_order('{"company_id":"77771111-1111-1111-1111-111111111111","branch_id":"7777aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","supplier_id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","order_number":"PO-CASHIER","items":[{"variant_id":"7777f000-0000-0000-0000-000000000001","ordered_qty":1,"unit_cost":1.00}]}'::JSONB) $$,
  NULL,
  NULL,
  'create_purchase_order: rejects cashier (non-admin)'
);

SELECT _reset_purchasing_rpc_context();

-- ============================================================
-- Test 11: receive_purchase_transaction — full receipt (sent → received)
-- ============================================================
SELECT _set_purchasing_rpc_context('77771111-1111-1111-1111-111111111111', 'admin', '7777000a-aaaa-aaaa-aaaa-aaaaaaaaaaaa'::UUID);

-- Get PO item IDs for the sent PO
DO $$
DECLARE
  v_po_id UUID;
  v_po_item_id_1 UUID;
  v_po_item_id_2 UUID;
BEGIN
  SELECT po_id INTO v_po_id FROM public._purchasing_rpc_test_results WHERE key = 'po_sent';
  SELECT id INTO v_po_item_id_1 FROM public.purchase_order_items WHERE purchase_order_id = v_po_id AND variant_id = '7777f000-0000-0000-0000-000000000001';
  SELECT id INTO v_po_item_id_2 FROM public.purchase_order_items WHERE purchase_order_id = v_po_id AND variant_id = '7777f000-0000-0000-0000-000000000002';

  INSERT INTO public._purchasing_rpc_test_results (key, payload, receipt_id)
  SELECT 'full_receipt',
         r,
         (r->>'receipt_id')::UUID
  FROM public.receive_purchase_transaction(
    jsonb_build_object(
      'company_id', '77771111-1111-1111-1111-111111111111',
      'branch_id', '7777aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      'purchase_order_id', v_po_id,
      'receipt_number', 'RCV-FULL-001',
      'notes', 'Full receipt test',
      'items', jsonb_build_array(
        jsonb_build_object('purchase_order_item_id', v_po_item_id_1, 'received_qty', 10, 'lot_code', 'LOT-FULL-1', 'expiration_date', '2027-12-31'),
        jsonb_build_object('purchase_order_item_id', v_po_item_id_2, 'received_qty', 20, 'lot_code', 'LOT-FULL-2')
      )
    )
  ) AS r;
END;
$$;

SELECT ok(
  (SELECT payload->>'receipt_id' FROM public._purchasing_rpc_test_results WHERE key = 'full_receipt') IS NOT NULL,
  'receive_purchase_transaction: returns receipt_id'
);

SELECT is(
  (SELECT payload->>'po_status' FROM public._purchasing_rpc_test_results WHERE key = 'full_receipt'),
  'received',
  'receive_purchase_transaction: PO status transitions to received (full receipt)'
);

SELECT is(
  (SELECT (payload->>'items_processed')::INT FROM public._purchasing_rpc_test_results WHERE key = 'full_receipt'),
  2,
  'receive_purchase_transaction: items_processed = 2'
);

-- Verify PO status in DB
SELECT is(
  (SELECT status FROM public.purchase_orders WHERE id = (SELECT po_id FROM public._purchasing_rpc_test_results WHERE key = 'po_sent')),
  'received',
  'receive_purchase_transaction: PO status is received in DB'
);

-- Verify receipt was inserted
SELECT is(
  (SELECT count(*)::bigint FROM public.purchase_receipts WHERE receipt_number = 'RCV-FULL-001' AND company_id = '77771111-1111-1111-1111-111111111111'),
  1::bigint,
  'receive_purchase_transaction: receipt header inserted'
);

-- Verify receipt items were inserted
SELECT is(
  (SELECT count(*)::bigint FROM public.purchase_receipt_items WHERE purchase_receipt_id = (SELECT receipt_id FROM public._purchasing_rpc_test_results WHERE key = 'full_receipt')),
  2::bigint,
  'receive_purchase_transaction: 2 receipt items inserted'
);

-- Verify inventory lots were created
SELECT is(
  (SELECT count(*)::bigint FROM public.stock_lots WHERE company_id = '77771111-1111-1111-1111-111111111111' AND branch_id = '7777aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' AND lot_code IN ('LOT-FULL-1', 'LOT-FULL-2')),
  2::bigint,
  'receive_purchase_transaction: 2 inventory lots created'
);

-- Verify inventory movements were created with correct reference
SELECT is(
  (SELECT count(*)::bigint FROM public.stock_movements WHERE reference_type = 'purchase_receipt' AND reference_id = (SELECT receipt_id FROM public._purchasing_rpc_test_results WHERE key = 'full_receipt')),
  2::bigint,
  'receive_purchase_transaction: 2 movements created with reference_type=purchase_receipt'
);

-- Verify received_qty was updated
SELECT is(
  (SELECT SUM(received_qty) FROM public.purchase_order_items WHERE purchase_order_id = (SELECT po_id FROM public._purchasing_rpc_test_results WHERE key = 'po_sent')),
  30::NUMERIC,
  'receive_purchase_transaction: received_qty updated (10+20=30)'
);

-- Verify product_variants.last_cost was updated
SELECT is(
  (SELECT last_cost FROM public.product_variants WHERE id = '7777f000-0000-0000-0000-000000000001'),
  100.00::NUMERIC,
  'receive_purchase_transaction: last_cost updated on variant 1'
);

SELECT _reset_purchasing_rpc_context();

-- ============================================================
-- Test 12: receive_purchase_transaction — partial receipt (sent → partial)
-- ============================================================
-- Create a fresh PO for partial receipt test
SELECT _set_purchasing_rpc_context('77771111-1111-1111-1111-111111111111', 'admin', '7777000a-aaaa-aaaa-aaaa-aaaaaaaaaaaa'::UUID);

DO $$
DECLARE
  v_po_id UUID;
  v_po_item_id UUID;
  v_result JSONB;
  v_supplier_id UUID;
BEGIN
  SELECT supplier_id INTO v_supplier_id FROM public._purchasing_rpc_test_results WHERE key = 'supplier_a1_create';

  v_result := public.create_purchase_order(
    jsonb_build_object(
      'company_id', '77771111-1111-1111-1111-111111111111',
      'branch_id', '7777aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      'supplier_id', v_supplier_id,
      'order_number', 'PO-PARTIAL-001',
      'items', jsonb_build_array(
        jsonb_build_object('variant_id', '7777f000-0000-0000-0000-000000000001', 'ordered_qty', 10, 'unit_cost', 100.00)
      )
    )
  );
  v_po_id := (v_result->>'purchase_order_id')::UUID;

  INSERT INTO public._purchasing_rpc_test_results (key, payload, po_id)
  VALUES ('po_partial_test', v_result, v_po_id);

  -- Manually set to 'sent' for receiving
  RESET ROLE;
  UPDATE public.purchase_orders SET status = 'sent' WHERE id = v_po_id;

  PERFORM _set_purchasing_rpc_context('77771111-1111-1111-1111-111111111111', 'admin', '7777000a-aaaa-aaaa-aaaa-aaaaaaaaaaaa'::UUID);

  SELECT id INTO v_po_item_id FROM public.purchase_order_items WHERE purchase_order_id = v_po_id;

  v_result := public.receive_purchase_transaction(
    jsonb_build_object(
      'company_id', '77771111-1111-1111-1111-111111111111',
      'branch_id', '7777aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      'purchase_order_id', v_po_id,
      'receipt_number', 'RCV-PARTIAL-002',
      'items', jsonb_build_array(
        jsonb_build_object('purchase_order_item_id', v_po_item_id, 'received_qty', 4)
      )
    )
  );

  INSERT INTO public._purchasing_rpc_test_results (key, payload, receipt_id)
  VALUES ('partial_receipt', v_result, (v_result->>'receipt_id')::UUID);
END;
$$;

SELECT is(
  (SELECT payload->>'po_status' FROM public._purchasing_rpc_test_results WHERE key = 'partial_receipt'),
  'partial',
  'receive_purchase_transaction: PO status transitions to partial (partial receipt)'
);

-- Verify received_qty = 4 in DB
SELECT is(
  (SELECT received_qty FROM public.purchase_order_items WHERE purchase_order_id = (SELECT po_id FROM public._purchasing_rpc_test_results WHERE key = 'po_partial_test')),
  4::NUMERIC,
  'receive_purchase_transaction: received_qty = 4 after partial receipt'
);

SELECT _reset_purchasing_rpc_context();

-- ============================================================
-- Test 13: receive_purchase_transaction — overshoot rejection
-- ============================================================
SELECT _set_purchasing_rpc_context('77771111-1111-1111-1111-111111111111', 'admin', '7777000a-aaaa-aaaa-aaaa-aaaaaaaaaaaa'::UUID);

DO $$
DECLARE
  v_po_id UUID;
  v_po_item_id UUID;
BEGIN
  SELECT po_id INTO v_po_id FROM public._purchasing_rpc_test_results WHERE key = 'po_overshoot';
  SELECT id INTO v_po_item_id FROM public.purchase_order_items WHERE purchase_order_id = v_po_id;

  -- Attempt to receive 10 (but ordered_qty is 5)
  PERFORM public.receive_purchase_transaction(
    jsonb_build_object(
      'company_id', '77771111-1111-1111-1111-111111111111',
      'branch_id', '7777aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      'purchase_order_id', v_po_id,
      'receipt_number', 'RCV-OVER-001',
      'items', jsonb_build_array(
        jsonb_build_object('purchase_order_item_id', v_po_item_id, 'received_qty', 10)
      )
    )
  );
EXCEPTION
  WHEN OTHERS THEN
    INSERT INTO public._purchasing_rpc_test_results (key, payload)
    VALUES ('overshoot_error', jsonb_build_object('error', SQLERRM));
END;
$$;

SELECT ok(
  (SELECT payload->>'error' FROM public._purchasing_rpc_test_results WHERE key = 'overshoot_error') IS NOT NULL,
  'receive_purchase_transaction: overshoot quantity raises exception'
);

SELECT _reset_purchasing_rpc_context();

-- ============================================================
-- Test 13b: receive_purchase_transaction — zero/negative received_qty rejection
-- ============================================================
SELECT _set_purchasing_rpc_context('77771111-1111-1111-1111-111111111111', 'admin', '7777000a-aaaa-aaaa-aaaa-aaaaaaaaaaaa'::UUID);

SELECT throws_ok(
  format(
    'SELECT public.receive_purchase_transaction(''{"company_id":"77771111-1111-1111-1111-111111111111","branch_id":"7777aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","purchase_order_id":"%s","receipt_number":"RCV-ZERO","items":[{"purchase_order_item_id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","received_qty":0}]}''::JSONB)',
    (SELECT po_id::text FROM public._purchasing_rpc_test_results WHERE key = 'po_sent')
  ),
  NULL,
  NULL,
  'receive_purchase_transaction: rejects zero received_qty'
);

SELECT _reset_purchasing_rpc_context();

-- ============================================================
-- Test 14: receive_purchase_transaction — reject received PO
-- ============================================================
SELECT _set_purchasing_rpc_context('77771111-1111-1111-1111-111111111111', 'admin', '7777000a-aaaa-aaaa-aaaa-aaaaaaaaaaaa'::UUID);

DO $$
DECLARE
  v_po_id UUID;
  v_po_item_id UUID;
BEGIN
  SELECT po_id INTO v_po_id FROM public._purchasing_rpc_test_results WHERE key = 'po_received';
  SELECT id INTO v_po_item_id FROM public.purchase_order_items WHERE purchase_order_id = v_po_id;

  PERFORM public.receive_purchase_transaction(
    jsonb_build_object(
      'company_id', '77771111-1111-1111-1111-111111111111',
      'branch_id', '7777aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      'purchase_order_id', v_po_id,
      'receipt_number', 'RCV-ON-RECEIVED',
      'items', jsonb_build_array(
        jsonb_build_object('purchase_order_item_id', v_po_item_id, 'received_qty', 1)
      )
    )
  );
EXCEPTION
  WHEN OTHERS THEN
    INSERT INTO public._purchasing_rpc_test_results (key, payload)
    VALUES ('reject_received', jsonb_build_object('error', SQLERRM));
END;
$$;

SELECT ok(
  (SELECT payload->>'error' FROM public._purchasing_rpc_test_results WHERE key = 'reject_received') IS NOT NULL,
  'receive_purchase_transaction: rejects received PO'
);

SELECT _reset_purchasing_rpc_context();

-- ============================================================
-- Test 15: receive_purchase_transaction — cross-company rejection
-- ============================================================
SELECT _set_purchasing_rpc_context('77772222-2222-2222-2222-222222222222', 'admin', '7777000c-cccc-cccc-cccc-cccccccccccc'::UUID);

SELECT throws_ok(
  format(
    'SELECT public.receive_purchase_transaction(''{"company_id":"77772222-2222-2222-2222-222222222222","branch_id":"7777bbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb","purchase_order_id":"%s","receipt_number":"RCV-CROSS","items":[{"purchase_order_item_id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","received_qty":1}]}''::JSONB)',
    (SELECT po_id::text FROM public._purchasing_rpc_test_results WHERE key = 'po_sent')
  ),
  NULL,
  NULL,
  'receive_purchase_transaction: rejects cross-company PO'
);

SELECT _reset_purchasing_rpc_context();

-- ============================================================
-- Test 16: cancel_purchase_order — cancel draft PO
-- ============================================================
SELECT _set_purchasing_rpc_context('77771111-1111-1111-1111-111111111111', 'admin', '7777000a-aaaa-aaaa-aaaa-aaaaaaaaaaaa'::UUID);

INSERT INTO public._purchasing_rpc_test_results (key, payload)
SELECT 'cancel_draft',
       r
FROM public.cancel_purchase_order(
  jsonb_build_object(
    'company_id', '77771111-1111-1111-1111-111111111111',
    'purchase_order_id', (SELECT po_id FROM public._purchasing_rpc_test_results WHERE key = 'po_draft'),
    'reason', 'No longer needed'
  )
) AS r;

SELECT is(
  (SELECT (payload->>'cancelled')::BOOL FROM public._purchasing_rpc_test_results WHERE key = 'cancel_draft'),
  TRUE,
  'cancel_purchase_order: returns cancelled = true for draft PO'
);

SELECT is(
  (SELECT payload->>'previous_status' FROM public._purchasing_rpc_test_results WHERE key = 'cancel_draft'),
  'draft',
  'cancel_purchase_order: previous_status = draft'
);

-- Verify PO status in DB
SELECT is(
  (SELECT status FROM public.purchase_orders WHERE id = (SELECT po_id FROM public._purchasing_rpc_test_results WHERE key = 'po_draft')),
  'cancelled',
  'cancel_purchase_order: PO status is cancelled in DB'
);

SELECT _reset_purchasing_rpc_context();

-- ============================================================
-- Test 16b: cancel_purchase_order — reject already-cancelled PO (W3)
-- ============================================================
SELECT _set_purchasing_rpc_context('77771111-1111-1111-1111-111111111111', 'admin', '7777000a-aaaa-aaaa-aaaa-aaaaaaaaaaaa'::UUID);

SELECT throws_ok(
  format(
    'SELECT public.cancel_purchase_order(''{"company_id":"77771111-1111-1111-1111-111111111111","purchase_order_id":"%s"}''::JSONB)',
    (SELECT po_id::text FROM public._purchasing_rpc_test_results WHERE key = 'po_draft')
  ),
  NULL,
  NULL,
  'cancel_purchase_order: rejects already-cancelled PO'
);

SELECT _reset_purchasing_rpc_context();

-- ============================================================
-- Test 16c: receive_purchase_transaction — reject cancelled PO
-- ============================================================
SELECT _set_purchasing_rpc_context('77771111-1111-1111-1111-111111111111', 'admin', '7777000a-aaaa-aaaa-aaaa-aaaaaaaaaaaa'::UUID);

DO $$
DECLARE
  v_po_id UUID;
  v_po_item_id UUID;
BEGIN
  SELECT po_id INTO v_po_id FROM public._purchasing_rpc_test_results WHERE key = 'po_draft';
  SELECT id INTO v_po_item_id FROM public.purchase_order_items WHERE purchase_order_id = v_po_id LIMIT 1;

  PERFORM public.receive_purchase_transaction(
    jsonb_build_object(
      'company_id', '77771111-1111-1111-1111-111111111111',
      'branch_id', '7777aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      'purchase_order_id', v_po_id,
      'receipt_number', 'RCV-ON-CANCELLED',
      'items', jsonb_build_array(
        jsonb_build_object('purchase_order_item_id', v_po_item_id, 'received_qty', 1)
      )
    )
  );
EXCEPTION
  WHEN OTHERS THEN
    INSERT INTO public._purchasing_rpc_test_results (key, payload)
    VALUES ('reject_cancelled', jsonb_build_object('error', SQLERRM));
END;
$$;

SELECT ok(
  (SELECT payload->>'error' FROM public._purchasing_rpc_test_results WHERE key = 'reject_cancelled') IS NOT NULL,
  'receive_purchase_transaction: rejects cancelled PO'
);

SELECT _reset_purchasing_rpc_context();

-- ============================================================
-- Test 17: cancel_purchase_order — cancel partial PO
-- ============================================================
SELECT _set_purchasing_rpc_context('77771111-1111-1111-1111-111111111111', 'admin', '7777000a-aaaa-aaaa-aaaa-aaaaaaaaaaaa'::UUID);

INSERT INTO public._purchasing_rpc_test_results (key, payload)
SELECT 'cancel_partial',
       r
FROM public.cancel_purchase_order(
  jsonb_build_object(
    'company_id', '77771111-1111-1111-1111-111111111111',
    'purchase_order_id', (SELECT po_id FROM public._purchasing_rpc_test_results WHERE key = 'po_partial'),
    'reason', 'Supplier discontinued'
  )
) AS r;

SELECT is(
  (SELECT (payload->>'cancelled')::BOOL FROM public._purchasing_rpc_test_results WHERE key = 'cancel_partial'),
  TRUE,
  'cancel_purchase_order: cancels partial PO'
);

SELECT is(
  (SELECT status FROM public.purchase_orders WHERE id = (SELECT po_id FROM public._purchasing_rpc_test_results WHERE key = 'po_partial')),
  'cancelled',
  'cancel_purchase_order: partial PO status is cancelled in DB'
);

SELECT _reset_purchasing_rpc_context();

-- ============================================================
-- Test 18: cancel_purchase_order — reject received PO
-- ============================================================
SELECT _set_purchasing_rpc_context('77771111-1111-1111-1111-111111111111', 'admin', '7777000a-aaaa-aaaa-aaaa-aaaaaaaaaaaa'::UUID);

SELECT throws_ok(
  format(
    'SELECT public.cancel_purchase_order(''{"company_id":"77771111-1111-1111-1111-111111111111","purchase_order_id":"%s"}''::JSONB)',
    (SELECT po_id::text FROM public._purchasing_rpc_test_results WHERE key = 'po_received')
  ),
  NULL,
  NULL,
  'cancel_purchase_order: rejects received PO'
);

SELECT _reset_purchasing_rpc_context();

-- ============================================================
-- Test 19: cancel_purchase_order — reject cross-company
-- ============================================================
SELECT _set_purchasing_rpc_context('77772222-2222-2222-2222-222222222222', 'admin', '7777000c-cccc-cccc-cccc-cccccccccccc'::UUID);

SELECT throws_ok(
  format(
    'SELECT public.cancel_purchase_order(''{"company_id":"77772222-2222-2222-2222-222222222222","purchase_order_id":"%s"}''::JSONB)',
    (SELECT po_id::text FROM public._purchasing_rpc_test_results WHERE key = 'po_draft')
  ),
  NULL,
  NULL,
  'cancel_purchase_order: rejects cross-company PO'
);

SELECT _reset_purchasing_rpc_context();

-- ============================================================
-- Test 20: cancel_purchase_order — reject cashier
-- ============================================================
SELECT _set_purchasing_rpc_context('77771111-1111-1111-1111-111111111111', 'cashier', '7777000b-bbbb-bbbb-bbbb-bbbbbbbbbbbb'::UUID);

SELECT throws_ok(
  $$ SELECT public.cancel_purchase_order('{"company_id":"77771111-1111-1111-1111-111111111111","purchase_order_id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"}'::JSONB) $$,
  NULL,
  NULL,
  'cancel_purchase_order: rejects cashier'
);

SELECT _reset_purchasing_rpc_context();

-- ============================================================
-- Test 21: manage_supplier — create with all fields
-- ============================================================
SELECT _set_purchasing_rpc_context('77771111-1111-1111-1111-111111111111', 'admin', '7777000a-aaaa-aaaa-aaaa-aaaaaaaaaaaa'::UUID);

INSERT INTO public._purchasing_rpc_test_results (key, payload, supplier_id)
SELECT 'supplier_create_full',
       r,
       (r->>'supplier_id')::UUID
FROM public.manage_supplier(
  '{"action":"create","company_id":"77771111-1111-1111-1111-111111111111","name":"Full Fields Co","slug":"full-fields-co","tax_id":"TAX-FULL","contact_name":"Alice","phone":"555-0200","email":"alice@full.com","address":"123 Main St","notes":"Notes here"}'::JSONB
) AS r;

SELECT ok(
  (SELECT payload->>'supplier_id' FROM public._purchasing_rpc_test_results WHERE key = 'supplier_create_full') IS NOT NULL,
  'manage_supplier create: returns supplier_id'
);

-- Verify supplier was created with correct fields
SELECT is(
  (SELECT name FROM public.suppliers WHERE id = (SELECT supplier_id FROM public._purchasing_rpc_test_results WHERE key = 'supplier_create_full')),
  'Full Fields Co',
  'manage_supplier create: name stored correctly'
);

SELECT is(
  (SELECT email FROM public.suppliers WHERE id = (SELECT supplier_id FROM public._purchasing_rpc_test_results WHERE key = 'supplier_create_full')),
  'alice@full.com',
  'manage_supplier create: email stored correctly'
);

SELECT is(
  (SELECT is_active FROM public.suppliers WHERE id = (SELECT supplier_id FROM public._purchasing_rpc_test_results WHERE key = 'supplier_create_full')),
  TRUE,
  'manage_supplier create: is_active = true'
);

SELECT _reset_purchasing_rpc_context();

-- ============================================================
-- Test 22: manage_supplier — slug uniqueness per company
-- ============================================================
SELECT _set_purchasing_rpc_context('77771111-1111-1111-1111-111111111111', 'admin', '7777000a-aaaa-aaaa-aaaa-aaaaaaaaaaaa'::UUID);

SELECT throws_ok(
  $$ SELECT public.manage_supplier('{"action":"create","company_id":"77771111-1111-1111-1111-111111111111","name":"Duplicate Slug","slug":"acme-corp","contact_name":"Dup"}'::JSONB) $$,
  NULL,
  'A supplier with this slug already exists in your company',
  'manage_supplier: rejects duplicate slug in same company'
);

SELECT _reset_purchasing_rpc_context();

-- ============================================================
-- Test 23: manage_supplier — update supplier
-- ============================================================
SELECT _set_purchasing_rpc_context('77771111-1111-1111-1111-111111111111', 'admin', '7777000a-aaaa-aaaa-aaaa-aaaaaaaaaaaa'::UUID);

SELECT lives_ok(
  format(
    'SELECT public.manage_supplier(''{"action":"update","company_id":"77771111-1111-1111-1111-111111111111","supplier_id":"%s","name":"ACME Corp Updated","phone":"555-9999"}''::JSONB)',
    (SELECT supplier_id::text FROM public._purchasing_rpc_test_results WHERE key = 'supplier_a1_create')
  ),
  'manage_supplier update: updates supplier name and phone'
);

SELECT is(
  (SELECT name FROM public.suppliers WHERE id = (SELECT supplier_id FROM public._purchasing_rpc_test_results WHERE key = 'supplier_a1_create')),
  'ACME Corp Updated',
  'manage_supplier update: name was updated'
);

SELECT is(
  (SELECT phone FROM public.suppliers WHERE id = (SELECT supplier_id FROM public._purchasing_rpc_test_results WHERE key = 'supplier_a1_create')),
  '555-9999',
  'manage_supplier update: phone was updated'
);

-- Original fields should be preserved
SELECT is(
  (SELECT tax_id FROM public.suppliers WHERE id = (SELECT supplier_id FROM public._purchasing_rpc_test_results WHERE key = 'supplier_a1_create')),
  'TAX001',
  'manage_supplier update: unchanged fields preserved (tax_id)'
);

SELECT _reset_purchasing_rpc_context();

-- ============================================================
-- Test 24: manage_supplier — deactivate (logical deletion)
-- ============================================================
SELECT _set_purchasing_rpc_context('77771111-1111-1111-1111-111111111111', 'admin', '7777000a-aaaa-aaaa-aaaa-aaaaaaaaaaaa'::UUID);

INSERT INTO public._purchasing_rpc_test_results (key, payload)
SELECT 'supplier_deactivate',
       r
FROM public.manage_supplier(
  jsonb_build_object(
    'action', 'deactivate',
    'company_id', '77771111-1111-1111-1111-111111111111',
    'supplier_id', (SELECT supplier_id FROM public._purchasing_rpc_test_results WHERE key = 'supplier_a2_create')
  )
) AS r;

SELECT is(
  (SELECT (payload->>'deactivated')::BOOL FROM public._purchasing_rpc_test_results WHERE key = 'supplier_deactivate'),
  TRUE,
  'manage_supplier deactivate: returns deactivated = true'
);

-- Verify logical deletion
SELECT is(
  (SELECT is_active FROM public.suppliers WHERE id = (SELECT supplier_id FROM public._purchasing_rpc_test_results WHERE key = 'supplier_a2_create')),
  FALSE,
  'manage_supplier deactivate: is_active = false'
);

SELECT ok(
  (SELECT deleted_at FROM public.suppliers WHERE id = (SELECT supplier_id FROM public._purchasing_rpc_test_results WHERE key = 'supplier_a2_create')) IS NOT NULL,
  'manage_supplier deactivate: deleted_at is set'
);

SELECT ok(
  (SELECT deleted_by FROM public.suppliers WHERE id = (SELECT supplier_id FROM public._purchasing_rpc_test_results WHERE key = 'supplier_a2_create')) IS NOT NULL,
  'manage_supplier deactivate: deleted_by is set'
);

-- Row still exists (no physical deletion)
SELECT is(
  (SELECT count(*)::bigint FROM public.suppliers WHERE id = (SELECT supplier_id FROM public._purchasing_rpc_test_results WHERE key = 'supplier_a2_create')),
  1::bigint,
  'manage_supplier deactivate: row preserved (logical deletion)'
);

SELECT _reset_purchasing_rpc_context();

-- ============================================================
-- Test 25: manage_supplier — reject deactivate already inactive
-- ============================================================
SELECT _set_purchasing_rpc_context('77771111-1111-1111-1111-111111111111', 'admin', '7777000a-aaaa-aaaa-aaaa-aaaaaaaaaaaa'::UUID);

SELECT throws_ok(
  format(
    'SELECT public.manage_supplier(''{"action":"deactivate","company_id":"77771111-1111-1111-1111-111111111111","supplier_id":"%s"}''::JSONB)',
    (SELECT supplier_id::text FROM public._purchasing_rpc_test_results WHERE key = 'supplier_a2_create')
  ),
  NULL,
  NULL,
  'manage_supplier: rejects deactivate on already inactive supplier'
);

SELECT _reset_purchasing_rpc_context();

-- ============================================================
-- Test 26: manage_supplier — cross-company update rejection
-- ============================================================
SELECT _set_purchasing_rpc_context('77772222-2222-2222-2222-222222222222', 'admin', '7777000c-cccc-cccc-cccc-cccccccccccc'::UUID);

SELECT throws_ok(
  format(
    'SELECT public.manage_supplier(''{"action":"update","company_id":"77772222-2222-2222-2222-222222222222","supplier_id":"%s","name":"Hacked"}''::JSONB)',
    (SELECT supplier_id::text FROM public._purchasing_rpc_test_results WHERE key = 'supplier_a1_create')
  ),
  NULL,
  NULL,
  'manage_supplier: rejects update of supplier from different company'
);

SELECT _reset_purchasing_rpc_context();

-- ============================================================
-- Test 27: manage_supplier — reject cashier
-- ============================================================
SELECT _set_purchasing_rpc_context('77771111-1111-1111-1111-111111111111', 'cashier', '7777000b-bbbb-bbbb-bbbb-bbbbbbbbbbbb'::UUID);

SELECT throws_ok(
  $$ SELECT public.manage_supplier('{"action":"create","company_id":"77771111-1111-1111-1111-111111111111","name":"Cashier Supplier","slug":"cashier-supplier"}'::JSONB) $$,
  NULL,
  NULL,
  'manage_supplier: rejects cashier'
);

SELECT _reset_purchasing_rpc_context();

-- ============================================================
-- Test 28: receive_purchase_transaction — atomic rollback when
-- inventory RPC fails (e.g., missing variant)
-- ============================================================
SELECT _set_purchasing_rpc_context('77771111-1111-1111-1111-111111111111', 'admin', '7777000a-aaaa-aaaa-aaaa-aaaaaaaaaaaa'::UUID);

-- Create a PO for atomicity test
DO $$
DECLARE
  v_po_id UUID;
  v_po_item_id UUID;
  v_po_item_id_2 UUID;
  v_receipt_count_before BIGINT;
  v_item_count_before BIGINT;
  v_lot_count_before BIGINT;
  v_movement_count_before BIGINT;
  v_supplier_id UUID;
  v_result JSONB;
BEGIN
  SELECT supplier_id INTO v_supplier_id FROM public._purchasing_rpc_test_results WHERE key = 'supplier_a1_create';

  v_result := public.create_purchase_order(
    jsonb_build_object(
      'company_id', '77771111-1111-1111-1111-111111111111',
      'branch_id', '7777aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      'supplier_id', v_supplier_id,
      'order_number', 'PO-ATOMIC-001',
      'items', jsonb_build_array(
        jsonb_build_object('variant_id', '7777f000-0000-0000-0000-000000000001', 'ordered_qty', 10, 'unit_cost', 50.00),
        jsonb_build_object('variant_id', '7777f000-0000-0000-0000-000000000002', 'ordered_qty', 5, 'unit_cost', 25.00)
      )
    )
  );

  v_po_id := (v_result->>'purchase_order_id')::UUID;

  -- Set to sent
  RESET ROLE;
  UPDATE public.purchase_orders SET status = 'sent' WHERE id = v_po_id;

  PERFORM _set_purchasing_rpc_context('77771111-1111-1111-1111-111111111111', 'admin', '7777000a-aaaa-aaaa-aaaa-aaaaaaaaaaaa'::UUID);

  SELECT id INTO v_po_item_id FROM public.purchase_order_items WHERE purchase_order_id = v_po_id AND variant_id = '7777f000-0000-0000-0000-000000000001';
  SELECT id INTO v_po_item_id_2 FROM public.purchase_order_items WHERE purchase_order_id = v_po_id AND variant_id = '7777f000-0000-0000-0000-000000000002';

  -- Deactivate variant 2 to cause receive_purchase_lot to fail
  RESET ROLE;
  UPDATE public.product_variants SET is_active = FALSE WHERE id = '7777f000-0000-0000-0000-000000000002';

  PERFORM _set_purchasing_rpc_context('77771111-1111-1111-1111-111111111111', 'admin', '7777000a-aaaa-aaaa-aaaa-aaaaaaaaaaaa'::UUID);

  -- Count before
  SELECT count(*) INTO v_receipt_count_before FROM public.purchase_receipts;
  SELECT count(*) INTO v_item_count_before FROM public.purchase_receipt_items WHERE company_id = '77771111-1111-1111-1111-111111111111';
  SELECT count(*) INTO v_lot_count_before FROM public.stock_lots WHERE company_id = '77771111-1111-1111-1111-111111111111';
  SELECT count(*) INTO v_movement_count_before FROM public.stock_movements WHERE company_id = '77771111-1111-1111-1111-111111111111';

  -- Attempt receipt with both items (item 2 will fail because variant is inactive)
  BEGIN
    PERFORM public.receive_purchase_transaction(
      jsonb_build_object(
        'company_id', '77771111-1111-1111-1111-111111111111',
        'branch_id', '7777aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
        'purchase_order_id', v_po_id,
        'receipt_number', 'RCV-ATOMIC-FAIL',
        'items', jsonb_build_array(
          jsonb_build_object('purchase_order_item_id', v_po_item_id, 'received_qty', 3),
          jsonb_build_object('purchase_order_item_id', v_po_item_id_2, 'received_qty', 2)
        )
      )
    );
  EXCEPTION
    WHEN OTHERS THEN
      -- Expected: transaction should rollback
      NULL;
  END;

  -- Restore variant active status
  RESET ROLE;
  UPDATE public.product_variants SET is_active = TRUE WHERE id = '7777f000-0000-0000-0000-000000000002';

  -- Verify no receipt rows persisted
  INSERT INTO public._purchasing_rpc_test_results (key, payload)
  VALUES (
    'atomic_rollback',
    jsonb_build_object(
      'receipts_unchanged', (SELECT count(*) = v_receipt_count_before FROM public.purchase_receipts),
      'items_unchanged', (SELECT count(*) = v_item_count_before FROM public.purchase_receipt_items WHERE company_id = '77771111-1111-1111-1111-111111111111'),
      'lots_unchanged', (SELECT count(*) = v_lot_count_before FROM public.stock_lots WHERE company_id = '77771111-1111-1111-1111-111111111111'),
      'movements_unchanged', (SELECT count(*) = v_movement_count_before FROM public.stock_movements WHERE company_id = '77771111-1111-1111-1111-111111111111'),
      'po_status_unchanged', (SELECT status = 'sent' FROM public.purchase_orders WHERE id = v_po_id)
    )
  );
END;
$$;

SELECT is(
  (SELECT (payload->>'receipts_unchanged')::BOOL FROM public._purchasing_rpc_test_results WHERE key = 'atomic_rollback'),
  TRUE,
  'receive_purchase_transaction atomicity: no receipt persisted on failure'
);

SELECT is(
  (SELECT (payload->>'items_unchanged')::BOOL FROM public._purchasing_rpc_test_results WHERE key = 'atomic_rollback'),
  TRUE,
  'receive_purchase_transaction atomicity: no receipt items persisted on failure'
);

SELECT is(
  (SELECT (payload->>'lots_unchanged')::BOOL FROM public._purchasing_rpc_test_results WHERE key = 'atomic_rollback'),
  TRUE,
  'receive_purchase_transaction atomicity: no inventory lots persisted on failure'
);

SELECT is(
  (SELECT (payload->>'movements_unchanged')::BOOL FROM public._purchasing_rpc_test_results WHERE key = 'atomic_rollback'),
  TRUE,
  'receive_purchase_transaction atomicity: no stock movements persisted on failure'
);

SELECT is(
  (SELECT (payload->>'po_status_unchanged')::BOOL FROM public._purchasing_rpc_test_results WHERE key = 'atomic_rollback'),
  TRUE,
  'receive_purchase_transaction atomicity: PO status unchanged on failure'
);

SELECT _reset_purchasing_rpc_context();

-- ============================================================
-- Clean up helper table and functions
-- ============================================================
DROP TABLE IF EXISTS public._purchasing_rpc_test_results;
DROP FUNCTION _set_purchasing_rpc_context(UUID, TEXT, UUID);
DROP FUNCTION _reset_purchasing_rpc_context();

-- ============================================================
-- Finish
-- ============================================================
SELECT * FROM finish();
ROLLBACK;
