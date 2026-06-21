-- pgTAP: Inventory domain RPC tests
-- Verifies hardened EXECUTE/search_path, FEFO multi-lot deduction,
-- adjustment behavior, reconciliation drift reporting, and V1 rejection paths.
-- (source: RI4-RI11)

BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap;

SELECT plan(34);

INSERT INTO public.companies (id, name, slug)
VALUES
  ('99999999-9999-9999-9999-999999999991', 'Inventory RPC Co A', 'inventory-rpc-co-a'),
  ('99999999-9999-9999-9999-999999999992', 'Inventory RPC Co B', 'inventory-rpc-co-b');

INSERT INTO public.branches (id, company_id, name, slug)
VALUES
  ('99991111-1111-1111-1111-111111111111', '99999999-9999-9999-9999-999999999991', 'Main Branch', 'main-branch'),
  ('99992222-2222-2222-2222-222222222222', '99999999-9999-9999-9999-999999999991', 'Overflow Branch', 'overflow-branch'),
  ('99993333-3333-3333-3333-333333333333', '99999999-9999-9999-9999-999999999992', 'Other Branch', 'other-branch');

INSERT INTO public.brands (id, company_id, name, slug)
VALUES
  ('99990000-0000-0000-0000-000000000001', '99999999-9999-9999-9999-999999999991', 'Inventory RPC Brand A', 'inventory-rpc-brand-a'),
  ('99990000-0000-0000-0000-000000000002', '99999999-9999-9999-9999-999999999992', 'Inventory RPC Brand B', 'inventory-rpc-brand-b');

INSERT INTO public.categories (id, company_id, name, slug)
VALUES
  ('99991000-0000-0000-0000-000000000001', '99999999-9999-9999-9999-999999999991', 'Inventory RPC Category A', 'inventory-rpc-category-a'),
  ('99991000-0000-0000-0000-000000000002', '99999999-9999-9999-9999-999999999992', 'Inventory RPC Category B', 'inventory-rpc-category-b');

INSERT INTO public.products (id, company_id, name, slug, brand_id, category_id)
VALUES
  ('99992000-0000-0000-0000-000000000001', '99999999-9999-9999-9999-999999999991', 'Inventory RPC Product A', 'inventory-rpc-product-a', '99990000-0000-0000-0000-000000000001', '99991000-0000-0000-0000-000000000001'),
  ('99992000-0000-0000-0000-000000000002', '99999999-9999-9999-9999-999999999992', 'Inventory RPC Product B', 'inventory-rpc-product-b', '99990000-0000-0000-0000-000000000002', '99991000-0000-0000-0000-000000000002');

INSERT INTO public.product_variants (id, company_id, product_id, sku, name)
VALUES
  ('99993000-0000-0000-0000-000000000001', '99999999-9999-9999-9999-999999999991', '99992000-0000-0000-0000-000000000001', 'INV-RPC-A1', 'Inventory RPC Variant A1'),
  ('99993000-0000-0000-0000-000000000002', '99999999-9999-9999-9999-999999999991', '99992000-0000-0000-0000-000000000001', 'INV-RPC-A2', 'Inventory RPC Variant A2'),
  ('99993000-0000-0000-0000-000000000003', '99999999-9999-9999-9999-999999999991', '99992000-0000-0000-0000-000000000001', 'INV-RPC-A3', 'Inventory RPC Variant A3'),
  ('99993000-0000-0000-0000-000000000004', '99999999-9999-9999-9999-999999999991', '99992000-0000-0000-0000-000000000001', 'INV-RPC-A4', 'Inventory RPC Variant A4'),
  ('99993000-0000-0000-0000-000000000005', '99999999-9999-9999-9999-999999999992', '99992000-0000-0000-0000-000000000002', 'INV-RPC-B1', 'Inventory RPC Variant B1');

