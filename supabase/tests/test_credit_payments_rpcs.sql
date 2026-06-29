-- pgTAP: Credit Payments domain RPC + trigger tests
-- Verifies the seed trigger (RCP2), cancellation trigger (RCP3), and the
-- register_customer_payment_transaction RPC (RCP4/RCP5) happy + edge paths.
-- source: RCP2, RCP3, RCP4, RCP5, design D2/D3/D4
--
-- NOTE on concurrency: true cross-session FOR UPDATE serialization cannot be
-- exercised from a single pgTAP session. Instead, two sequential abonos toward
-- the same balance are applied and the exact sum is asserted — this exercises
-- the same locked read-modify-write code path the RPC uses under FOR UPDATE.

BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap;

SELECT plan(22);

-- ============================================================================
-- Seed data
-- Companies, branch, users, a cash session, customers, and sales.
-- sales.customer_id and customer_balances.customer_id now both resolve to
-- public.customers(company_id, id), so the fixture uses a normal customer row.
-- ============================================================================
INSERT INTO public.companies (id, name, slug)
VALUES ('c1d00000-0000-0000-0000-000000000001', 'Credit RPC Co A', 'credit-rpc-co-a');

INSERT INTO public.branches (id, company_id, name, slug)
VALUES ('b1d00000-1111-1111-1111-111111111111', 'c1d00000-0000-0000-0000-000000000001', 'CRPC Branch A1', 'crpc-branch-a1');

INSERT INTO auth.users (id, email, raw_app_meta_data, raw_user_meta_data)
VALUES
  ('ad1d0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'crpc-admin-a@test.com',
   '{"company_id": "c1d00000-0000-0000-0000-000000000001", "role": "admin"}',
   '{"full_name": "CRPC Admin A"}'),
  ('ad1d0000-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'crpc-cashier-a@test.com',
   '{"company_id": "c1d00000-0000-0000-0000-000000000001", "role": "cashier"}',
   '{"full_name": "CRPC Cashier A"}'),
  ('0cd10000-0000-0000-0000-000000000001', 'crpc-customer-one@test.com',
   '{"company_id": "c1d00000-0000-0000-0000-000000000001", "role": "cashier"}',
   '{"full_name": "CRPC Customer One"}')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.profiles (id, full_name)
