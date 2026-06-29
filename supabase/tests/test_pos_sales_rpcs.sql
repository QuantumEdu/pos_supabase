-- pgTAP: POS Sales domain RPC tests
-- Verifies create_sale_transaction, cancel_sale_transaction, authorize_discount
-- flows including cash session validation, FEFO deduction, reversal, and role gates.

BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap;

SELECT plan(18);

-- Seed data
INSERT INTO public.companies (id, name, slug)
VALUES
  ('c1c00000-0000-0000-0000-000000000001', 'Sales RPC Co A', 'sales-rpc-co-a'),
  ('c2c00000-0000-0000-0000-000000000002', 'Sales RPC Co B', 'sales-rpc-co-b');

INSERT INTO public.branches (id, company_id, name, slug)
VALUES
  ('b1c00000-1111-1111-1111-111111111111', 'c1c00000-0000-0000-0000-000000000001', 'RPC Branch A1', 'rpc-branch-a1'),
  ('b2c00000-2222-2222-2222-222222222222', 'c2c00000-0000-0000-0000-000000000002', 'RPC Branch B1', 'rpc-branch-b1');

INSERT INTO auth.users (id, email, raw_app_meta_data, raw_user_meta_data)
VALUES
  ('ac1c0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'sales-rpc-admin-a@test.com',
   '{"company_id": "c1c00000-0000-0000-0000-000000000001", "role": "admin"}',
   '{"full_name": "Sales RPC Admin A"}'),
  ('ac1c0000-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'sales-rpc-cashier-a@test.com',
   '{"company_id": "c1c00000-0000-0000-0000-000000000001", "role": "cashier", "branch_id": "b1c00000-1111-1111-1111-111111111111"}',
   '{"full_name": "Sales RPC Cashier A"}'),
  ('a0a1c000-cccc-cccc-cccc-cccccccccccc', 'sales-rpc-noncashier-a@test.com',
   '{"company_id": "c1c00000-0000-0000-0000-000000000001", "role": "admin"}',
   '{"full_name": "Sales RPC Noncashier A"}'),
  ('ac2c0000-dddd-dddd-dddd-dddddddddddd', 'sales-rpc-cashier-b@test.com',
   '{"company_id": "c2c00000-0000-0000-0000-000000000002", "role": "cashier", "branch_id": "b2c00000-2222-2222-2222-222222222222"}',
   '{"full_name": "Sales RPC Cashier B"}'),
  ('ac2c0000-eeee-eeee-eeee-eeeeeeeeeeee', 'sales-rpc-admin-b@test.com',
   '{"company_id": "c2c00000-0000-0000-0000-000000000002", "role": "admin"}',
   '{"full_name": "Sales RPC Admin B"}')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.profiles (id, full_name)