INSERT INTO auth.users (id, email, raw_app_meta_data, raw_user_meta_data)
VALUES
  ('9999aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'inventory-rpc-admin-a@test.com',
   '{"company_id": "99999999-9999-9999-9999-999999999991", "role": "admin", "branch_id": "99991111-1111-1111-1111-111111111111"}',
   '{"full_name": "Inventory RPC Admin A"}'),
  ('9999bbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'inventory-rpc-cashier-a@test.com',
   '{"company_id": "99999999-9999-9999-9999-999999999991", "role": "cashier", "branch_id": "99991111-1111-1111-1111-111111111111"}',
   '{"full_name": "Inventory RPC Cashier A"}'),
  ('9999cccc-cccc-cccc-cccc-cccccccccccc', 'inventory-rpc-admin-b@test.com',
   '{"company_id": "99999999-9999-9999-9999-999999999992", "role": "admin", "branch_id": "99993333-3333-3333-3333-333333333333"}',
   '{"full_name": "Inventory RPC Admin B"}')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.profiles (id, full_name)
VALUES
  ('9999aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'Inventory RPC Admin A'),
  ('9999bbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'Inventory RPC Cashier A'),
  ('9999cccc-cccc-cccc-cccc-cccccccccccc', 'Inventory RPC Admin B')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.company_users (user_id, company_id, role)
VALUES
  ('9999aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', '99999999-9999-9999-9999-999999999991', 'admin'),
  ('9999bbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', '99999999-9999-9999-9999-999999999991', 'cashier'),
  ('9999cccc-cccc-cccc-cccc-cccccccccccc', '99999999-9999-9999-9999-999999999992', 'admin')
ON CONFLICT (user_id, company_id) DO NOTHING;

CREATE OR REPLACE FUNCTION _set_inventory_rpc_context(p_company_id UUID, p_role TEXT, p_user_id UUID, p_branch_id UUID DEFAULT NULL)
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

CREATE OR REPLACE FUNCTION _reset_inventory_rpc_context()
RETURNS VOID AS $$
BEGIN
  RESET ROLE;
  PERFORM set_config('request.jwt.claims', '', true);
END;
$$ LANGUAGE plpgsql;

CREATE TABLE IF NOT EXISTS public._inventory_rpc_test_results (
  key TEXT PRIMARY KEY,
  payload JSONB
);
TRUNCATE public._inventory_rpc_test_results;
GRANT ALL ON public._inventory_rpc_test_results TO authenticated;
GRANT ALL ON public._inventory_rpc_test_results TO anon;

SELECT ok(
  (SELECT count(*)::bigint FROM pg_proc p
   JOIN pg_namespace n ON p.pronamespace = n.oid
   WHERE n.nspname = 'public'
     AND p.proname IN (
       'receive_purchase_lot',
       'record_sale_return',
       'record_waste',
       'record_expiration',
       'record_sale_deduction',
       'adjust_inventory',
       'reconcile_inventory',
       'reserve_stock',
       'release_reservation'
     )
     AND p.prosecdef = TRUE
     AND p.proconfig IS NOT NULL
     AND '{search_path=public}'::text[] <@ p.proconfig
  ) = 9::bigint,
  'All 9 inventory RPCs have SECURITY DEFINER with fixed search_path = public'
);

SELECT ok(
  (SELECT count(*)::bigint FROM pg_proc p
   JOIN pg_namespace n ON p.pronamespace = n.oid
   WHERE n.nspname = 'public'
     AND p.proname IN (
       'receive_purchase_lot',
       'record_sale_return',
       'record_waste',
       'record_expiration',
       'record_sale_deduction',
       'adjust_inventory',
       'reconcile_inventory',
       'reserve_stock',
       'release_reservation'
     )
     AND has_function_privilege('authenticated', format('public.%I(jsonb)', p.proname), 'EXECUTE')
  ) = 9::bigint,
  'Authenticated role has EXECUTE on all 9 inventory RPCs'
);

SELECT ok(
  (SELECT count(*)::bigint FROM pg_proc p
   JOIN pg_namespace n ON p.pronamespace = n.oid
   WHERE n.nspname = 'public'
     AND p.proname IN (
       'receive_purchase_lot',
       'record_sale_return',
       'record_waste',
       'record_expiration',
       'record_sale_deduction',
       'adjust_inventory',
       'reconcile_inventory',
       'reserve_stock',
       'release_reservation'
     )
     AND has_function_privilege('anon', format('public.%I(jsonb)', p.proname), 'EXECUTE')
  ) = 0::bigint,
  'Anon role has no EXECUTE privileges on inventory RPCs'
);

SELECT ok(
  pg_get_functiondef('public.record_sale_deduction(jsonb)'::regprocedure) LIKE '%FOR UPDATE%',
  'record_sale_deduction uses FOR UPDATE row locking'
);

SELECT ok(
  pg_get_functiondef('public.adjust_inventory(jsonb)'::regprocedure) LIKE '%FOR UPDATE%',
  'adjust_inventory FEFO decrease path uses FOR UPDATE row locking'
);

SELECT _set_inventory_rpc_context('99999999-9999-9999-9999-999999999991', 'admin', '9999aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'::UUID, '99991111-1111-1111-1111-111111111111'::UUID);

INSERT INTO public._inventory_rpc_test_results (key, payload)
SELECT 'purchase_auto', public.receive_purchase_lot(
  '{"company_id":"99999999-9999-9999-9999-999999999991","branch_id":"99991111-1111-1111-1111-111111111111","variant_id":"99993000-0000-0000-0000-000000000001","qty":50}'::JSONB
);

SELECT ok(
  (SELECT payload->>'lot_code' FROM public._inventory_rpc_test_results WHERE key = 'purchase_auto') LIKE 'LOT-MAINBRAN-%',
  'receive_purchase_lot auto-generates LOT-prefixed codes from the branch slug'
);

SELECT is(
  (SELECT remaining_qty FROM public.stock_lots WHERE id = ((SELECT payload->>'lot_id' FROM public._inventory_rpc_test_results WHERE key = 'purchase_auto')::UUID)),
  50::numeric,
  'receive_purchase_lot creates lot with remaining_qty equal to qty'
);

SELECT is(
  (SELECT count(*)::bigint FROM public.stock_movements WHERE lot_id = ((SELECT payload->>'lot_id' FROM public._inventory_rpc_test_results WHERE key = 'purchase_auto')::UUID) AND movement_type = 'purchase_receipt'),
  1::bigint,
  'receive_purchase_lot inserts a purchase_receipt movement'
);

SELECT lives_ok(
  format(
    'SELECT public.record_sale_return(''{"company_id":"99999999-9999-9999-9999-999999999991","branch_id":"99991111-1111-1111-1111-111111111111","variant_id":"99993000-0000-0000-0000-000000000001","lot_id":"%s","qty":2,"reference_type":"sale"}''::JSONB)',
    (SELECT payload->>'lot_id' FROM public._inventory_rpc_test_results WHERE key = 'purchase_auto')
  ),
  'record_sale_return succeeds for an owned lot'
);

SELECT is(
  (SELECT remaining_qty FROM public.stock_lots WHERE id = ((SELECT payload->>'lot_id' FROM public._inventory_rpc_test_results WHERE key = 'purchase_auto')::UUID)),
  52::numeric,
  'record_sale_return adds quantity back into the lot'
);

SELECT lives_ok(
  format(
    'SELECT public.record_waste(''{"company_id":"99999999-9999-9999-9999-999999999991","branch_id":"99991111-1111-1111-1111-111111111111","variant_id":"99993000-0000-0000-0000-000000000001","lot_id":"%s","qty":1,"reason":"damaged bottle"}''::JSONB)',
    (SELECT payload->>'lot_id' FROM public._inventory_rpc_test_results WHERE key = 'purchase_auto')
  ),
  'record_waste succeeds with a required reason'
);

SELECT is(
  (SELECT remaining_qty FROM public.stock_lots WHERE id = ((SELECT payload->>'lot_id' FROM public._inventory_rpc_test_results WHERE key = 'purchase_auto')::UUID)),
  51::numeric,
  'record_waste deducts quantity from the selected lot'
);

INSERT INTO public._inventory_rpc_test_results (key, payload)
SELECT 'expired_purchase', public.receive_purchase_lot(
  '{"company_id":"99999999-9999-9999-9999-999999999991","branch_id":"99991111-1111-1111-1111-111111111111","variant_id":"99993000-0000-0000-0000-000000000002","qty":7,"expiration_date":"2099-01-01"}'::JSONB
);

SELECT _reset_inventory_rpc_context();

UPDATE public.stock_lots
SET expiration_date = '2020-01-01'
WHERE id = ((SELECT payload->>'lot_id' FROM public._inventory_rpc_test_results WHERE key = 'expired_purchase')::UUID);

SELECT _set_inventory_rpc_context('99999999-9999-9999-9999-999999999991', 'admin', '9999aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'::UUID, '99991111-1111-1111-1111-111111111111'::UUID);

SELECT lives_ok(
  format(
    'SELECT public.record_expiration(''{"company_id":"99999999-9999-9999-9999-999999999991","branch_id":"99991111-1111-1111-1111-111111111111","variant_id":"99993000-0000-0000-0000-000000000002","lot_id":"%s"}''::JSONB)',
    (SELECT payload->>'lot_id' FROM public._inventory_rpc_test_results WHERE key = 'expired_purchase')
  ),
  'record_expiration expires a specific expired lot'
);

SELECT is(
  (SELECT status FROM public.stock_lots WHERE id = ((SELECT payload->>'lot_id' FROM public._inventory_rpc_test_results WHERE key = 'expired_purchase')::UUID)),
  'expired',
  'record_expiration sets lot status to expired'
);

SELECT is(
  (SELECT remaining_qty FROM public.stock_lots WHERE id = ((SELECT payload->>'lot_id' FROM public._inventory_rpc_test_results WHERE key = 'expired_purchase')::UUID)),
  0::numeric,
  'record_expiration drains remaining_qty to zero'
);

INSERT INTO public._inventory_rpc_test_results (key, payload)
SELECT 'sale_fefo_1', public.receive_purchase_lot(
  '{"company_id":"99999999-9999-9999-9999-999999999991","branch_id":"99991111-1111-1111-1111-111111111111","variant_id":"99993000-0000-0000-0000-000000000003","qty":10,"lot_code":"FEFO-LOT-A","expiration_date":"2096-01-10"}'::JSONB
);

INSERT INTO public._inventory_rpc_test_results (key, payload)
SELECT 'sale_fefo_2', public.receive_purchase_lot(
  '{"company_id":"99999999-9999-9999-9999-999999999991","branch_id":"99991111-1111-1111-1111-111111111111","variant_id":"99993000-0000-0000-0000-000000000003","qty":20,"lot_code":"FEFO-LOT-B","expiration_date":"2096-02-10"}'::JSONB
);

INSERT INTO public._inventory_rpc_test_results (key, payload)
SELECT 'sale_result', public.record_sale_deduction(
  '{"company_id":"99999999-9999-9999-9999-999999999991","branch_id":"99991111-1111-1111-1111-111111111111","variant_id":"99993000-0000-0000-0000-000000000003","qty":15,"reference_type":"sale"}'::JSONB
);

SELECT is(
  (SELECT jsonb_array_length(payload->'movement_ids') FROM public._inventory_rpc_test_results WHERE key = 'sale_result'),
  2,
  'record_sale_deduction creates one movement per affected lot'
);

SELECT is(
  (SELECT payload->'lots_affected'->0->>'lot_code' FROM public._inventory_rpc_test_results WHERE key = 'sale_result'),
  'FEFO-LOT-A',
  'record_sale_deduction consumes the earliest-expiring lot first'
);

SELECT is(
  (SELECT remaining_qty FROM public.stock_lots WHERE id = ((SELECT payload->>'lot_id' FROM public._inventory_rpc_test_results WHERE key = 'sale_fefo_1')::UUID)),
  0::numeric,
  'record_sale_deduction fully depletes the first FEFO lot'
);

SELECT is(
  (SELECT remaining_qty FROM public.stock_lots WHERE id = ((SELECT payload->>'lot_id' FROM public._inventory_rpc_test_results WHERE key = 'sale_fefo_2')::UUID)),
  15::numeric,
  'record_sale_deduction partially deducts the second FEFO lot'
);

SELECT throws_ok(
  $$ SELECT public.record_sale_deduction('{"company_id":"99999999-9999-9999-9999-999999999991","branch_id":"99991111-1111-1111-1111-111111111111","variant_id":"99993000-0000-0000-0000-000000000003","qty":999,"reference_type":"sale"}'::JSONB) $$,
  NULL,
  'Insufficient stock for the requested sale deduction',
  'record_sale_deduction rejects insufficient stock with no partial deduction'
);

SELECT is(
  (SELECT SUM(remaining_qty) FROM public.stock_lots WHERE company_id = '99999999-9999-9999-9999-999999999991' AND branch_id = '99991111-1111-1111-1111-111111111111' AND variant_id = '99993000-0000-0000-0000-000000000003'),
  15::numeric,
  'record_sale_deduction rollback preserves previous balances after failure'
);

INSERT INTO public._inventory_rpc_test_results (key, payload)
SELECT 'adjust_plus', public.adjust_inventory(
  '{"company_id":"99999999-9999-9999-9999-999999999991","branch_id":"99991111-1111-1111-1111-111111111111","variant_id":"99993000-0000-0000-0000-000000000004","qty":5,"reason":"cycle count gain"}'::JSONB
);

SELECT ok(
  (SELECT payload->>'lot_code' FROM public._inventory_rpc_test_results WHERE key = 'adjust_plus') LIKE 'ADJ-MAINBRAN-%',
  'adjust_inventory increase creates an ADJ-prefixed lot'
);

SELECT is(
  (SELECT cost_per_unit FROM public.stock_lots WHERE id = ((SELECT payload->>'lot_id' FROM public._inventory_rpc_test_results WHERE key = 'adjust_plus')::UUID)) IS NULL,
  TRUE,
  'adjust_inventory leaves cost_per_unit NULL when omitted'
);

INSERT INTO public._inventory_rpc_test_results (key, payload)
SELECT 'adjust_fefo_1', public.receive_purchase_lot(
  '{"company_id":"99999999-9999-9999-9999-999999999991","branch_id":"99991111-1111-1111-1111-111111111111","variant_id":"99993000-0000-0000-0000-000000000004","qty":4,"lot_code":"ADJ-FEFO-A","expiration_date":"2096-03-01"}'::JSONB
);

INSERT INTO public._inventory_rpc_test_results (key, payload)
SELECT 'adjust_fefo_2', public.receive_purchase_lot(
  '{"company_id":"99999999-9999-9999-9999-999999999991","branch_id":"99991111-1111-1111-1111-111111111111","variant_id":"99993000-0000-0000-0000-000000000004","qty":4,"lot_code":"ADJ-FEFO-B","expiration_date":"2096-04-01"}'::JSONB
);

INSERT INTO public._inventory_rpc_test_results (key, payload)
SELECT 'adjust_minus', public.adjust_inventory(
  '{"company_id":"99999999-9999-9999-9999-999999999991","branch_id":"99991111-1111-1111-1111-111111111111","variant_id":"99993000-0000-0000-0000-000000000004","qty":-6,"reason":"cycle count shrink"}'::JSONB
);

SELECT is(
  (SELECT jsonb_array_length(payload->'movement_ids') FROM public._inventory_rpc_test_results WHERE key = 'adjust_minus'),
  2,
  'adjust_inventory decrease emits one movement per affected FEFO lot'
);

SELECT is(
  (SELECT remaining_qty FROM public.stock_lots WHERE id = ((SELECT payload->>'lot_id' FROM public._inventory_rpc_test_results WHERE key = 'adjust_fefo_1')::UUID)),
  0::numeric,
  'adjust_inventory decrease fully consumes the earliest lot first'
);

SELECT is(
  (SELECT remaining_qty FROM public.stock_lots WHERE id = ((SELECT payload->>'lot_id' FROM public._inventory_rpc_test_results WHERE key = 'adjust_fefo_2')::UUID)),
  2::numeric,
  'adjust_inventory decrease partially consumes the next FEFO lot'
);

SELECT throws_ok(
  $$ SELECT public.adjust_inventory('{"company_id":"99999999-9999-9999-9999-999999999991","branch_id":"99991111-1111-1111-1111-111111111111","variant_id":"99993000-0000-0000-0000-000000000004","qty":1}'::JSONB) $$,
  NULL,
  'reason is required',
  'adjust_inventory requires a reason'
);

SELECT _reset_inventory_rpc_context();

UPDATE public.stock_lots
SET remaining_qty = 999
WHERE id = ((SELECT payload->>'lot_id' FROM public._inventory_rpc_test_results WHERE key = 'adjust_plus')::UUID);

SELECT _set_inventory_rpc_context('99999999-9999-9999-9999-999999999991', 'admin', '9999aaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'::UUID, '99991111-1111-1111-1111-111111111111'::UUID);

INSERT INTO public._inventory_rpc_test_results (key, payload)
SELECT 'reconcile', public.reconcile_inventory(
  '{"company_id":"99999999-9999-9999-9999-999999999991","branch_id":"99991111-1111-1111-1111-111111111111","variant_id":"99993000-0000-0000-0000-000000000004"}'::JSONB
);

SELECT is(
  (SELECT payload->>'has_drift' FROM public._inventory_rpc_test_results WHERE key = 'reconcile'),
  'true',
  'reconcile_inventory reports drift when remaining_qty diverges from movement sums'
);

SELECT is(
  (SELECT remaining_qty FROM public.stock_lots WHERE id = ((SELECT payload->>'lot_id' FROM public._inventory_rpc_test_results WHERE key = 'adjust_plus')::UUID)),
  999::numeric,
  'reconcile_inventory does not auto-fix drift in V1'
);

SELECT throws_ok(
  $$ SELECT public.reserve_stock('{"company_id":"99999999-9999-9999-9999-999999999991"}'::JSONB) $$,
  NULL,
  'Reservations are not supported in V1',
  'reserve_stock is an explicit V1 NOT_SUPPORTED path'
);

SELECT throws_ok(
  $$ SELECT public.release_reservation('{"company_id":"99999999-9999-9999-9999-999999999991"}'::JSONB) $$,
  NULL,
  'Reservations are not supported in V1',
  'release_reservation is an explicit V1 NOT_SUPPORTED path'
);

SELECT throws_ok(
  $$ SELECT public.record_sale_deduction('{"company_id":"99999999-9999-9999-9999-999999999991","branch_id":"99991111-1111-1111-1111-111111111111","variant_id":"99993000-0000-0000-0000-000000000003","qty":1,"reference_type":"transfer_out"}'::JSONB) $$,
  NULL,
  'Transfer and reservation operations are not supported in V1',
  'Transfer-linked deduction paths are explicitly rejected in V1'
);

SELECT _reset_inventory_rpc_context();

SELECT _set_inventory_rpc_context('99999999-9999-9999-9999-999999999991', 'cashier', '9999bbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'::UUID, '99991111-1111-1111-1111-111111111111'::UUID);

SELECT throws_ok(
  $$ SELECT public.receive_purchase_lot('{"company_id":"99999999-9999-9999-9999-999999999991","branch_id":"99991111-1111-1111-1111-111111111111","variant_id":"99993000-0000-0000-0000-000000000001","qty":1}'::JSONB) $$,
  NULL,
  'Only admins can receive purchase lots',
  'Cashier cannot execute admin-only inventory RPCs'
);

SELECT _reset_inventory_rpc_context();

SET ROLE anon;

SELECT throws_ok(
  $$ SELECT public.receive_purchase_lot('{"company_id":"99999999-9999-9999-9999-999999999991","branch_id":"99991111-1111-1111-1111-111111111111","variant_id":"99993000-0000-0000-0000-000000000001","qty":1}'::JSONB) $$,
  '42501',
  NULL,
  'Anon cannot execute receive_purchase_lot'
);

RESET ROLE;

DROP TABLE IF EXISTS public._inventory_rpc_test_results;
DROP FUNCTION _set_inventory_rpc_context(UUID, TEXT, UUID, UUID);
DROP FUNCTION _reset_inventory_rpc_context();

SELECT * FROM finish();
ROLLBACK;
