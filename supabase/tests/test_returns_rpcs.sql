-- pgTAP: Returns domain RPC tests
-- Verifies return_sale_item_transaction() (RR2/RR3/RR4) happy + edge paths:
--   - valid inventario return commits + restocks lot via adjust_inventory_stock
--   - cash refund appended for cash-paid portion (RR4)
--   - non-cash (card) sale creates no cash movement
--   - destination routing: merma/garantia/desecho → single negative stock_movements
--     each, no lot restock (RR3)
--   - qty-overflow rejected (returnable remaining), no partial rows (RR2)
--   - cancelled sale rejected (RR2)
--   - unknown original_batch_id for the sale_item rejected, no partial state (RR2)
--   - non-admin caller → FORBIDDEN (RR5)
--   - cash refund required but no open cash session → rejected before writes (RR4)
-- source: RR2, RR3, RR4, RR5, design D2, D3, D4

BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap;

SELECT plan(31);

-- ============================================================================
-- Seed data
-- ============================================================================
INSERT INTO public.companies (id, name, slug)
VALUES ('c1e00000-0000-0000-0000-000000000001', 'Returns RPC Co A', 'returns-rpc-co-a');

INSERT INTO public.branches (id, company_id, name, slug)
VALUES
  ('b1e00000-1111-1111-1111-111111111111', 'c1e00000-0000-0000-0000-000000000001', 'RRPC Branch A1', 'rrpc-branch-a1'),
  ('b2e00000-2222-2222-2222-222222222222', 'c1e00000-0000-0000-0000-000000000001', 'RRPC Branch A2', 'rrpc-branch-a2');

INSERT INTO auth.users (id, email, raw_app_meta_data, raw_user_meta_data)
VALUES
  ('ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'rrpc-admin-a@test.com',
   '{"company_id": "c1e00000-0000-0000-0000-000000000001", "role": "admin"}',
   '{"full_name": "RRPC Admin A"}'),
  ('ae1e0000-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'rrpc-cashier-a@test.com',
   '{"company_id": "c1e00000-0000-0000-0000-000000000001", "role": "cashier"}',
   '{"full_name": "RRPC Cashier A"}')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.profiles (id, full_name)
