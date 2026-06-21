-- pgTAP: Credit Payments domain constraint tests
-- Verifies table/column presence, NOT NULL, CHECK constraints, UNIQUE
-- (company_id, sale_id), composite FKs (sales + customers), the STORED
-- generated column (remaining_amount), and append-only protection.
-- source: RCP1, design D1

BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap;

SELECT plan(39);

-- ============================================================================
-- Seed data
-- ============================================================================
INSERT INTO public.companies (id, name, slug)
VALUES ('c1e00000-0000-0000-0000-000000000001', 'Credit Constraints Co A', 'credit-constraints-co-a');

INSERT INTO public.branches (id, company_id, name, slug)
VALUES ('b1e00000-1111-1111-1111-111111111111', 'c1e00000-0000-0000-0000-000000000001', 'CC Branch A1', 'cc-branch-a1');

INSERT INTO auth.users (id, email, raw_app_meta_data, raw_user_meta_data)
VALUES
  ('ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'cc-admin-a@test.com',
   '{"company_id": "c1e00000-0000-0000-0000-000000000001", "role": "admin"}',
   '{"full_name": "CC Admin A"}'),
  ('ae1e0000-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'cc-cashier-a@test.com',
   '{"company_id": "c1e00000-0000-0000-0000-000000000001", "role": "cashier"}',
   '{"full_name": "CC Cashier A"}')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.profiles (id, full_name)
