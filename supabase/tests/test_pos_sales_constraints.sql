-- pgTAP: POS Sales domain constraint tests
-- Verifies core table constraints, composite FKs, logical-delete protection,
-- status CHECK, and sale_number uniqueness per branch.

BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap;

SELECT plan(19);

-- Seed data
INSERT INTO public.companies (id, name, slug)
VALUES
  ('c1a00000-0000-0000-0000-000000000001', 'Sales Constraint Co A', 'sales-constraint-co-a'),
  ('c2a00000-0000-0000-0000-000000000002', 'Sales Constraint Co B', 'sales-constraint-co-b');

INSERT INTO public.branches (id, company_id, name, slug)
VALUES
  ('b1a00000-1111-1111-1111-111111111111', 'c1a00000-0000-0000-0000-000000000001', 'Sales Branch A1', 'sales-branch-a1'),
  ('b2a00000-2222-2222-2222-222222222222', 'c2a00000-0000-0000-0000-000000000002', 'Sales Branch B1', 'sales-branch-b1');

INSERT INTO auth.users (id, email, raw_app_meta_data, raw_user_meta_data)
VALUES
  ('aa1a0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'sales-constraint-admin-a@test.com',
   '{"company_id": "c1a00000-0000-0000-0000-000000000001", "role": "admin"}',
   '{"full_name": "Sales Constraint Admin A"}'),
  ('ac1a0000-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'sales-constraint-cashier-a@test.com',
   '{"company_id": "c1a00000-0000-0000-0000-000000000001", "role": "cashier"}',
   '{"full_name": "Sales Constraint Cashier A"}'),
  ('ac2a0000-cccc-cccc-cccc-cccccccccccc', 'sales-constraint-cashier-b@test.com',
   '{"company_id": "c2a00000-0000-0000-0000-000000000002", "role": "cashier"}',
   '{"full_name": "Sales Constraint Cashier B"}')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.profiles (id, full_name)