VALUES
  ('ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'RRPC Admin A'),
  ('ae1e0000-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'RRPC Cashier A')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.company_users (user_id, company_id, role)
VALUES
  ('ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'c1e00000-0000-0000-0000-000000000001', 'admin'),
  ('ae1e0000-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'c1e00000-0000-0000-0000-000000000001', 'cashier')
ON CONFLICT (user_id, company_id) DO NOTHING;

INSERT INTO public.branch_users (user_id, branch_id, company_id)
VALUES ('ae1e0000-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'b1e00000-1111-1111-1111-111111111111', 'c1e00000-0000-0000-0000-000000000001')
ON CONFLICT (user_id, branch_id) DO NOTHING;

-- Product + variant
INSERT INTO public.products (id, company_id, name, slug, created_by)
VALUES ('dde00000-0000-0000-0000-000000000001', 'c1e00000-0000-0000-0000-000000000001', 'RRPC Product One', 'rrpc-product-one', 'ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa');

INSERT INTO public.product_variants (id, company_id, product_id, name, sku, created_by)
VALUES ('dce00000-0000-0000-0000-000000000001', 'c1e00000-0000-0000-0000-000000000001', 'dde00000-0000-0000-0000-000000000001', 'RRPC Variant One', 'RRPC-VAR-1', 'ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa');

-- Stock lots (baseline remaining_qty asserted later)
INSERT INTO public.stock_lots (id, company_id, branch_id, variant_id, lot_code, received_qty, remaining_qty, created_by, updated_by) VALUES
  ('dae10000-0000-0000-0000-000000000001', 'c1e00000-0000-0000-0000-000000000001', 'b1e00000-1111-1111-1111-111111111111', 'dce00000-0000-0000-0000-000000000001', 'LOT-A', 100, 50, 'ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa'),
  ('dae10000-0000-0000-0000-000000000002', 'c1e00000-0000-0000-0000-000000000001', 'b1e00000-1111-1111-1111-111111111111', 'dce00000-0000-0000-0000-000000000001', 'LOT-B', 100, 40, 'ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa'),
  ('dae20000-0000-0000-0000-000000000003', 'c1e00000-0000-0000-0000-000000000001', 'b2e00000-2222-2222-2222-222222222222', 'dce00000-0000-0000-0000-000000000001', 'LOT-C', 100, 20, 'ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa');

-- Cash sessions: one OPEN in B1; one will be created OPEN in B2 then closed.
INSERT INTO public.cash_sessions (id, company_id, branch_id, cashier_user_id, status, opening_amount, expected_cash_amount, created_by, updated_by) VALUES
  ('0ce10000-0000-0000-0000-000000000091', 'c1e00000-0000-0000-0000-000000000001', 'b1e00000-1111-1111-1111-111111111111', 'ae1e0000-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'open', 100.00, 100.00, 'ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa'),
  ('0ce20000-0000-0000-0000-000000000092', 'c1e00000-0000-0000-0000-000000000001', 'b2e00000-2222-2222-2222-222222222222', 'ae1e0000-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'open',   0.00,   0.00, 'ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa');

-- ----------------------------------------------------------------------------
-- Sales + sale_items + sale_item_batches + payments
-- ----------------------------------------------------------------------------
-- S-CASH (B1, cash-paid): for inventario + cash refund happy path
INSERT INTO public.sales (id, company_id, branch_id, cashier_user_id, cash_session_id, status, subtotal, total, sale_number, created_by, updated_by) VALUES
  ('1ae10000-0000-0000-0000-000000000001', 'c1e00000-0000-0000-0000-000000000001', 'b1e00000-1111-1111-1111-111111111111', 'ae1e0000-bbbb-bbbb-bbbb-bbbbbbbbbbbb', '0ce10000-0000-0000-0000-000000000091', 'active', 50.00, 50.00, 9001, 'ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
INSERT INTO public.sale_items (id, company_id, sale_id, variant_id, quantity, unit_price, line_total, created_by, updated_by) VALUES
  ('1ae10000-0000-0000-0000-0000000000a1', 'c1e00000-0000-0000-0000-000000000001', '1ae10000-0000-0000-0000-000000000001', 'dce00000-0000-0000-0000-000000000001', 5, 10.00, 50.00, 'ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
INSERT INTO public.sale_item_batches (id, company_id, sale_item_id, lot_id, quantity, created_by, updated_by) VALUES
  ('1ae10000-0000-0000-0000-0000000000b1', 'c1e00000-0000-0000-0000-000000000001', '1ae10000-0000-0000-0000-0000000000a1', 'dae10000-0000-0000-0000-000000000001', 5, 'ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
INSERT INTO public.payments (id, company_id, sale_id, payment_method, amount, created_by, updated_by) VALUES
  ('1fe10000-0000-0000-0000-000000000001', 'c1e00000-0000-0000-0000-000000000001', '1ae10000-0000-0000-0000-000000000001', 'cash', 50.00, 'ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa');

-- S-CARD (B1, card-paid): 3 sale_items for merma/garantia/desecho routing (no cash → no refund)
INSERT INTO public.sales (id, company_id, branch_id, cashier_user_id, cash_session_id, status, subtotal, total, sale_number, created_by, updated_by) VALUES
  ('1ae10000-0000-0000-0000-000000000002', 'c1e00000-0000-0000-0000-000000000001', 'b1e00000-1111-1111-1111-111111111111', 'ae1e0000-bbbb-bbbb-bbbb-bbbbbbbbbbbb', '0ce10000-0000-0000-0000-000000000091', 'active', 120.00, 120.00, 9002, 'ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
INSERT INTO public.sale_items (id, company_id, sale_id, variant_id, quantity, unit_price, line_total, created_by, updated_by) VALUES
  ('1ae10000-0000-0000-0000-00000000002a', 'c1e00000-0000-0000-0000-000000000001', '1ae10000-0000-0000-0000-000000000002', 'dce00000-0000-0000-0000-000000000001', 4, 10.00, 40.00, 'ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa'),
  ('1ae10000-0000-0000-0000-00000000002b', 'c1e00000-0000-0000-0000-000000000001', '1ae10000-0000-0000-0000-000000000002', 'dce00000-0000-0000-0000-000000000001', 4, 10.00, 40.00, 'ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa'),
  ('1ae10000-0000-0000-0000-00000000002c', 'c1e00000-0000-0000-0000-000000000001', '1ae10000-0000-0000-0000-000000000002', 'dce00000-0000-0000-0000-000000000001', 4, 10.00, 40.00, 'ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
INSERT INTO public.sale_item_batches (id, company_id, sale_item_id, lot_id, quantity, created_by, updated_by) VALUES
  ('1ae10000-0000-0000-0000-0000000002ba', 'c1e00000-0000-0000-0000-000000000001', '1ae10000-0000-0000-0000-00000000002a', 'dae10000-0000-0000-0000-000000000001', 4, 'ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa'),
  ('1ae10000-0000-0000-0000-0000000002bb', 'c1e00000-0000-0000-0000-000000000001', '1ae10000-0000-0000-0000-00000000002b', 'dae10000-0000-0000-0000-000000000001', 4, 'ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa'),
  ('1ae10000-0000-0000-0000-0000000002bc', 'c1e00000-0000-0000-0000-000000000001', '1ae10000-0000-0000-0000-00000000002c', 'dae10000-0000-0000-0000-000000000002', 4, 'ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
INSERT INTO public.payments (id, company_id, sale_id, payment_method, amount, created_by, updated_by) VALUES
  ('1fe10000-0000-0000-0000-000000000002', 'c1e00000-0000-0000-0000-000000000001', '1ae10000-0000-0000-0000-000000000002', 'card', 120.00, 'ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa');

-- S-OVF (B1, card-paid): qty=5 for overflow test (first 3 ok, second 3 rejected)
INSERT INTO public.sales (id, company_id, branch_id, cashier_user_id, cash_session_id, status, subtotal, total, sale_number, created_by, updated_by) VALUES
  ('1ae10000-0000-0000-0000-000000000003', 'c1e00000-0000-0000-0000-000000000001', 'b1e00000-1111-1111-1111-111111111111', 'ae1e0000-bbbb-bbbb-bbbb-bbbbbbbbbbbb', '0ce10000-0000-0000-0000-000000000091', 'active', 50.00, 50.00, 9003, 'ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
INSERT INTO public.sale_items (id, company_id, sale_id, variant_id, quantity, unit_price, line_total, created_by, updated_by) VALUES
  ('1ae10000-0000-0000-0000-0000000000a3', 'c1e00000-0000-0000-0000-000000000001', '1ae10000-0000-0000-0000-000000000003', 'dce00000-0000-0000-0000-000000000001', 5, 10.00, 50.00, 'ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
INSERT INTO public.sale_item_batches (id, company_id, sale_item_id, lot_id, quantity, created_by, updated_by) VALUES
  ('1ae10000-0000-0000-0000-0000000000b3', 'c1e00000-0000-0000-0000-000000000001', '1ae10000-0000-0000-0000-0000000000a3', 'dae10000-0000-0000-0000-000000000002', 5, 'ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
INSERT INTO public.payments (id, company_id, sale_id, payment_method, amount, created_by, updated_by) VALUES
  ('1fe10000-0000-0000-0000-000000000003', 'c1e00000-0000-0000-0000-000000000001', '1ae10000-0000-0000-0000-000000000003', 'card', 50.00, 'ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa');

-- S-CANC (B1, cash-paid): will be cancelled before the return attempt
INSERT INTO public.sales (id, company_id, branch_id, cashier_user_id, cash_session_id, status, subtotal, total, sale_number, created_by, updated_by) VALUES
  ('1ae10000-0000-0000-0000-000000000004', 'c1e00000-0000-0000-0000-000000000001', 'b1e00000-1111-1111-1111-111111111111', 'ae1e0000-bbbb-bbbb-bbbb-bbbbbbbbbbbb', '0ce10000-0000-0000-0000-000000000091', 'active', 50.00, 50.00, 9004, 'ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
INSERT INTO public.sale_items (id, company_id, sale_id, variant_id, quantity, unit_price, line_total, created_by, updated_by) VALUES
  ('1ae10000-0000-0000-0000-0000000000a4', 'c1e00000-0000-0000-0000-000000000001', '1ae10000-0000-0000-0000-000000000004', 'dce00000-0000-0000-0000-000000000001', 5, 10.00, 50.00, 'ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
INSERT INTO public.sale_item_batches (id, company_id, sale_item_id, lot_id, quantity, created_by, updated_by) VALUES
  ('1ae10000-0000-0000-0000-0000000000b4', 'c1e00000-0000-0000-0000-000000000001', '1ae10000-0000-0000-0000-0000000000a4', 'dae10000-0000-0000-0000-000000000001', 5, 'ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
INSERT INTO public.payments (id, company_id, sale_id, payment_method, amount, created_by, updated_by) VALUES
  ('1fe10000-0000-0000-0000-000000000004', 'c1e00000-0000-0000-0000-000000000001', '1ae10000-0000-0000-0000-000000000004', 'cash', 50.00, 'ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
UPDATE public.sales SET status = 'cancelled', updated_by = 'ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
 WHERE id = '1ae10000-0000-0000-0000-000000000004';

-- S-NOSESS (B2, cash-paid): cash session in B2 will be CLOSED so no open session exists
INSERT INTO public.sales (id, company_id, branch_id, cashier_user_id, cash_session_id, status, subtotal, total, sale_number, created_by, updated_by) VALUES
  ('1ae20000-0000-0000-0000-000000000005', 'c1e00000-0000-0000-0000-000000000001', 'b2e00000-2222-2222-2222-222222222222', 'ae1e0000-bbbb-bbbb-bbbb-bbbbbbbbbbbb', '0ce20000-0000-0000-0000-000000000092', 'active', 50.00, 50.00, 9005, 'ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
INSERT INTO public.sale_items (id, company_id, sale_id, variant_id, quantity, unit_price, line_total, created_by, updated_by) VALUES
  ('1ae20000-0000-0000-0000-0000000000a5', 'c1e00000-0000-0000-0000-000000000001', '1ae20000-0000-0000-0000-000000000005', 'dce00000-0000-0000-0000-000000000001', 5, 10.00, 50.00, 'ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
INSERT INTO public.sale_item_batches (id, company_id, sale_item_id, lot_id, quantity, created_by, updated_by) VALUES
  ('1ae20000-0000-0000-0000-0000000000b5', 'c1e00000-0000-0000-0000-000000000001', '1ae20000-0000-0000-0000-0000000000a5', 'dae20000-0000-0000-0000-000000000003', 5, 'ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
INSERT INTO public.payments (id, company_id, sale_id, payment_method, amount, created_by, updated_by) VALUES
  ('1fe20000-0000-0000-0000-000000000005', 'c1e00000-0000-0000-0000-000000000001', '1ae20000-0000-0000-0000-000000000005', 'cash', 50.00, 'ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
-- Close the B2 session so no OPEN session exists for branch B2 at return time
UPDATE public.cash_sessions SET status = 'closed', closed_at = now(), updated_by = 'ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
 WHERE id = '0ce20000-0000-0000-0000-000000000092';

-- ============================================================================
-- Helper: invoke the RPC once and capture result fields into session settings
-- ============================================================================
-- NOTE: set_config(..., is_local => false) sets the GUC at session level so it
-- remains visible to subsequent current_setting() calls. The whole file is
-- wrapped in BEGIN/ROLLBACK, so these session-level GUCs are discarded on
-- ROLLBACK. Using is_local=true here would scope each GUC to this function
-- call only and discard it on return, making current_setting() fail.
CREATE OR REPLACE FUNCTION _invoke_return(p JSONB, prefix TEXT)
RETURNS VOID AS $$
DECLARE v_res JSONB;
BEGIN
  v_res := public.return_sale_item_transaction(p);
  PERFORM set_config('rrpc.' || prefix || '_success', COALESCE(v_res->>'success',''), false);
  PERFORM set_config('rrpc.' || prefix || '_code',    COALESCE(v_res->>'code',''), false);
  PERFORM set_config('rrpc.' || prefix || '_message',COALESCE(v_res->>'message',''), false);
  PERFORM set_config('rrpc.' || prefix || '_id',     COALESCE(v_res->'data'->>'return_id',''), false);
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- RR2/RR3/RR4: happy path — inventario return + cash refund (S-CASH)
-- qty=2 from SIB1 (lot A), unit_price=10 → subtotal=20; cash_paid=50 → refund=20
-- ============================================================================
SELECT _invoke_return(jsonb_build_object(
  'company_id', 'c1e00000-0000-0000-0000-000000000001',
  'branch_id',  'b1e00000-1111-1111-1111-111111111111',
  'actor_user_id', 'ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'sale_id', '1ae10000-0000-0000-0000-000000000001',
  'type', 'partial',
  'reason', 'customer return to inventory',
  'items', jsonb_build_array(jsonb_build_object(
    'sale_item_id', '1ae10000-0000-0000-0000-0000000000a1',
    'variant_id', 'dce00000-0000-0000-0000-000000000001',
    'qty', 2,
    'destination', 'inventario',
    'unit_price', 10.00,
    'batches', jsonb_build_array(jsonb_build_object(
      'original_batch_id', '1ae10000-0000-0000-0000-0000000000b1',
      'qty', 2
    ))
  ))
), 'r1');

SELECT is(current_setting('rrpc.r1_success'), 'true', 'RR2: valid inventario return returns success=true');
SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.returns WHERE sale_id = '1ae10000-0000-0000-0000-000000000001' $$,
  ARRAY[1::bigint], 'RR2: exactly one return header created for the sale'
);
SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.return_items WHERE return_id = current_setting('rrpc.r1_id')::uuid $$,
  ARRAY[1::bigint], 'RR2: one return_item created'
);
SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.return_item_batches WHERE return_item_id IN (SELECT id FROM public.return_items WHERE return_id = current_setting('rrpc.r1_id')::uuid) $$,
  ARRAY[1::bigint], 'RR2: one return_item_batch created'
);
-- RR3 inventario routing: a single positive sale_return movement via adjust_inventory_stock
SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.stock_movements
      WHERE reference_id = current_setting('rrpc.r1_id')::uuid
        AND movement_type = 'sale_return' AND delta_qty = 2 $$,
  ARRAY[1::bigint], 'RR3 inventario: one sale_return movement (+2) referencing the return'
);
SELECT is(
  (SELECT remaining_qty FROM public.stock_lots WHERE id = 'dae10000-0000-0000-0000-000000000001'),
  52.000::numeric,
  'RR3 inventario: lot A remaining_qty restocked by +2 (50→52) via adjust_inventory_stock'
);
-- RR4 cash refund: one sale_return_refund movement amount=20 against the open session
SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.cash_movements
      WHERE reference_id = current_setting('rrpc.r1_id')::uuid
        AND movement_type = 'sale_return_refund' AND amount = 20.00 $$,
  ARRAY[1::bigint], 'RR4: one sale_return_refund cash movement for the cash-paid portion (20.00)'
);
SELECT is(
  (SELECT expected_cash_amount FROM public.cash_sessions WHERE id = '0ce10000-0000-0000-0000-000000000091'),
  80.00::numeric,
  'RR4: open cash session expected_cash_amount decremented by refund (100→80)'
);
SELECT is(
  (SELECT total_amount FROM public.returns WHERE id = current_setting('rrpc.r1_id')::uuid),
  20.00::numeric,
  'RR2: return total_amount equals sum of item subtotals (20.00)'
);

-- ============================================================================
-- RR3: merma → single negative waste_return movement, NO lot restock, NO cash (S-CARD SIa)
-- ============================================================================
SELECT _invoke_return(jsonb_build_object(
  'company_id', 'c1e00000-0000-0000-0000-000000000001',
  'branch_id',  'b1e00000-1111-1111-1111-111111111111',
  'actor_user_id', 'ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'sale_id', '1ae10000-0000-0000-0000-000000000002',
  'type', 'partial',
  'items', jsonb_build_array(jsonb_build_object(
    'sale_item_id', '1ae10000-0000-0000-0000-00000000002a',
    'variant_id', 'dce00000-0000-0000-0000-000000000001',
    'qty', 3, 'destination', 'merma', 'unit_price', 10.00,
    'batches', jsonb_build_array(jsonb_build_object('original_batch_id', '1ae10000-0000-0000-0000-0000000002ba', 'qty', 3))
  ))
), 'r2');

SELECT is(current_setting('rrpc.r2_success'), 'true', 'RR3 merma: return succeeds');
SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.stock_movements
      WHERE reference_id = current_setting('rrpc.r2_id')::uuid
        AND movement_type = 'waste_return' AND delta_qty = -3 $$,
  ARRAY[1::bigint], 'RR3 merma: exactly one waste_return movement delta_qty=-3'
);
SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.stock_movements
      WHERE reference_id = current_setting('rrpc.r2_id')::uuid
        AND movement_type = 'sale_return' $$,
  ARRAY[0::bigint], 'RR3 merma: no intermediate positive sale_return restock movement'
);
SELECT is(
  (SELECT remaining_qty FROM public.stock_lots WHERE id = 'dae10000-0000-0000-0000-000000000001'),
  52.000::numeric,
  'RR3 merma: lot A remaining_qty unchanged (no lot restock)'
);
-- non-cash sale → no cash movement for this return
SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.cash_movements WHERE reference_id = current_setting('rrpc.r2_id')::uuid $$,
  ARRAY[0::bigint], 'RR4 non-cash (card) sale: no cash_movements row created (cash_paid=0)'
);

-- ============================================================================
-- RR3: garantia → one warranty_return negative movement (S-CARD SIb)
-- ============================================================================
SELECT _invoke_return(jsonb_build_object(
  'company_id', 'c1e00000-0000-0000-0000-000000000001',
  'branch_id',  'b1e00000-1111-1111-1111-111111111111',
  'actor_user_id', 'ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'sale_id', '1ae10000-0000-0000-0000-000000000002',
  'type', 'partial',
  'items', jsonb_build_array(jsonb_build_object(
    'sale_item_id', '1ae10000-0000-0000-0000-00000000002b',
    'variant_id', 'dce00000-0000-0000-0000-000000000001',
    'qty', 2, 'destination', 'garantia', 'unit_price', 10.00,
    'batches', jsonb_build_array(jsonb_build_object('original_batch_id', '1ae10000-0000-0000-0000-0000000002bb', 'qty', 2))
  ))
), 'r3');

SELECT is(current_setting('rrpc.r3_success'), 'true', 'RR3 garantia: return succeeds');
SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.stock_movements
      WHERE reference_id = current_setting('rrpc.r3_id')::uuid
        AND movement_type = 'warranty_return' AND delta_qty = -2 $$,
  ARRAY[1::bigint], 'RR3 garantia: one warranty_return movement delta_qty=-2'
);

-- ============================================================================
-- RR3: desecho → one disposal_return negative movement (S-CARD SIc)
-- ============================================================================
SELECT _invoke_return(jsonb_build_object(
  'company_id', 'c1e00000-0000-0000-0000-000000000001',
  'branch_id',  'b1e00000-1111-1111-1111-111111111111',
  'actor_user_id', 'ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'sale_id', '1ae10000-0000-0000-0000-000000000002',
  'type', 'partial',
  'items', jsonb_build_array(jsonb_build_object(
    'sale_item_id', '1ae10000-0000-0000-0000-00000000002c',
    'variant_id', 'dce00000-0000-0000-0000-000000000001',
    'qty', 1, 'destination', 'desecho', 'unit_price', 10.00,
    'batches', jsonb_build_array(jsonb_build_object('original_batch_id', '1ae10000-0000-0000-0000-0000000002bc', 'qty', 1))
  ))
), 'r4');

SELECT is(current_setting('rrpc.r4_success'), 'true', 'RR3 desecho: return succeeds');
SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.stock_movements
      WHERE reference_id = current_setting('rrpc.r4_id')::uuid
        AND movement_type = 'disposal_return' AND delta_qty = -1 $$,
  ARRAY[1::bigint], 'RR3 desecho: one disposal_return movement delta_qty=-1'
);

-- ============================================================================
-- RR2: qty overflow — first return qty=3 (ok), second return qty=3 rejected (remaining=2)
-- (S-OVF: sale_item qty=5)
-- ============================================================================
SELECT _invoke_return(jsonb_build_object(
  'company_id', 'c1e00000-0000-0000-0000-000000000001',
  'branch_id',  'b1e00000-1111-1111-1111-111111111111',
  'actor_user_id', 'ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'sale_id', '1ae10000-0000-0000-0000-000000000003',
  'type', 'partial',
  'items', jsonb_build_array(jsonb_build_object(
    'sale_item_id', '1ae10000-0000-0000-0000-0000000000a3',
    'variant_id', 'dce00000-0000-0000-0000-000000000001',
    'qty', 3, 'destination', 'inventario', 'unit_price', 10.00,
    'batches', jsonb_build_array(jsonb_build_object('original_batch_id', '1ae10000-0000-0000-0000-0000000000b3', 'qty', 3))
  ))
), 'r5');
SELECT is(current_setting('rrpc.r5_success'), 'true', 'RR2 overflow: first return qty=3 succeeds');

SELECT _invoke_return(jsonb_build_object(
  'company_id', 'c1e00000-0000-0000-0000-000000000001',
  'branch_id',  'b1e00000-1111-1111-1111-111111111111',
  'actor_user_id', 'ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'sale_id', '1ae10000-0000-0000-0000-000000000003',
  'type', 'partial',
  'items', jsonb_build_array(jsonb_build_object(
    'sale_item_id', '1ae10000-0000-0000-0000-0000000000a3',
    'variant_id', 'dce00000-0000-0000-0000-000000000001',
    'qty', 3, 'destination', 'inventario', 'unit_price', 10.00,
    'batches', jsonb_build_array(jsonb_build_object('original_batch_id', '1ae10000-0000-0000-0000-0000000000b3', 'qty', 3))
  ))
), 'r6');
SELECT is(current_setting('rrpc.r6_success'), 'false', 'RR2 overflow: second return qty=3 rejected (returnable remaining=2)');
SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.returns WHERE sale_id = '1ae10000-0000-0000-0000-000000000003' $$,
  ARRAY[1::bigint], 'RR2 overflow: no second return header written (only the first)'
);

-- ============================================================================
-- RR2: unknown original_batch_id for the sale_item → rejected, no partial state
-- Use S-CARD SIa but pass SIb's batch (belongs to a different sale_item)
-- ============================================================================
SELECT _invoke_return(jsonb_build_object(
  'company_id', 'c1e00000-0000-0000-0000-000000000001',
  'branch_id',  'b1e00000-1111-1111-1111-111111111111',
  'actor_user_id', 'ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'sale_id', '1ae10000-0000-0000-0000-000000000002',
  'type', 'partial',
  'items', jsonb_build_array(jsonb_build_object(
    'sale_item_id', '1ae10000-0000-0000-0000-00000000002a',
    'variant_id', 'dce00000-0000-0000-0000-000000000001',
    'qty', 1, 'destination', 'inventario', 'unit_price', 10.00,
    'batches', jsonb_build_array(jsonb_build_object('original_batch_id', '1ae10000-0000-0000-0000-0000000002bb', 'qty', 1))
  ))
), 'r7');
SELECT is(current_setting('rrpc.r7_success'), 'false', 'RR2: unknown original_batch_id for sale_item is rejected');
SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.returns WHERE id::text = current_setting('rrpc.r7_id') $$,
  ARRAY[0::bigint], 'RR2: rejected return wrote no header (no partial state)'
);

-- ============================================================================
-- RR2: cancelled sale → rejected, no rows (S-CANC)
-- ============================================================================
SELECT _invoke_return(jsonb_build_object(
  'company_id', 'c1e00000-0000-0000-0000-000000000001',
  'branch_id',  'b1e00000-1111-1111-1111-111111111111',
  'actor_user_id', 'ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'sale_id', '1ae10000-0000-0000-0000-000000000004',
  'type', 'partial',
  'items', jsonb_build_array(jsonb_build_object(
    'sale_item_id', '1ae10000-0000-0000-0000-0000000000a4',
    'variant_id', 'dce00000-0000-0000-0000-000000000001',
    'qty', 2, 'destination', 'inventario', 'unit_price', 10.00,
    'batches', jsonb_build_array(jsonb_build_object('original_batch_id', '1ae10000-0000-0000-0000-0000000000b4', 'qty', 2))
  ))
), 'r8');
SELECT is(current_setting('rrpc.r8_success'), 'false', 'RR2: cancelled sale return is rejected');
SELECT is(current_setting('rrpc.r8_message'), 'Cannot return a cancelled sale', 'RR2: cancelled sale returns the expected message');
SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.returns WHERE sale_id = '1ae10000-0000-0000-0000-000000000004' $$,
  ARRAY[0::bigint], 'RR2: cancelled sale rejection wrote no return rows'
);

-- ============================================================================
-- RR4: cash refund required but no open cash session → rejected before writes (S-NOSESS, B2)
-- ============================================================================
SELECT _invoke_return(jsonb_build_object(
  'company_id', 'c1e00000-0000-0000-0000-000000000001',
  'branch_id',  'b2e00000-2222-2222-2222-222222222222',
  'actor_user_id', 'ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'sale_id', '1ae20000-0000-0000-0000-000000000005',
  'type', 'partial',
  'items', jsonb_build_array(jsonb_build_object(
    'sale_item_id', '1ae20000-0000-0000-0000-0000000000a5',
    'variant_id', 'dce00000-0000-0000-0000-000000000001',
    'qty', 2, 'destination', 'inventario', 'unit_price', 10.00,
    'batches', jsonb_build_array(jsonb_build_object('original_batch_id', '1ae20000-0000-0000-0000-0000000000b5', 'qty', 2))
  ))
), 'r9');
SELECT is(current_setting('rrpc.r9_success'), 'false', 'RR4: cash sale with no open session is rejected');
SELECT is(current_setting('rrpc.r9_message'), 'No open cash session for this branch; cannot refund cash', 'RR4: no-open-session returns the expected message');
SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.returns WHERE sale_id = '1ae20000-0000-0000-0000-000000000005' $$,
  ARRAY[0::bigint], 'RR4: no-open-session rejection wrote no return rows (validated before writes)'
);

-- ============================================================================
-- RR5: non-admin caller → FORBIDDEN (cashier on S-OVF)
-- ============================================================================
SELECT _invoke_return(jsonb_build_object(
  'company_id', 'c1e00000-0000-0000-0000-000000000001',
  'branch_id',  'b1e00000-1111-1111-1111-111111111111',
  'actor_user_id', 'ae1e0000-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
  'sale_id', '1ae10000-0000-0000-0000-000000000003',
  'type', 'partial',
  'items', jsonb_build_array(jsonb_build_object(
    'sale_item_id', '1ae10000-0000-0000-0000-0000000000a3',
    'variant_id', 'dce00000-0000-0000-0000-000000000001',
    'qty', 1, 'destination', 'inventario', 'unit_price', 10.00,
    'batches', jsonb_build_array(jsonb_build_object('original_batch_id', '1ae10000-0000-0000-0000-0000000000b3', 'qty', 1))
  ))
), 'r10');
SELECT is(current_setting('rrpc.r10_success'), 'false', 'RR5: non-admin caller is rejected');
SELECT is(current_setting('rrpc.r10_code'), 'FORBIDDEN', 'RR5: non-admin caller receives FORBIDDEN');

-- ============================================================================
-- Cleanup
-- ============================================================================
SELECT * FROM finish();
ROLLBACK;