VALUES
  ('ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'CC Admin A'),
  ('ae1e0000-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'CC Cashier A')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.company_users (user_id, company_id, role)
VALUES
  ('ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'c1e00000-0000-0000-0000-000000000001', 'admin'),
  ('ae1e0000-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'c1e00000-0000-0000-0000-000000000001', 'cashier')
ON CONFLICT (user_id, company_id) DO NOTHING;

INSERT INTO public.branch_users (user_id, branch_id, company_id)
VALUES ('ae1e0000-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'b1e00000-1111-1111-1111-111111111111', 'c1e00000-0000-0000-0000-000000000001')
ON CONFLICT (user_id, branch_id) DO NOTHING;

-- A customer for the customer_balances.customer_id composite FK
INSERT INTO public.customers (id, company_id, name, slug, created_by)
VALUES (
  '0ce10000-0000-0000-0000-000000000001',
  'c1e00000-0000-0000-0000-000000000001',
  'CC Customer One', 'cc-customer-one',
  'ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
);

-- Open cash session for cashier A
INSERT INTO public.cash_sessions (
  id, company_id, branch_id, cashier_user_id, status, opening_amount, expected_cash_amount, created_by, updated_by
) VALUES (
  '0ce10000-0000-0000-0000-000000000091',
  'c1e00000-0000-0000-0000-000000000001',
  'b1e00000-1111-1111-1111-111111111111',
  'ae1e0000-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
  'open', 100.00, 100.00,
  'ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
);

-- A handful of sales in company A (distinct sale_numbers) so each CHECK/FK
-- rejection test can use a fresh sale_id without colliding on UNIQUE.
INSERT INTO public.sales (
  id, company_id, branch_id, cashier_user_id, cash_session_id, status,
  subtotal, total, sale_number, created_by, updated_by
) VALUES
  ('1ae10000-0000-0000-0000-000000000001', 'c1e00000-0000-0000-0000-000000000001', 'b1e00000-1111-1111-1111-111111111111', 'ae1e0000-bbbb-bbbb-bbbb-bbbbbbbbbbbb', '0ce10000-0000-0000-0000-000000000091', 'active', 100.00, 100.00, 9001, 'ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa'),
  ('1ae10000-0000-0000-0000-000000000002', 'c1e00000-0000-0000-0000-000000000001', 'b1e00000-1111-1111-1111-111111111111', 'ae1e0000-bbbb-bbbb-bbbb-bbbbbbbbbbbb', '0ce10000-0000-0000-0000-000000000091', 'active',  50.00,  50.00, 9002, 'ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa'),
  ('1ae10000-0000-0000-0000-000000000003', 'c1e00000-0000-0000-0000-000000000001', 'b1e00000-1111-1111-1111-111111111111', 'ae1e0000-bbbb-bbbb-bbbb-bbbbbbbbbbbb', '0ce10000-0000-0000-0000-000000000091', 'active',  10.00,  10.00, 9003, 'ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa'),
  ('1ae10000-0000-0000-0000-000000000004', 'c1e00000-0000-0000-0000-000000000001', 'b1e00000-1111-1111-1111-111111111111', 'ae1e0000-bbbb-bbbb-bbbb-bbbbbbbbbbbb', '0ce10000-0000-0000-0000-000000000091', 'active',  10.00,  10.00, 9004, 'ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa'),
  ('1ae10000-0000-0000-0000-000000000005', 'c1e00000-0000-0000-0000-000000000001', 'b1e00000-1111-1111-1111-111111111111', 'ae1e0000-bbbb-bbbb-bbbb-bbbbbbbbbbbb', '0ce10000-0000-0000-0000-000000000091', 'active',  10.00,  10.00, 9005, 'ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa'),
  ('1ae10000-0000-0000-0000-000000000006', 'c1e00000-0000-0000-0000-000000000001', 'b1e00000-1111-1111-1111-111111111111', 'ae1e0000-bbbb-bbbb-bbbb-bbbbbbbbbbbb', '0ce10000-0000-0000-0000-000000000091', 'active',  10.00,  10.00, 9006, 'ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa'),
  ('1ae10000-0000-0000-0000-000000000007', 'c1e00000-0000-0000-0000-000000000001', 'b1e00000-1111-1111-1111-111111111111', 'ae1e0000-bbbb-bbbb-bbbb-bbbbbbbbbbbb', '0ce10000-0000-0000-0000-000000000091', 'active',  10.00,  10.00, 9007, 'ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa');

-- ============================================================================
-- Table + column existence
-- ============================================================================
SELECT has_table('public', 'customer_balances', 'customer_balances table exists');
SELECT has_table('public', 'customer_payments', 'customer_payments table exists');

SELECT has_column('public', 'customer_balances', 'id', 'customer_balances.id exists');
SELECT has_column('public', 'customer_balances', 'company_id', 'customer_balances.company_id exists');
SELECT has_column('public', 'customer_balances', 'sale_id', 'customer_balances.sale_id exists');
SELECT has_column('public', 'customer_balances', 'customer_id', 'customer_balances.customer_id exists');
SELECT has_column('public', 'customer_balances', 'total_amount', 'customer_balances.total_amount exists');
SELECT has_column('public', 'customer_balances', 'paid_amount', 'customer_balances.paid_amount exists');
SELECT has_column('public', 'customer_balances', 'remaining_amount', 'customer_balances.remaining_amount exists');
SELECT has_column('public', 'customer_balances', 'status', 'customer_balances.status exists');
SELECT has_column('public', 'customer_balances', 'is_active', 'customer_balances.is_active exists');
SELECT has_column('public', 'customer_balances', 'deleted_at', 'customer_balances.deleted_at exists (soft-delete)');

SELECT has_column('public', 'customer_payments', 'balance_id', 'customer_payments.balance_id exists');
SELECT has_column('public', 'customer_payments', 'amount', 'customer_payments.amount exists');
SELECT has_column('public', 'customer_payments', 'payment_method', 'customer_payments.payment_method exists');

-- ============================================================================
-- NOT NULL on key customer_balances columns
-- ============================================================================
SELECT col_not_null('public', 'customer_balances', 'company_id', 'customer_balances.company_id NOT NULL');
SELECT col_not_null('public', 'customer_balances', 'sale_id', 'customer_balances.sale_id NOT NULL');
SELECT col_not_null('public', 'customer_balances', 'customer_id', 'customer_balances.customer_id NOT NULL');
SELECT col_not_null('public', 'customer_balances', 'total_amount', 'customer_balances.total_amount NOT NULL');
SELECT col_not_null('public', 'customer_balances', 'status', 'customer_balances.status NOT NULL');

-- ============================================================================
-- Valid insert + generated column correctness
-- ============================================================================
SELECT lives_ok(
  $$ INSERT INTO public.customer_balances (
       id, company_id, sale_id, customer_id, total_amount, paid_amount, status, created_by, updated_by
     ) VALUES (
       'fbe10000-0000-0000-0000-000000000001',
       'c1e00000-0000-0000-0000-000000000001',
       '1ae10000-0000-0000-0000-000000000001',
       '0ce10000-0000-0000-0000-000000000001',
       100.00, 30.00, 'partial',
       'ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
       'ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
     ) $$,
  'customer_balances: valid insert succeeds'
);

-- remaining_amount is a STORED generated column = total_amount - paid_amount
SELECT is(
  remaining_amount, 70.00::numeric,
  'customer_balances: remaining_amount is generated (100 - 30 = 70)'
) FROM public.customer_balances WHERE id = 'fbe10000-0000-0000-0000-000000000001';

-- Default paid_amount = 0 ⇒ remaining = total
SELECT lives_ok(
  $$ INSERT INTO public.customer_balances (
       id, company_id, sale_id, customer_id, total_amount, created_by, updated_by
     ) VALUES (
       'fbe10000-0000-0000-0000-000000000002',
       'c1e00000-0000-0000-0000-000000000001',
       '1ae10000-0000-0000-0000-000000000002',
       '0ce10000-0000-0000-0000-000000000001',
       50.00,
       'ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
       'ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
     ) $$,
  'customer_balances: default paid_amount=0 insert succeeds'
);

SELECT is(
  remaining_amount, 50.00::numeric,
  'customer_balances: default remaining_amount = total_amount (50)'
) FROM public.customer_balances WHERE id = 'fbe10000-0000-0000-0000-000000000002';

-- ============================================================================
-- UNIQUE (company_id, sale_id) — one balance per sale
-- ============================================================================
SELECT throws_ok(
  $$ INSERT INTO public.customer_balances (
       id, company_id, sale_id, customer_id, total_amount, created_by, updated_by
     ) VALUES (
       'fbe10000-0000-0000-0000-000000000003',
       'c1e00000-0000-0000-0000-000000000001',
       '1ae10000-0000-0000-0000-000000000001',  -- same sale as balance #1
       '0ce10000-0000-0000-0000-000000000001',
       25.00,
       'ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
       'ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
     ) $$,
  NULL, NULL,
  'customer_balances: UNIQUE (company_id, sale_id) rejects second balance for same sale'
);

-- ============================================================================
-- CHECK constraints
-- ============================================================================
SELECT throws_ok(
  $$ INSERT INTO public.customer_balances (
       id, company_id, sale_id, customer_id, total_amount, status, created_by, updated_by
     ) VALUES (
       'fbe10000-0000-0000-0000-000000000010',
       'c1e00000-0000-0000-0000-000000000001',
       '1ae10000-0000-0000-0000-000000000003',
       '0ce10000-0000-0000-0000-000000000001',
       10.00, 'foo',
       'ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
       'ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
     ) $$,
  NULL, NULL,
  'customer_balances: status CHECK rejects invalid enum value'
);

SELECT throws_ok(
  $$ INSERT INTO public.customer_balances (
       id, company_id, sale_id, customer_id, total_amount, created_by, updated_by
     ) VALUES (
       'fbe10000-0000-0000-0000-000000000011',
       'c1e00000-0000-0000-0000-000000000001',
       '1ae10000-0000-0000-0000-000000000004',
       '0ce10000-0000-0000-0000-000000000001',
       0.00,
       'ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
       'ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
     ) $$,
  NULL, NULL,
  'customer_balances: total_amount CHECK rejects zero'
);

SELECT throws_ok(
  $$ INSERT INTO public.customer_balances (
       id, company_id, sale_id, customer_id, total_amount, created_by, updated_by
     ) VALUES (
       'fbe10000-0000-0000-0000-000000000012',
       'c1e00000-0000-0000-0000-000000000001',
       '1ae10000-0000-0000-0000-000000000005',
       '0ce10000-0000-0000-0000-000000000001',
       -10.00,
       'ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
       'ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
     ) $$,
  NULL, NULL,
  'customer_balances: total_amount CHECK rejects negative'
);

SELECT throws_ok(
  $$ INSERT INTO public.customer_balances (
       id, company_id, sale_id, customer_id, total_amount, paid_amount, created_by, updated_by
     ) VALUES (
       'fbe10000-0000-0000-0000-000000000013',
       'c1e00000-0000-0000-0000-000000000001',
       '1ae10000-0000-0000-0000-000000000006',
       '0ce10000-0000-0000-0000-000000000001',
       10.00, -5.00,
       'ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
       'ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
     ) $$,
  NULL, NULL,
  'customer_balances: paid_amount CHECK rejects negative'
);

SELECT throws_ok(
  $$ INSERT INTO public.customer_balances (
       id, company_id, sale_id, customer_id, total_amount, paid_amount, created_by, updated_by
     ) VALUES (
       'fbe10000-0000-0000-0000-000000000014',
       'c1e00000-0000-0000-0000-000000000001',
       '1ae10000-0000-0000-0000-000000000007',
       '0ce10000-0000-0000-0000-000000000001',
       10.00, 150.00,
       'ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
       'ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
     ) $$,
  NULL, NULL,
  'customer_balances: remaining_amount CHECK rejects paid > total (generated negative)'
);

-- ============================================================================
-- Composite FKs (same-company reference integrity)
-- ============================================================================
-- sale composite FK: company A balance referencing a sale UUID that does not
-- exist under (company A, *) ⇒ rejected
SELECT throws_ok(
  $$ INSERT INTO public.customer_balances (
       id, company_id, sale_id, customer_id, total_amount, created_by, updated_by
     ) VALUES (
       'fbe10000-0000-0000-0000-000000000020',
       'c1e00000-0000-0000-0000-000000000001',
       'ffffffff-0000-0000-0000-000000000099',  -- non-existent sale in company A
       '0ce10000-0000-0000-0000-000000000001',
       10.00,
       'ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
       'ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
     ) $$,
  NULL, NULL,
  'customer_balances: composite FK (company_id, sale_id)→sales rejects unknown sale'
);

-- customer composite FK: company A balance referencing a customer UUID that
-- does not exist under (company A, *) ⇒ rejected
SELECT throws_ok(
  $$ INSERT INTO public.customer_balances (
       id, company_id, sale_id, customer_id, total_amount, created_by, updated_by
     ) VALUES (
       'fbe10000-0000-0000-0000-000000000021',
       'c1e00000-0000-0000-0000-000000000001',
       '1ae10000-0000-0000-0000-000000000003',  -- valid sale (unused so far)
       'ffffffff-0000-0000-0000-0000000000aa',  -- non-existent customer in company A
       10.00,
       'ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
       'ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
     ) $$,
  NULL, NULL,
  'customer_balances: composite FK (company_id, customer_id)→customers rejects unknown customer'
);

-- ============================================================================
-- customer_payments valid insert + CHECKs + composite FK
-- ============================================================================
SELECT lives_ok(
  $$ INSERT INTO public.customer_payments (
       id, company_id, balance_id, amount, payment_method, reference, created_by, updated_by
     ) VALUES (
       'fae10000-0000-0000-0000-000000000001',
       'c1e00000-0000-0000-0000-000000000001',
       'fbe10000-0000-0000-0000-000000000001',
       20.00, 'cash', 'ABONO-1',
       'ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
       'ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
     ) $$,
  'customer_payments: valid insert succeeds'
);

SELECT throws_ok(
  $$ INSERT INTO public.customer_payments (
       id, company_id, balance_id, amount, payment_method, created_by, updated_by
     ) VALUES (
       'fae10000-0000-0000-0000-000000000002',
       'c1e00000-0000-0000-0000-000000000001',
       'fbe10000-0000-0000-0000-000000000001',
       20.00, 'credit',
       'ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
       'ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
     ) $$,
  NULL, NULL,
  'customer_payments: payment_method CHECK rejects credit'
);

SELECT throws_ok(
  $$ INSERT INTO public.customer_payments (
       id, company_id, balance_id, amount, payment_method, created_by, updated_by
     ) VALUES (
       'fae10000-0000-0000-0000-000000000003',
       'c1e00000-0000-0000-0000-000000000001',
       'fbe10000-0000-0000-0000-000000000001',
       0.00, 'cash',
       'ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
       'ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
     ) $$,
  NULL, NULL,
  'customer_payments: amount CHECK rejects zero'
);

SELECT throws_ok(
  $$ INSERT INTO public.customer_payments (
       id, company_id, balance_id, amount, payment_method, created_by, updated_by
     ) VALUES (
       'fae10000-0000-0000-0000-000000000004',
       'c1e00000-0000-0000-0000-000000000001',
       'ffffffff-0000-0000-0000-0000000000ff',  -- non-existent balance
       20.00, 'cash',
       'ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
       'ae1e0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
     ) $$,
  NULL, NULL,
  'customer_payments: composite FK (company_id, balance_id)→customer_balances rejects unknown balance'
);

-- ============================================================================
-- Append-only protection
-- ============================================================================
SELECT throws_ok(
  $$ UPDATE public.customer_payments SET amount = 999 WHERE id = 'fae10000-0000-0000-0000-000000000001' $$,
  NULL, NULL,
  'customer_payments: direct UPDATE is rejected (append-only)'
);

SELECT throws_ok(
  $$ DELETE FROM public.customer_payments WHERE id = 'fae10000-0000-0000-0000-000000000001' $$,
  NULL, NULL,
  'customer_payments: physical DELETE is rejected'
);

SELECT throws_ok(
  $$ DELETE FROM public.customer_balances WHERE id = 'fbe10000-0000-0000-0000-000000000002' $$,
  NULL, NULL,
  'customer_balances: physical DELETE is rejected (logical deletion only)'
);

-- ============================================================================
-- Cleanup
-- ============================================================================
SELECT * FROM finish();
ROLLBACK;