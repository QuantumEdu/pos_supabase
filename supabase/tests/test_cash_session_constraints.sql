-- pgTAP: Cash session domain constraint tests
-- Verifies core table constraints, composite FKs, open-session uniqueness,
-- logical-delete protection, and append-only ledger protections.

BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap;

SELECT plan(14);

INSERT INTO public.companies (id, name, slug)
VALUES
  ('c1000000-0000-0000-0000-000000000001', 'Cash Constraint Co A', 'cash-constraint-co-a'),
  ('c2000000-0000-0000-0000-000000000002', 'Cash Constraint Co B', 'cash-constraint-co-b');

INSERT INTO public.branches (id, company_id, name, slug)
VALUES
  ('c1111111-1111-1111-1111-111111111111', 'c1000000-0000-0000-0000-000000000001', 'Constraint Branch A1', 'constraint-branch-a1'),
  ('c2222222-2222-2222-2222-222222222222', 'c2000000-0000-0000-0000-000000000002', 'Constraint Branch B1', 'constraint-branch-b1');

INSERT INTO auth.users (id, email, raw_app_meta_data, raw_user_meta_data)
VALUES
  ('caaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'cash-constraint-cashier-a@test.com',
   '{"company_id": "c1000000-0000-0000-0000-000000000001", "role": "cashier"}',
   '{"full_name": "Cash Constraint Cashier A"}'),
  ('cbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'cash-constraint-admin-a@test.com',
   '{"company_id": "c1000000-0000-0000-0000-000000000001", "role": "admin"}',
   '{"full_name": "Cash Constraint Admin A"}'),
  ('cccccccc-cccc-cccc-cccc-cccccccccccc', 'cash-constraint-cashier-b@test.com',
   '{"company_id": "c2000000-0000-0000-0000-000000000002", "role": "cashier"}',
   '{"full_name": "Cash Constraint Cashier B"}')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.profiles (id, full_name)