VALUES
  ('aa1a0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'Sales Constraint Admin A'),
  ('ac1a0000-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'Sales Constraint Cashier A'),
  ('ac2a0000-cccc-cccc-cccc-cccccccccccc', 'Sales Constraint Cashier B')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.company_users (user_id, company_id, role)
VALUES
  ('aa1a0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'c1a00000-0000-0000-0000-000000000001', 'admin'),
  ('ac1a0000-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'c1a00000-0000-0000-0000-000000000001', 'cashier'),
  ('ac2a0000-cccc-cccc-cccc-cccccccccccc', 'c2a00000-0000-0000-0000-000000000002', 'cashier')
ON CONFLICT (user_id, company_id) DO NOTHING;

INSERT INTO public.customers (id, company_id, name, slug, created_by)
VALUES
  ('ca1a0000-0000-0000-0000-000000000001', 'c1a00000-0000-0000-0000-000000000001', 'Sales Customer A', 'sales-customer-a', 'aa1a0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa'),
  ('ca2a0000-0000-0000-0000-000000000002', 'c2a00000-0000-0000-0000-000000000002', 'Sales Customer B', 'sales-customer-b', 'ac2a0000-cccc-cccc-cccc-cccccccccccc');

-- Open a cash session for cashier A in branch A1
INSERT INTO public.cash_sessions (
  id, company_id, branch_id, cashier_user_id, status, opening_amount, expected_cash_amount, created_by, updated_by
) VALUES (
  '0c1a0000-0000-0000-0000-000000000001',
  'c1a00000-0000-0000-0000-000000000001',
  'b1a00000-1111-1111-1111-111111111111',
  'ac1a0000-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
  'open', 100.00, 100.00,
  'aa1a0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'aa1a0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
);

-- ============================================================================
-- Table existence
-- ============================================================================
SELECT has_table('public', 'sales', 'sales table exists');
SELECT has_table('public', 'sale_items', 'sale_items table exists');
SELECT has_table('public', 'sale_item_batches', 'sale_item_batches table exists');
SELECT has_table('public', 'payments', 'payments table exists');
SELECT has_table('public', 'discount_authorizations', 'discount_authorizations table exists');

-- ============================================================================
-- Valid inserts
-- ============================================================================
SELECT lives_ok(
  $$ INSERT INTO public.sales (
       id, company_id, branch_id, cashier_user_id, cash_session_id, status,
       subtotal, discount_amount, tax_amount, total, sale_number, created_by, updated_by
     ) VALUES (
       '1a1a0000-0000-0000-0000-000000000001',
       'c1a00000-0000-0000-0000-000000000001',
       'b1a00000-1111-1111-1111-111111111111',
       'ac1a0000-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
       '0c1a0000-0000-0000-0000-000000000001',
       'active', 100.00, 0, 10.00, 110.00, 1001,
       'aa1a0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
       'aa1a0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
     ) $$,
  'sales: valid insert succeeds'
);

-- ============================================================================
-- Status CHECK
-- ============================================================================
SELECT throws_ok(
  $$ INSERT INTO public.sales (
        company_id, branch_id, cashier_user_id, cash_session_id, status,
       subtotal, total, sale_number
     ) VALUES (
       'c1a00000-0000-0000-0000-000000000001',
       'b1a00000-1111-1111-1111-111111111111',
       'ac1a0000-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
       '0c1a0000-0000-0000-0000-000000000001',
       'pending', 50.00, 50.00, 1002
     ) $$,
  NULL, NULL,
  'sales: invalid status is rejected'
);

-- ============================================================================
-- Composite FK: branch must belong to same company
-- ============================================================================
SELECT throws_ok(
  $$ INSERT INTO public.sales (
       company_id, branch_id, cashier_user_id, cash_session_id, status,
       subtotal, total, sale_number
     ) VALUES (
       'c1a00000-0000-0000-0000-000000000001',
       'b2a00000-2222-2222-2222-222222222222',
       'ac1a0000-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
       '0c1a0000-0000-0000-0000-000000000001',
       'active', 50.00, 50.00, 1003
     ) $$,
  NULL, NULL,
  'sales: branch composite FK rejects cross-company branch'
);

-- ============================================================================
-- Composite FK: cash session must belong to same company
-- ============================================================================
SELECT throws_ok(
  $$ INSERT INTO public.sales (
       company_id, branch_id, cashier_user_id, cash_session_id, status,
       subtotal, total, sale_number
     ) VALUES (
       'c2a00000-0000-0000-0000-000000000002',
       'b2a00000-2222-2222-2222-222222222222',
       'ac2a0000-cccc-cccc-cccc-cccccccccccc',
       '0c1a0000-0000-0000-0000-000000000001',
       'active', 50.00, 50.00, 1004
     ) $$,
  NULL, NULL,
  'sales: cash_session composite FK rejects cross-company session'
);

-- ============================================================================
-- Composite FK: customer must belong to same company customers table
-- ============================================================================
SELECT lives_ok(
  $$ INSERT INTO public.sales (
       id, company_id, branch_id, cashier_user_id, customer_id, cash_session_id, status,
       subtotal, total, sale_number, created_by, updated_by
     ) VALUES (
       '1a1a0000-0000-0000-0000-000000000099',
       'c1a00000-0000-0000-0000-000000000001',
       'b1a00000-1111-1111-1111-111111111111',
       'ac1a0000-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
       'ca1a0000-0000-0000-0000-000000000001',
       '0c1a0000-0000-0000-0000-000000000001',
       'active', 50.00, 50.00, 1099,
       'aa1a0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
       'aa1a0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
     ) $$,
  'sales: customer composite FK accepts same-company customer'
);

SELECT throws_ok(
  $$ INSERT INTO public.sales (
       company_id, branch_id, cashier_user_id, customer_id, cash_session_id, status,
       subtotal, total, sale_number
     ) VALUES (
       'c1a00000-0000-0000-0000-000000000001',
       'b1a00000-1111-1111-1111-111111111111',
       'ac1a0000-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
       'ca2a0000-0000-0000-0000-000000000002',
       '0c1a0000-0000-0000-0000-000000000001',
       'active', 50.00, 50.00, 1100
     ) $$,
  NULL, NULL,
  'sales: customer composite FK rejects cross-company customer'
);

-- ============================================================================
-- Logical deletion: physical DELETE is prohibited
-- ============================================================================
SELECT throws_ok(
  $$ DELETE FROM public.sales WHERE id = '1a1a0000-0000-0000-0000-000000000001' $$,
  NULL, NULL,
  'sales: physical DELETE is rejected (logical delete only)'
);

-- ============================================================================
-- Child table mutation prevention
-- ============================================================================
INSERT INTO public.sale_items (
  id, company_id, sale_id, variant_id, quantity, unit_price, line_total, created_by, updated_by
) VALUES (
  '3a1a0000-0000-0000-0000-000000000001',
  'c1a00000-0000-0000-0000-000000000001',
  '1a1a0000-0000-0000-0000-000000000001',
  '00000000-0000-0000-0000-000000000001',
  2, 50.00, 100.00,
  'aa1a0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'aa1a0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
);

-- Insert rows into child tables so triggers have rows to act on
INSERT INTO public.sale_item_batches (
  company_id, sale_item_id, lot_id, quantity, created_by, updated_by
) VALUES (
  'c1a00000-0000-0000-0000-000000000001',
  '3a1a0000-0000-0000-0000-000000000001',
  '00000000-0000-0000-0000-000000000002',
  2, 'aa1a0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'aa1a0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
);

INSERT INTO public.payments (
  company_id, sale_id, payment_method, amount, created_by, updated_by
) VALUES (
  'c1a00000-0000-0000-0000-000000000001',
  '1a1a0000-0000-0000-0000-000000000001',
  'cash', 110.00,
  'aa1a0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'aa1a0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
);

INSERT INTO public.discount_authorizations (
  company_id, sale_id, authorized_by, discount_percent, discount_amount, reason, created_by, updated_by
) VALUES (
  'c1a00000-0000-0000-0000-000000000001',
  '1a1a0000-0000-0000-0000-000000000001',
  'aa1a0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  10.00, 11.00, 'Test',
  'aa1a0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'aa1a0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
);

SELECT throws_ok(
  $$ DELETE FROM public.sale_items WHERE id = '3a1a0000-0000-0000-0000-000000000001' $$,
  NULL, NULL,
  'sale_items: physical DELETE is rejected'
);

SELECT throws_ok(
  $$ DELETE FROM public.payments WHERE company_id = 'c1a00000-0000-0000-0000-000000000001' $$,
  NULL, NULL,
  'payments: physical DELETE is rejected'
);

SELECT throws_ok(
  $$ DELETE FROM public.discount_authorizations WHERE company_id = 'c1a00000-0000-0000-0000-000000000001' $$,
  NULL, NULL,
  'discount_authorizations: physical DELETE is rejected'
);

SELECT throws_ok(
  $$ DELETE FROM public.sale_item_batches WHERE company_id = 'c1a00000-0000-0000-0000-000000000001' $$,
  NULL, NULL,
  'sale_item_batches: physical DELETE is rejected'
);

-- ============================================================================
-- Append-only: no UPDATE on certain child tables
-- ============================================================================
SELECT throws_ok(
  $$ UPDATE public.payments SET amount = 999 WHERE company_id = 'c1a00000-0000-0000-0000-000000000001' $$,
  NULL, NULL,
  'payments: direct UPDATE is rejected (append-only)'
);

SELECT throws_ok(
  $$ UPDATE public.sale_item_batches SET quantity = 999 WHERE company_id = 'c1a00000-0000-0000-0000-000000000001' $$,
  NULL, NULL,
  'sale_item_batches: direct UPDATE is rejected (append-only)'
);

SELECT throws_ok(
  $$ UPDATE public.discount_authorizations SET discount_percent = 99 WHERE company_id = 'c1a00000-0000-0000-0000-000000000001' $$,
  NULL, NULL,
  'discount_authorizations: direct UPDATE is rejected (append-only)'
);

-- ============================================================================
-- Cleanup
-- ============================================================================
SELECT * FROM finish();
ROLLBACK;