VALUES
  ('ad1d0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'CRPC Admin A'),
  ('ad1d0000-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'CRPC Cashier A'),
  ('0cd10000-0000-0000-0000-000000000001', 'CRPC Customer One')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.company_users (user_id, company_id, role)
VALUES
  ('ad1d0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'c1d00000-0000-0000-0000-000000000001', 'admin'),
  ('ad1d0000-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'c1d00000-0000-0000-0000-000000000001', 'cashier')
ON CONFLICT (user_id, company_id) DO NOTHING;

INSERT INTO public.branch_users (user_id, branch_id, company_id)
VALUES ('ad1d0000-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'b1d00000-1111-1111-1111-111111111111', 'c1d00000-0000-0000-0000-000000000001')
ON CONFLICT (user_id, branch_id) DO NOTHING;

-- Normal customer referenced by the credit-sale fixture
INSERT INTO public.customers (id, company_id, name, slug, created_by)
VALUES (
  '0cd10000-0000-0000-0000-000000000001',
  'c1d00000-0000-0000-0000-000000000001',
  'CRPC Customer One', 'crpc-customer-one',
  'ad1d0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
);

-- Cash session for the cashier
INSERT INTO public.cash_sessions (
  id, company_id, branch_id, cashier_user_id, status, opening_amount, expected_cash_amount, created_by, updated_by
) VALUES (
  '0cd10000-0000-0000-0000-000000000091',
  'c1d00000-0000-0000-0000-000000000001',
  'b1d00000-1111-1111-1111-111111111111',
  'ad1d0000-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
  'open', 500.00, 500.00,
  'ad1d0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'ad1d0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
);

-- Sales used across scenarios (each with customer_id = the normal customer)
INSERT INTO public.sales (
  id, company_id, branch_id, cashier_user_id, customer_id, cash_session_id, status,
  subtotal, total, sale_number, created_by, updated_by
) VALUES
  ('1ad10000-0000-0000-0000-000000000001', 'c1d00000-0000-0000-0000-000000000001', 'b1d00000-1111-1111-1111-111111111111', 'ad1d0000-bbbb-bbbb-bbbb-bbbbbbbbbbbb', '0cd10000-0000-0000-0000-000000000001', '0cd10000-0000-0000-0000-000000000091', 'active', 100.00, 100.00, 9101, 'ad1d0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'ad1d0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa'),
  ('1ad10000-0000-0000-0000-000000000002', 'c1d00000-0000-0000-0000-000000000001', 'b1d00000-1111-1111-1111-111111111111', 'ad1d0000-bbbb-bbbb-bbbb-bbbbbbbbbbbb', '0cd10000-0000-0000-0000-000000000001', '0cd10000-0000-0000-0000-000000000091', 'active',  50.00,  50.00, 9102, 'ad1d0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'ad1d0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa'),
  ('1ad10000-0000-0000-0000-000000000003', 'c1d00000-0000-0000-0000-000000000001', 'b1d00000-1111-1111-1111-111111111111', 'ad1d0000-bbbb-bbbb-bbbb-bbbbbbbbbbbb', '0cd10000-0000-0000-0000-000000000001', '0cd10000-0000-0000-0000-000000000091', 'active',  80.00,  80.00, 9103, 'ad1d0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'ad1d0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa'),
  ('1ad10000-0000-0000-0000-000000000004', 'c1d00000-0000-0000-0000-000000000001', 'b1d00000-1111-1111-1111-111111111111', 'ad1d0000-bbbb-bbbb-bbbb-bbbbbbbbbbbb', '0cd10000-0000-0000-0000-000000000001', '0cd10000-0000-0000-0000-000000000091', 'active',  40.00,  40.00, 9104, 'ad1d0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'ad1d0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa'),
  ('1ad10000-0000-0000-0000-000000000005', 'c1d00000-0000-0000-0000-000000000001', 'b1d00000-1111-1111-1111-111111111111', 'ad1d0000-bbbb-bbbb-bbbb-bbbbbbbbbbbb', '0cd10000-0000-0000-0000-000000000001', '0cd10000-0000-0000-0000-000000000091', 'active',  60.00,  60.00, 9105, 'ad1d0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'ad1d0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa'),
  ('1ad10000-0000-0000-0000-000000000006', 'c1d00000-0000-0000-0000-000000000001', 'b1d00000-1111-1111-1111-111111111111', 'ad1d0000-bbbb-bbbb-bbbb-bbbbbbbbbbbb', '0cd10000-0000-0000-0000-000000000001', '0cd10000-0000-0000-0000-000000000091', 'active',  40.00,  40.00, 9106, 'ad1d0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'ad1d0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa');

-- ============================================================================
-- RCP2: Seed trigger — credit payment creates a pending balance
-- Sale A receives one credit payment of 100.00
-- ============================================================================
INSERT INTO public.payments (
  id, company_id, sale_id, payment_method, amount, created_by, updated_by
) VALUES (
  '1fd10000-0000-0000-0000-000000000001',
  'c1d00000-0000-0000-0000-000000000001',
  '1ad10000-0000-0000-0000-000000000001',
  'credit', 100.00,
  'ad1d0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'ad1d0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
);

SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.customer_balances WHERE company_id = 'c1d00000-0000-0000-0000-000000000001' AND sale_id = '1ad10000-0000-0000-0000-000000000001' $$,
  ARRAY[1::bigint],
  'RCP2: one credit payment seeds exactly one customer_balances row'
);

SELECT is(
  status, 'pending',
  'RCP2: seeded balance starts in pending status'
) FROM public.customer_balances WHERE sale_id = '1ad10000-0000-0000-0000-000000000001';

SELECT is(
  total_amount, 100.00::numeric,
  'RCP2: seeded balance total_amount equals the credit payment amount'
) FROM public.customer_balances WHERE sale_id = '1ad10000-0000-0000-0000-000000000001';

SELECT is(
  remaining_amount, 100.00::numeric,
  'RCP2: seeded balance remaining_amount equals total_amount (paid_amount=0)'
) FROM public.customer_balances WHERE sale_id = '1ad10000-0000-0000-0000-000000000001';

SELECT is(
  customer_id, '0cd10000-0000-0000-0000-000000000001'::uuid,
  'RCP2: seeded balance customer_id comes from the sale'
) FROM public.customer_balances WHERE sale_id = '1ad10000-0000-0000-0000-000000000001';

-- ============================================================================
-- RCP2: non-credit payment does NOT seed a balance
-- Sale B receives a cash payment only
-- ============================================================================
INSERT INTO public.payments (
  id, company_id, sale_id, payment_method, amount, created_by, updated_by
) VALUES (
  '1fd10000-0000-0000-0000-000000000002',
  'c1d00000-0000-0000-0000-000000000001',
  '1ad10000-0000-0000-0000-000000000002',
  'cash', 50.00,
  'ad1d0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'ad1d0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
);

SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.customer_balances WHERE company_id = 'c1d00000-0000-0000-0000-000000000001' AND sale_id = '1ad10000-0000-0000-0000-000000000002' $$,
  ARRAY[0::bigint],
  'RCP2: non-credit payment does not seed a balance'
);

-- ============================================================================
-- RCP2: multiple credit payments for one sale aggregate into ONE balance
-- Sale E receives two credit payments (60.00 then 25.00) → one balance, total 85.00
-- ============================================================================
INSERT INTO public.payments (id, company_id, sale_id, payment_method, amount, created_by, updated_by)
VALUES ('1fd10000-0000-0000-0000-000000000005', 'c1d00000-0000-0000-0000-000000000001', '1ad10000-0000-0000-0000-000000000005', 'credit', 60.00, 'ad1d0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'ad1d0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa');

INSERT INTO public.payments (id, company_id, sale_id, payment_method, amount, created_by, updated_by)
VALUES ('1fd10000-0000-0000-0000-000000000006', 'c1d00000-0000-0000-0000-000000000001', '1ad10000-0000-0000-0000-000000000005', 'credit', 25.00, 'ad1d0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'ad1d0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa');

SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.customer_balances WHERE company_id = 'c1d00000-0000-0000-0000-000000000001' AND sale_id = '1ad10000-0000-0000-0000-000000000005' $$,
  ARRAY[1::bigint],
  'RCP2: two credit payments converge into one balance row'
);

SELECT is(
  total_amount, 85.00::numeric,
  'RCP2: aggregated balance total_amount = sum of credit payments (60 + 25)'
) FROM public.customer_balances WHERE sale_id = '1ad10000-0000-0000-0000-000000000005';

-- ============================================================================
-- RCP3: cancellation trigger — cancelling a sale transitions its balance
-- Sale C: seed a balance, then cancel the sale → balance status = cancelled
-- ============================================================================
INSERT INTO public.payments (id, company_id, sale_id, payment_method, amount, created_by, updated_by)
VALUES ('1fd10000-0000-0000-0000-000000000003', 'c1d00000-0000-0000-0000-000000000001', '1ad10000-0000-0000-0000-000000000003', 'credit', 80.00, 'ad1d0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'ad1d0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa');

UPDATE public.sales
   SET status = 'cancelled', updated_by = 'ad1d0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
 WHERE id = '1ad10000-0000-0000-0000-000000000003';

SELECT is(
  status, 'cancelled',
  'RCP3: cancelling a sale transitions linked balance to cancelled'
) FROM public.customer_balances WHERE sale_id = '1ad10000-0000-0000-0000-000000000003';

-- ============================================================================
-- RCP4: RPC happy path — pending → partial → paid on Sale A (total 100)
-- abono1 = 30.00 → partial; abono2 = 70.00 → paid, remaining 0
-- (two sequential abonos on the same balance exercise the FOR UPDATE code path)
-- ============================================================================
DO $$
DECLARE v_balance_id UUID;
BEGIN
  SELECT id INTO v_balance_id FROM public.customer_balances
   WHERE company_id = 'c1d00000-0000-0000-0000-000000000001'
     AND sale_id = '1ad10000-0000-0000-0000-000000000001';

  PERFORM set_config('cp.balance_id_a', v_balance_id::text, true);
END;
$$;

SELECT results_eq(
  $$ SELECT public.register_customer_payment_transaction(jsonb_build_object(
       'company_id', 'c1d00000-0000-0000-0000-000000000001',
       'actor_user_id', 'ad1d0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
       'balance_id', current_setting('cp.balance_id_a'),
       'amount', 30.00,
       'payment_method', 'cash'
     ))->>'success' $$,
  ARRAY['true'::text],
  'RCP4: first abono (pending→partial) returns success'
);

SELECT is(
  status, 'partial',
  'RCP4: balance is partial after partial abono'
) FROM public.customer_balances WHERE sale_id = '1ad10000-0000-0000-0000-000000000001';

SELECT results_eq(
  $$ SELECT public.register_customer_payment_transaction(jsonb_build_object(
       'company_id', 'c1d00000-0000-0000-0000-000000000001',
       'actor_user_id', 'ad1d0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
       'balance_id', current_setting('cp.balance_id_a'),
       'amount', 70.00,
       'payment_method', 'transfer'
     ))->>'success' $$,
  ARRAY['true'::text],
  'RCP4: second abono (partial→paid) returns success'
);

SELECT is(
  status, 'paid',
  'RCP4: balance is paid once abonos sum to total'
) FROM public.customer_balances WHERE sale_id = '1ad10000-0000-0000-0000-000000000001';

SELECT is(
  remaining_amount, 0.00::numeric,
  'RCP4: remaining_amount is 0 once fully paid'
) FROM public.customer_balances WHERE sale_id = '1ad10000-0000-0000-0000-000000000001';

-- ============================================================================
-- RCP5: RPC edge cases
-- ============================================================================

-- overpayment: Sale B has no balance (cash only); use a fresh balance on Sale F.
-- Seed Sale F with a 40.00 credit, then attempt an abono of 50.00 > 40.00.
INSERT INTO public.payments (id, company_id, sale_id, payment_method, amount, created_by, updated_by)
VALUES ('1fd10000-0000-0000-0000-000000000004', 'c1d00000-0000-0000-0000-000000000001', '1ad10000-0000-0000-0000-000000000004', 'credit', 40.00, 'ad1d0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'ad1d0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa');

DO $$
DECLARE v_bid UUID;
BEGIN
  SELECT id INTO v_bid FROM public.customer_balances
   WHERE company_id = 'c1d00000-0000-0000-0000-000000000001'
     AND sale_id = '1ad10000-0000-0000-0000-000000000004';
  PERFORM set_config('cp.balance_id_f', v_bid::text, true);
END;
$$;

SELECT results_eq(
  $$ SELECT public.register_customer_payment_transaction(jsonb_build_object(
       'company_id', 'c1d00000-0000-0000-0000-000000000001',
       'actor_user_id', 'ad1d0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
       'balance_id', current_setting('cp.balance_id_f'),
       'amount', 50.00,
       'payment_method', 'cash'
     ))->>'success' $$,
  ARRAY['false'::text],
  'RCP5: overpayment (amount > remaining) is rejected'
);

SELECT results_eq(
  $$ SELECT count(*)::bigint FROM public.customer_payments
     WHERE balance_id = current_setting('cp.balance_id_f')::uuid $$,
  ARRAY[0::bigint],
  'RCP5: overpayment rejection creates no customer_payments row'
);

-- paid balance: Sale A balance is now paid → another abono is rejected
SELECT results_eq(
  $$ SELECT public.register_customer_payment_transaction(jsonb_build_object(
       'company_id', 'c1d00000-0000-0000-0000-000000000001',
       'actor_user_id', 'ad1d0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
       'balance_id', current_setting('cp.balance_id_a'),
       'amount', 10.00,
       'payment_method', 'cash'
     ))->>'success' $$,
  ARRAY['false'::text],
  'RCP5: abono against a paid balance is rejected'
);

-- cancelled balance: Sale C balance is cancelled → abono is rejected
DO $$
DECLARE v_bid UUID;
BEGIN
  SELECT id INTO v_bid FROM public.customer_balances
   WHERE company_id = 'c1d00000-0000-0000-0000-000000000001'
     AND sale_id = '1ad10000-0000-0000-0000-000000000003';
  PERFORM set_config('cp.balance_id_c', v_bid::text, true);
END;
$$;

SELECT results_eq(
  $$ SELECT public.register_customer_payment_transaction(jsonb_build_object(
       'company_id', 'c1d00000-0000-0000-0000-000000000001',
       'actor_user_id', 'ad1d0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
       'balance_id', current_setting('cp.balance_id_c'),
       'amount', 10.00,
       'payment_method', 'cash'
     ))->>'success' $$,
  ARRAY['false'::text],
  'RCP5: abono against a cancelled balance is rejected'
);

-- amount ≤ 0: rejected (both 0 and negative)
SELECT results_eq(
  $$ SELECT public.register_customer_payment_transaction(jsonb_build_object(
       'company_id', 'c1d00000-0000-0000-0000-000000000001',
       'actor_user_id', 'ad1d0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
       'balance_id', current_setting('cp.balance_id_f'),
       'amount', 0.00,
       'payment_method', 'cash'
     ))->>'success' $$,
  ARRAY['false'::text],
  'RCP5: zero-amount abono is rejected'
);

SELECT results_eq(
  $$ SELECT public.register_customer_payment_transaction(jsonb_build_object(
       'company_id', 'c1d00000-0000-0000-0000-000000000001',
       'actor_user_id', 'ad1d0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
       'balance_id', current_setting('cp.balance_id_f'),
       'amount', -5.00,
       'payment_method', 'cash'
     ))->>'success' $$,
  ARRAY['false'::text],
  'RCP5: negative-amount abono is rejected'
);

-- invalid payment_method: rejected
SELECT results_eq(
  $$ SELECT public.register_customer_payment_transaction(jsonb_build_object(
       'company_id', 'c1d00000-0000-0000-0000-000000000001',
       'actor_user_id', 'ad1d0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
       'balance_id', current_setting('cp.balance_id_f'),
       'amount', 10.00,
       'payment_method', 'credit'
     ))->>'success' $$,
  ARRAY['false'::text],
  'RCP5: credit payment_method for abono is rejected'
);

-- unknown balance_id: NOT_FOUND
SELECT results_eq(
  $$ SELECT public.register_customer_payment_transaction(jsonb_build_object(
       'company_id', 'c1d00000-0000-0000-0000-000000000001',
       'actor_user_id', 'ad1d0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
       'balance_id', 'ffffffff-0000-0000-0000-0000000000ff',
       'amount', 10.00,
       'payment_method', 'cash'
     ))->>'success' $$,
  ARRAY['false'::text],
  'RCP5: unknown balance_id returns failure (NOT_FOUND)'
);

-- ============================================================================
-- Cleanup
-- ============================================================================
SELECT * FROM finish();
ROLLBACK;