VALUES
  ('caaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'Cash Constraint Cashier A'),
  ('cbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'Cash Constraint Admin A'),
  ('cccccccc-cccc-cccc-cccc-cccccccccccc', 'Cash Constraint Cashier B')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.company_users (user_id, company_id, role)
VALUES
  ('caaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'c1000000-0000-0000-0000-000000000001', 'cashier'),
  ('cbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'c1000000-0000-0000-0000-000000000001', 'admin'),
  ('cccccccc-cccc-cccc-cccc-cccccccccccc', 'c2000000-0000-0000-0000-000000000002', 'cashier')
ON CONFLICT (user_id, company_id) DO NOTHING;

INSERT INTO public.branch_users (user_id, branch_id, company_id)
VALUES
  ('caaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'c1111111-1111-1111-1111-111111111111', 'c1000000-0000-0000-0000-000000000001'),
  ('cccccccc-cccc-cccc-cccc-cccccccccccc', 'c2222222-2222-2222-2222-222222222222', 'c2000000-0000-0000-0000-000000000002')
ON CONFLICT (user_id, branch_id) DO NOTHING;

SELECT lives_ok(
  $$ INSERT INTO public.cash_sessions (
       id, company_id, branch_id, cashier_user_id, status, opening_amount, expected_cash_amount, created_by, updated_by
     )
     VALUES (
       'c3000000-0000-0000-0000-000000000001',
       'c1000000-0000-0000-0000-000000000001',
       'c1111111-1111-1111-1111-111111111111',
       'caaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
       'open', 100.00, 100.00,
       'cbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
       'cbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
     ) $$,
  'cash_sessions: valid open session insert succeeds'
);

SELECT lives_ok(
  $$ INSERT INTO public.cash_movements (
       id, company_id, branch_id, cash_session_id, movement_type, amount, reason, created_by, updated_by
     )
     VALUES (
       'c4000000-0000-0000-0000-000000000001',
       'c1000000-0000-0000-0000-000000000001',
       'c1111111-1111-1111-1111-111111111111',
       'c3000000-0000-0000-0000-000000000001',
       'opening_float', 100.00, 'seed opening',
       'cbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
       'cbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
     ) $$,
  'cash_movements: valid opening ledger row insert succeeds'
);

SELECT throws_ok(
  $$ INSERT INTO public.cash_sessions (company_id, branch_id, cashier_user_id, status, opening_amount, expected_cash_amount)
     VALUES (
       'c1000000-0000-0000-0000-000000000001',
       'c1111111-1111-1111-1111-111111111111',
       'caaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
       'reviewed', 10.00, 10.00
     ) $$,
  NULL,
  NULL,
  'cash_sessions: invalid status is rejected'
);

SELECT throws_ok(
  $$ INSERT INTO public.cash_sessions (company_id, branch_id, cashier_user_id, status, opening_amount, expected_cash_amount)
     VALUES (
       'c1000000-0000-0000-0000-000000000001',
       'c2222222-2222-2222-2222-222222222222',
       'caaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
       'open', 10.00, 10.00
     ) $$,
  NULL,
  NULL,
  'cash_sessions: branch composite FK rejects cross-company branch'
);

SELECT throws_ok(
  $$ INSERT INTO public.cash_sessions (company_id, branch_id, cashier_user_id, status, opening_amount, expected_cash_amount)
     VALUES (
       'c1000000-0000-0000-0000-000000000001',
       'c1111111-1111-1111-1111-111111111111',
       'cccccccc-cccc-cccc-cccc-cccccccccccc',
       'open', 10.00, 10.00
     ) $$,
  NULL,
  NULL,
  'cash_sessions: cashier membership composite FK rejects another-company user'
);

SELECT throws_ok(
  $$ INSERT INTO public.cash_sessions (company_id, branch_id, cashier_user_id, status, opening_amount, expected_cash_amount)
     VALUES (
       'c1000000-0000-0000-0000-000000000001',
       'c1111111-1111-1111-1111-111111111111',
       'caaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
       'open', 25.00, 25.00
     ) $$,
  NULL,
  NULL,
  'cash_sessions: partial unique index rejects duplicate open session for same cashier and branch'
);

SELECT lives_ok(
  $$ INSERT INTO public.cash_sessions (
       id, company_id, branch_id, cashier_user_id, status, opening_amount, expected_cash_amount, closed_at, counted_cash_amount, difference_amount
     )
     VALUES (
       'c3000000-0000-0000-0000-000000000002',
       'c1000000-0000-0000-0000-000000000001',
       'c1111111-1111-1111-1111-111111111111',
       'caaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
       'closed', 40.00, 40.00, now(), 40.00, 0.00
     ) $$,
  'cash_sessions: closed history row in same scope is allowed'
);

SELECT throws_ok(
  $$ INSERT INTO public.cash_movements (company_id, branch_id, cash_session_id, movement_type, amount)
     VALUES (
       'c2000000-0000-0000-0000-000000000002',
       'c2222222-2222-2222-2222-222222222222',
       'c3000000-0000-0000-0000-000000000001',
       'opening_float', 10.00
     ) $$,
  NULL,
  NULL,
  'cash_movements: session composite FK rejects cross-company session reference'
);

SELECT throws_ok(
  $$ INSERT INTO public.cash_movements (company_id, branch_id, cash_session_id, movement_type, amount)
     VALUES (
       'c1000000-0000-0000-0000-000000000001',
       'c1111111-1111-1111-1111-111111111111',
       'c3000000-0000-0000-0000-000000000001',
       'bogus_type', 10.00
     ) $$,
  NULL,
  NULL,
  'cash_movements: invalid movement_type is rejected'
);

SELECT throws_ok(
  $$ DELETE FROM public.cash_sessions WHERE id = 'c3000000-0000-0000-0000-000000000002' $$,
  NULL,
  'cash_sessions uses logical deletion only',
  'cash_sessions: physical delete is blocked by trigger'
);

SELECT throws_ok(
  $$ UPDATE public.cash_movements SET reason = 'edited' WHERE id = 'c4000000-0000-0000-0000-000000000001' $$,
  NULL,
  'cash_movements is append-only',
  'cash_movements: updates are blocked by append-only trigger'
);

SELECT throws_ok(
  $$ DELETE FROM public.cash_movements WHERE id = 'c4000000-0000-0000-0000-000000000001' $$,
  NULL,
  'cash_movements is append-only',
  'cash_movements: deletes are blocked by append-only trigger'
);

SELECT is(
  (SELECT count(*)::INT
   FROM public.cash_sessions
   WHERE company_id = 'c1000000-0000-0000-0000-000000000001'
     AND branch_id = 'c1111111-1111-1111-1111-111111111111'
     AND cashier_user_id = 'caaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
     AND status = 'open'
     AND is_active = TRUE),
  1,
  'cash_sessions: exactly one active open session remains for the cashier and branch'
);

SELECT lives_ok(
  $$ UPDATE public.cash_sessions
     SET is_active = FALSE,
         deleted_at = now(),
         deleted_by = 'cbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
     WHERE id = 'c3000000-0000-0000-0000-000000000002' $$,
  'cash_sessions: logical-delete columns can be updated without physical removal'
);

SELECT * FROM finish();
ROLLBACK;