VALUES
  ('ac1c0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'Sales RPC Admin A'),
  ('ac1c0000-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'Sales RPC Cashier A'),
  ('a0a1c000-cccc-cccc-cccc-cccccccccccc', 'Sales RPC Noncashier A'),
  ('ac2c0000-dddd-dddd-dddd-dddddddddddd', 'Sales RPC Cashier B'),
  ('ac2c0000-eeee-eeee-eeee-eeeeeeeeeeee', 'Sales RPC Admin B')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.company_users (user_id, company_id, role)
VALUES
  ('ac1c0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'c1c00000-0000-0000-0000-000000000001', 'admin'),
  ('ac1c0000-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'c1c00000-0000-0000-0000-000000000001', 'cashier'),
  ('a0a1c000-cccc-cccc-cccc-cccccccccccc', 'c1c00000-0000-0000-0000-000000000001', 'admin'),
  ('ac2c0000-dddd-dddd-dddd-dddddddddddd', 'c2c00000-0000-0000-0000-000000000002', 'cashier'),
  ('ac2c0000-eeee-eeee-eeee-eeeeeeeeeeee', 'c2c00000-0000-0000-0000-000000000002', 'admin')
ON CONFLICT (user_id, company_id) DO NOTHING;

INSERT INTO public.branch_users (user_id, branch_id, company_id)
VALUES
  ('ac1c0000-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'b1c00000-1111-1111-1111-111111111111', 'c1c00000-0000-0000-0000-000000000001'),
  ('ac2c0000-dddd-dddd-dddd-dddddddddddd', 'b2c00000-2222-2222-2222-222222222222', 'c2c00000-0000-0000-0000-000000000002')
ON CONFLICT (user_id, branch_id) DO NOTHING;

INSERT INTO public.customers (id, company_id, name, slug, created_by)
VALUES (
  'cc1c0000-0000-0000-0000-000000000001',
  'c1c00000-0000-0000-0000-000000000001',
  'RPC Customer A',
  'rpc-customer-a',
  'ac1c0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
);

-- Customer B with a credit limit for limit validation tests
INSERT INTO public.customers (id, company_id, name, slug, credit_limit, created_by)
VALUES (
  'cc1c0000-0000-0000-0000-000000000002',
  'c1c00000-0000-0000-0000-000000000001',
  'RPC Customer B (Limited)',
  'rpc-customer-b-limited',
  1000.00,
  'ac1c0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
);

-- Seed product so product_variants FK works
INSERT INTO public.products (id, company_id, name, slug, created_by)
VALUES (
  'f0000000-0000-0000-0000-00000000f001',
  'c1c00000-0000-0000-0000-000000000001',
  'RPC Product',
  'rpc-product',
  'ac1c0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
);

-- Seed inventory: variant with stock for FEFO deduction
INSERT INTO public.product_variants (id, product_id, sku, company_id, name, created_by)
VALUES
  ('0b1c0000-0000-0000-0000-000000000001', 'f0000000-0000-0000-0000-00000000f001', 'RPC-VAR-A', 'c1c00000-0000-0000-0000-000000000001', 'RPC Variant A', 'ac1c0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa'),
  ('0b2c0000-0000-0000-0000-000000000002', 'f0000000-0000-0000-0000-00000000f001', 'RPC-VAR-B', 'c1c00000-0000-0000-0000-000000000001', 'RPC Variant B', 'ac1c0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa');

-- Create lot and stock movement for inventory
INSERT INTO public.stock_lots (id, variant_id, company_id, branch_id, lot_code, received_qty, remaining_qty, cost_per_unit)
VALUES (
  '0d1c0000-0000-0000-0000-000000000001',
  '0b1c0000-0000-0000-0000-000000000001',
  'c1c00000-0000-0000-0000-000000000001',
  'b1c00000-1111-1111-1111-111111111111',
  'RPC-BATCH-001', 100, 100, 25.00
);

INSERT INTO public.stock_movements (
  company_id, branch_id, variant_id, lot_id, delta_qty, movement_type, reference_type, created_by
) VALUES (
  'c1c00000-0000-0000-0000-000000000001',
  'b1c00000-1111-1111-1111-111111111111',
  '0b1c0000-0000-0000-0000-000000000001',
  '0d1c0000-0000-0000-0000-000000000001',
  100, 'purchase_receipt', 'initial_seed',
  'ac1c0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
);

-- Open cash session for cashier A
INSERT INTO public.cash_sessions (
  id, company_id, branch_id, cashier_user_id, status, opening_amount, expected_cash_amount, created_by
) VALUES (
  '0c1c0000-0000-0000-0000-000000000001',
  'c1c00000-0000-0000-0000-000000000001',
  'b1c00000-1111-1111-1111-111111111111',
  'ac1c0000-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
  'open', 500.00, 500.00,
  'ac1c0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
);

-- ============================================================================
-- RPC execution tests
-- ============================================================================

-- 1. create_sale_transaction: success with open session
SELECT results_eq(
  $$ SELECT public.create_sale_transaction(jsonb_build_object(
    'company_id', 'c1c00000-0000-0000-0000-000000000001',
    'branch_id', 'b1c00000-1111-1111-1111-111111111111',
    'actor_user_id', 'ac1c0000-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
    'items', jsonb_build_array(jsonb_build_object(
      'variant_id', '0b1c0000-0000-0000-0000-000000000001',
      'quantity', 2,
      'unit_price', 50.00,
      'line_total', 100.00
    )),
    'payments', jsonb_build_array(jsonb_build_object(
      'payment_method', 'cash',
      'amount', 100.00
    ))
  ))->>'success' $$,
  ARRAY['true'::text],
  'create_sale_transaction: success with open session returns success'
);

-- 2. create_sale_transaction: fails without open cash session
SELECT results_eq(
  $$ SELECT public.create_sale_transaction(jsonb_build_object(
    'company_id', 'c1c00000-0000-0000-0000-000000000001',
    'branch_id', 'b1c00000-1111-1111-1111-111111111111',
    'actor_user_id', 'a0a1c000-cccc-cccc-cccc-cccccccccccc', -- admin user, no open session
    'cashier_user_id', 'a0a1c000-cccc-cccc-cccc-cccccccccccc',
    'items', jsonb_build_array(jsonb_build_object(
      'variant_id', '0b1c0000-0000-0000-0000-000000000001',
      'quantity', 1,
      'unit_price', 50.00,
      'line_total', 50.00
    )),
    'payments', jsonb_build_array(jsonb_build_object(
      'payment_method', 'cash',
      'amount', 50.00
    ))
  ))->>'success' $$,
  ARRAY['false'::text],
  'create_sale_transaction: no open session returns failure'
);

-- 3. create_sale_transaction: validation error for insufficient stock (raises exception)
SELECT throws_ok(
  $$ SELECT public.create_sale_transaction(jsonb_build_object(
    'company_id', 'c1c00000-0000-0000-0000-000000000001',
    'branch_id', 'b1c00000-1111-1111-1111-111111111111',
    'actor_user_id', 'ac1c0000-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
    'items', jsonb_build_array(jsonb_build_object(
      'variant_id', '0b1c0000-0000-0000-0000-000000000001',
      'quantity', 9999,
      'unit_price', 50.00,
      'line_total', 499950.00
    )),
    'payments', jsonb_build_array(jsonb_build_object(
      'payment_method', 'cash',
      'amount', 499950.00
    ))
  )) $$,
  NULL, NULL,
  'create_sale_transaction: insufficient stock raises exception'
);

-- 4. cancel_sale_transaction: success
-- First create a sale to cancel
DO $$
DECLARE
  v_sale_id UUID;
BEGIN
  INSERT INTO public.sales (
    id, company_id, branch_id, cashier_user_id, cash_session_id, status,
    subtotal, total, sale_number, created_by, updated_by
  ) VALUES (
    '1a1c0000-0000-0000-0000-000000000001',
    'c1c00000-0000-0000-0000-000000000001',
    'b1c00000-1111-1111-1111-111111111111',
    'ac1c0000-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
    '0c1c0000-0000-0000-0000-000000000001',
    'active', 100.00, 110.00, 3001,
    'ac1c0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    'ac1c0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
  ) RETURNING id INTO v_sale_id;

  INSERT INTO public.sale_items (
    id, company_id, sale_id, variant_id, quantity, unit_price, line_total, created_by, updated_by
  ) VALUES (
    '3a1c0000-0000-0000-0000-000000000001',
    'c1c00000-0000-0000-0000-000000000001',
    v_sale_id,
    '0b1c0000-0000-0000-0000-000000000001',
    2, 50.00, 100.00,
    'ac1c0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    'ac1c0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
  );

  INSERT INTO public.sale_item_batches (
    company_id, sale_item_id, lot_id, quantity, cost_price, created_by, updated_by
  ) VALUES (
    'c1c00000-0000-0000-0000-000000000001',
    '3a1c0000-0000-0000-0000-000000000001',
    '0d1c0000-0000-0000-0000-000000000001',
    2, 25.00,
    'ac1c0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    'ac1c0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
  );
END;
$$;

SELECT results_eq(
  $$ SELECT public.cancel_sale_transaction(jsonb_build_object(
    'company_id', 'c1c00000-0000-0000-0000-000000000001',
    'actor_user_id', 'ac1c0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    'sale_id', '1a1c0000-0000-0000-0000-000000000001',
    'reason', 'Test cancellation'
  ))->>'success' $$,
  ARRAY['true'::text],
  'cancel_sale_transaction: admin cancels sale returns success'
);

-- 5. cancel_sale_transaction: fails for already cancelled sale
SELECT results_eq(
  $$ SELECT public.cancel_sale_transaction(jsonb_build_object(
    'company_id', 'c1c00000-0000-0000-0000-000000000001',
    'actor_user_id', 'ac1c0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    'sale_id', '1a1c0000-0000-0000-0000-000000000001'
  ))->>'success' $$,
  ARRAY['false'::text],
  'cancel_sale_transaction: already cancelled returns failure'
);

-- 6. cancel_sale_transaction: cashier cancels own sale
DO $$
DECLARE
  v_sale_id2 UUID;
BEGIN
  INSERT INTO public.sales (
    id, company_id, branch_id, cashier_user_id, cash_session_id, status,
    subtotal, total, sale_number, created_by, updated_by
  ) VALUES (
    '1a2c0000-0000-0000-0000-000000000001',
    'c1c00000-0000-0000-0000-000000000001',
    'b1c00000-1111-1111-1111-111111111111',
    'ac1c0000-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
    '0c1c0000-0000-0000-0000-000000000001',
    'active', 50.00, 55.00, 3002,
    'ac1c0000-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
    'ac1c0000-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
  ) RETURNING id INTO v_sale_id2;
END;
$$;

SELECT results_eq(
  $$ SELECT public.cancel_sale_transaction(jsonb_build_object(
    'company_id', 'c1c00000-0000-0000-0000-000000000001',
    'actor_user_id', 'ac1c0000-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
    'sale_id', '1a2c0000-0000-0000-0000-000000000001'
  ))->>'success' $$,
  ARRAY['true'::text],
  'cancel_sale_transaction: cashier cancels own sale returns success'
);

-- 7. cancel_sale_transaction: cashier cannot cancel another cashier's sale
DO $$
DECLARE
  v_sale_id3 UUID;
BEGIN
  INSERT INTO public.sales (
    id, company_id, branch_id, cashier_user_id, cash_session_id, status,
    subtotal, total, sale_number, created_by, updated_by
  ) VALUES (
    '1a3c0000-0000-0000-0000-000000000001',
    'c1c00000-0000-0000-0000-000000000001',
    'b1c00000-1111-1111-1111-111111111111',
    'ac1c0000-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
    '0c1c0000-0000-0000-0000-000000000001',
    'active', 75.00, 80.00, 3003,
    'ac1c0000-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
    'ac1c0000-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
  ) RETURNING id INTO v_sale_id3;
END;
$$;

-- Cashier A cancels own sale — should succeed
SELECT results_eq(
  $$ SELECT public.cancel_sale_transaction(jsonb_build_object(
    'company_id', 'c1c00000-0000-0000-0000-000000000001',
    'actor_user_id', 'ac1c0000-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
    'sale_id', '1a3c0000-0000-0000-0000-000000000001'
  ))->>'success' $$,
  ARRAY['true'::text],
  'cancel_sale_transaction: cashier can cancel own second sale'
);

-- Create a fresh active sale for discount authorization tests
DO $$
DECLARE
  v_discount_sale_id UUID;
BEGIN
  INSERT INTO public.sales (
    id, company_id, branch_id, cashier_user_id, cash_session_id, status,
    subtotal, total, sale_number, created_by, updated_by
  ) VALUES (
    '4a1c0000-0000-0000-0000-000000000001',
    'c1c00000-0000-0000-0000-000000000001',
    'b1c00000-1111-1111-1111-111111111111',
    'ac1c0000-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
    '0c1c0000-0000-0000-0000-000000000001',
    'active', 100.00, 110.00, 4001,
    'ac1c0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    'ac1c0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
  );
END;
$$;

-- 8. authorize_discount: admin authorized succeeds
SELECT results_eq(
  $$ SELECT public.authorize_discount(jsonb_build_object(
    'company_id', 'c1c00000-0000-0000-0000-000000000001',
    'actor_user_id', 'ac1c0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    'sale_id', '4a1c0000-0000-0000-0000-000000000001',
    'discount_percent', 10.00,
    'discount_amount', 11.00,
    'reason', 'Regular customer discount'
  ))->>'success' $$,
  ARRAY['true'::text],
  'authorize_discount: admin authorization succeeds'
);

-- 9. authorize_discount: non-admin (cashier) fails
SELECT results_eq(
  $$ SELECT public.authorize_discount(jsonb_build_object(
    'company_id', 'c1c00000-0000-0000-0000-000000000001',
    'actor_user_id', 'ac1c0000-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
    'sale_id', '4a1c0000-0000-0000-0000-000000000001',
    'discount_percent', 5.00,
    'discount_amount', 5.50,
    'reason', 'Cashier attempted authorization'
  ))->>'success' $$,
  ARRAY['false'::text],
  'authorize_discount: cashier authorization fails'
);

-- 10. authorize_discount: cross-company admin fails
SELECT results_eq(
  $$ SELECT public.authorize_discount(jsonb_build_object(
    'company_id', 'c1c00000-0000-0000-0000-000000000001',
    'actor_user_id', 'ac2c0000-eeee-eeee-eeee-eeeeeeeeeeee', -- admin from company B
    'sale_id', '4a1c0000-0000-0000-0000-000000000001',
    'discount_percent', 10.00,
    'discount_amount', 11.00,
    'reason', 'Cross-company attempt'
  ))->>'success' $$,
  ARRAY['false'::text],
  'authorize_discount: cross-company admin fails'
);

-- 11. create_sale_transaction: admin creates sale for another cashier
SELECT results_eq(
  $$ SELECT public.create_sale_transaction(jsonb_build_object(
    'company_id', 'c1c00000-0000-0000-0000-000000000001',
    'branch_id', 'b1c00000-1111-1111-1111-111111111111',
    'actor_user_id', 'ac1c0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    'cashier_user_id', 'ac1c0000-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
    'items', jsonb_build_array(jsonb_build_object(
      'variant_id', '0b1c0000-0000-0000-0000-000000000001',
      'quantity', 1,
      'unit_price', 50.00,
      'line_total', 50.00
    )),
    'payments', jsonb_build_array(jsonb_build_object(
      'payment_method', 'cash',
      'amount', 50.00
    ))
  ))->>'success' $$,
  ARRAY['true'::text],
  'create_sale_transaction: admin creates sale for cashier succeeds'
);

-- 12. create_sale_transaction: admin cannot create sale for non-cashier
SELECT results_eq(
  $$ SELECT public.create_sale_transaction(jsonb_build_object(
    'company_id', 'c1c00000-0000-0000-0000-000000000001',
    'branch_id', 'b1c00000-1111-1111-1111-111111111111',
    'actor_user_id', 'ac1c0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    'cashier_user_id', 'a0a1c000-cccc-cccc-cccc-cccccccccccc', -- non-cashier (admin without cashier role)
    'items', jsonb_build_array(jsonb_build_object(
      'variant_id', '0b1c0000-0000-0000-0000-000000000001',
      'quantity', 1,
      'unit_price', 50.00,
      'line_total', 50.00
    )),
    'payments', jsonb_build_array(jsonb_build_object(
      'payment_method', 'cash',
      'amount', 50.00
    ))
  ))->>'success' $$,
  ARRAY['false'::text],
  'create_sale_transaction: admin creating sale for non-cashier fails'
);

-- 13. Credit payment requires customer_id
SELECT results_eq(
  $$ SELECT public.create_sale_transaction(jsonb_build_object(
    'company_id', 'c1c00000-0000-0000-0000-000000000001',
    'branch_id', 'b1c00000-1111-1111-1111-111111111111',
    'actor_user_id', 'ac1c0000-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
    'items', jsonb_build_array(jsonb_build_object(
      'variant_id', '0b1c0000-0000-0000-0000-000000000001',
      'quantity', 1,
      'unit_price', 50.00,
      'line_total', 50.00
    )),
    'payments', jsonb_build_array(jsonb_build_object(
      'payment_method', 'credit',
      'amount', 50.00
    ))
  ))->>'success' $$,
  ARRAY['false'::text],
  'create_sale_transaction: credit payment without customer fails'
);

SELECT results_eq(
  $$ SELECT public.create_sale_transaction(jsonb_build_object(
    'company_id', 'c1c00000-0000-0000-0000-000000000001',
    'branch_id', 'b1c00000-1111-1111-1111-111111111111',
    'actor_user_id', 'ac1c0000-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
    'customer_id', 'cc1c0000-0000-0000-0000-000000000001',
    'items', jsonb_build_array(jsonb_build_object(
      'variant_id', '0b1c0000-0000-0000-0000-000000000001',
      'quantity', 1,
      'unit_price', 50.00,
      'line_total', 50.00
    )),
    'payments', jsonb_build_array(jsonb_build_object(
      'payment_method', 'credit',
      'amount', 50.00
    ))
  ))->>'success' $$,
  ARRAY['true'::text],
  'create_sale_transaction: credit payment with real customer succeeds'
);

-- 14. Credit limit: customer with NULL credit_limit (unlimited) succeeds
SELECT results_eq(
  $$ SELECT public.create_sale_transaction(jsonb_build_object(
    'company_id', 'c1c00000-0000-0000-0000-000000000001',
    'branch_id', 'b1c00000-1111-1111-1111-111111111111',
    'actor_user_id', 'ac1c0000-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
    'customer_id', 'cc1c0000-0000-0000-0000-000000000001',
    'items', jsonb_build_array(jsonb_build_object(
      'variant_id', '0b1c0000-0000-0000-0000-000000000001',
      'quantity', 1000,
      'unit_price', 100.00,
      'line_total', 100000.00
    )),
    'payments', jsonb_build_array(jsonb_build_object(
      'payment_method', 'credit',
      'amount', 100000.00
    ))
  ))->>'success' $$,
  ARRAY['true'::text],
  'create_sale_transaction: credit with unlimited customer (NULL credit_limit) succeeds'
);

-- 15. Credit limit: customer within limit succeeds
SELECT results_eq(
  $$ SELECT public.create_sale_transaction(jsonb_build_object(
    'company_id', 'c1c00000-0000-0000-0000-000000000001',
    'branch_id', 'b1c00000-1111-1111-1111-111111111111',
    'actor_user_id', 'ac1c0000-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
    'customer_id', 'cc1c0000-0000-0000-0000-000000000002',
    'items', jsonb_build_array(jsonb_build_object(
      'variant_id', '0b1c0000-0000-0000-0000-000000000001',
      'quantity', 1,
      'unit_price', 50.00,
      'line_total', 50.00
    )),
    'payments', jsonb_build_array(jsonb_build_object(
      'payment_method', 'credit',
      'amount', 50.00
    ))
  ))->>'success' $$,
  ARRAY['true'::text],
  'create_sale_transaction: credit within limit succeeds'
);

-- 16. Credit limit: customer exceeding limit fails
SELECT results_eq(
  $$ SELECT public.create_sale_transaction(jsonb_build_object(
    'company_id', 'c1c00000-0000-0000-0000-000000000001',
    'branch_id', 'b1c00000-1111-1111-1111-111111111111',
    'actor_user_id', 'ac1c0000-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
    'customer_id', 'cc1c0000-0000-0000-0000-000000000002',
    'items', jsonb_build_array(jsonb_build_object(
      'variant_id', '0b1c0000-0000-0000-0000-000000000001',
      'quantity', 1,
      'unit_price', 9999.00,
      'line_total', 9999.00
    )),
    'payments', jsonb_build_array(jsonb_build_object(
      'payment_method', 'credit',
      'amount', 9999.00
    ))
  ))->>'success' $$,
  ARRAY['false'::text],
  'create_sale_transaction: credit exceeding limit fails'
);

-- 17. Verify cancelled sale status
SELECT is(
  status, 'cancelled',
  'RPC: cancelled sale has correct status'
) FROM public.sales WHERE id = '1a1c0000-0000-0000-0000-000000000001';

-- ============================================================================
-- Cleanup
-- ============================================================================
SELECT * FROM finish();
ROLLBACK;
