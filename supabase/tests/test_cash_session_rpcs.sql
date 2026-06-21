-- pgTAP: Cash session domain RPC tests
-- Verifies RPC hardening, EF-only EXECUTE grants, and open/close/manual/force-close flows.

BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap;

SELECT plan(21);

INSERT INTO public.companies (id, name, slug)
VALUES
  ('e1000000-0000-0000-0000-000000000001', 'Cash RPC Co A', 'cash-rpc-co-a'),
  ('e2000000-0000-0000-0000-000000000002', 'Cash RPC Co B', 'cash-rpc-co-b');

INSERT INTO public.branches (id, company_id, name, slug)
VALUES
  ('e1111111-1111-1111-1111-111111111111', 'e1000000-0000-0000-0000-000000000001', 'RPC Branch A1', 'rpc-branch-a1'),
  ('e2111111-1111-1111-1111-111111111111', 'e2000000-0000-0000-0000-000000000002', 'RPC Branch B1', 'rpc-branch-b1');

INSERT INTO auth.users (id, email, raw_app_meta_data, raw_user_meta_data)
VALUES
  ('eaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'cash-rpc-admin-a@test.com',
   '{"company_id": "e1000000-0000-0000-0000-000000000001", "role": "admin"}',
   '{"full_name": "Cash RPC Admin A"}'),
  ('ebbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'cash-rpc-cashier-a@test.com',
   '{"company_id": "e1000000-0000-0000-0000-000000000001", "role": "cashier", "branch_id": "e1111111-1111-1111-1111-111111111111"}',
   '{"full_name": "Cash RPC Cashier A"}'),
  ('eccccccc-cccc-cccc-cccc-cccccccccccc', 'cash-rpc-noncashier-a@test.com',
   '{"company_id": "e1000000-0000-0000-0000-000000000001", "role": "admin"}',
   '{"full_name": "Cash RPC Noncashier A"}'),
  ('eddddddd-dddd-dddd-dddd-dddddddddddd', 'cash-rpc-admin-b@test.com',
   '{"company_id": "e2000000-0000-0000-0000-000000000002", "role": "admin"}',
   '{"full_name": "Cash RPC Admin B"}')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.profiles (id, full_name)
VALUES
  ('eaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'Cash RPC Admin A'),
  ('ebbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'Cash RPC Cashier A'),
  ('eccccccc-cccc-cccc-cccc-cccccccccccc', 'Cash RPC Noncashier A'),
  ('eddddddd-dddd-dddd-dddd-dddddddddddd', 'Cash RPC Admin B')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.company_users (user_id, company_id, role)
VALUES
  ('eaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'e1000000-0000-0000-0000-000000000001', 'admin'),
  ('ebbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'e1000000-0000-0000-0000-000000000001', 'cashier'),
  ('eccccccc-cccc-cccc-cccc-cccccccccccc', 'e1000000-0000-0000-0000-000000000001', 'admin'),
  ('eddddddd-dddd-dddd-dddd-dddddddddddd', 'e2000000-0000-0000-0000-000000000002', 'admin')
ON CONFLICT (user_id, company_id) DO NOTHING;

INSERT INTO public.branch_users (user_id, branch_id, company_id)
VALUES
  ('ebbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'e1111111-1111-1111-1111-111111111111', 'e1000000-0000-0000-0000-000000000001')
ON CONFLICT (user_id, branch_id) DO NOTHING;

CREATE OR REPLACE FUNCTION _set_cash_session_rpc_role(p_db_role TEXT)
RETURNS VOID AS $$
BEGIN
  EXECUTE format('SET ROLE %I', p_db_role);
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION _reset_cash_session_rpc_role()
RETURNS VOID AS $$
BEGIN
  RESET ROLE;
END;
$$ LANGUAGE plpgsql;

CREATE TABLE IF NOT EXISTS public._cash_session_rpc_test_results (
  key TEXT PRIMARY KEY,
  payload JSONB,
  session_id UUID,
  movement_id UUID
);
TRUNCATE public._cash_session_rpc_test_results;
GRANT ALL ON public._cash_session_rpc_test_results TO authenticated;
GRANT ALL ON public._cash_session_rpc_test_results TO anon;
GRANT ALL ON public._cash_session_rpc_test_results TO service_role;

SELECT ok(
  (SELECT count(*)::bigint
   FROM pg_proc p
   JOIN pg_namespace n ON p.pronamespace = n.oid
   WHERE n.nspname = 'public'
     AND p.proname IN (
       'open_cash_session',
       'close_cash_session',
       'record_cash_movement',
       'force_close_cash_session'
     )
     AND p.prosecdef = TRUE
     AND p.proconfig IS NOT NULL
     AND '{search_path=public}'::text[] <@ p.proconfig
  ) = 4::bigint,
  'All 4 cash RPCs have SECURITY DEFINER with fixed search_path = public'
);

SELECT ok(
  (SELECT count(*)::bigint
   FROM pg_proc p
   JOIN pg_namespace n ON p.pronamespace = n.oid
   WHERE n.nspname = 'public'
     AND p.proname IN (
       'open_cash_session',
       'close_cash_session',
       'record_cash_movement',
       'force_close_cash_session'
     )
     AND has_function_privilege('authenticated', format('public.%I(jsonb)', p.proname), 'EXECUTE')
  ) = 0::bigint,
  'Authenticated role has no direct EXECUTE on cash RPCs'
);

SELECT ok(
  (SELECT count(*)::bigint
   FROM pg_proc p
   JOIN pg_namespace n ON p.pronamespace = n.oid
   WHERE n.nspname = 'public'
     AND p.proname IN (
       'open_cash_session',
       'close_cash_session',
       'record_cash_movement',
       'force_close_cash_session'
     )
     AND has_function_privilege('anon', format('public.%I(jsonb)', p.proname), 'EXECUTE')
  ) = 0::bigint,
  'Anon role has no EXECUTE on cash RPCs'
);

SELECT ok(
  (SELECT count(*)::bigint
   FROM pg_proc p
   JOIN pg_namespace n ON p.pronamespace = n.oid
   WHERE n.nspname = 'public'
     AND p.proname IN (
       'open_cash_session',
       'close_cash_session',
       'record_cash_movement',
       'force_close_cash_session'
     )
     AND has_function_privilege('service_role', format('public.%I(jsonb)', p.proname), 'EXECUTE')
  ) = 4::bigint,
  'Service_role has EXECUTE on all 4 cash RPCs for EF calls'
);

SELECT _set_cash_session_rpc_role('authenticated');

SELECT throws_ok(
  $$ SELECT public.open_cash_session(
       '{"company_id":"e1000000-0000-0000-0000-000000000001","actor_user_id":"ebbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb","branch_id":"e1111111-1111-1111-1111-111111111111","opening_amount":100.00}'::JSONB
     ) $$,
  '42501',
  'permission denied for function open_cash_session',
  'Authenticated client cannot execute open_cash_session directly'
);

SELECT _reset_cash_session_rpc_role();

SELECT _set_cash_session_rpc_role('service_role');

INSERT INTO public._cash_session_rpc_test_results (key, payload, session_id, movement_id)
SELECT
  'open_self',
  r,
  (r->>'cash_session_id')::UUID,
  (r->>'movement_id')::UUID
FROM public.open_cash_session(
  '{"company_id":"e1000000-0000-0000-0000-000000000001","actor_user_id":"ebbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb","branch_id":"e1111111-1111-1111-1111-111111111111","opening_amount":100.00,"notes":"opening self"}'::JSONB
) AS r;

SELECT ok(
  (SELECT session_id IS NOT NULL FROM public._cash_session_rpc_test_results WHERE key = 'open_self'),
  'open_cash_session succeeds via service_role path'
);

SELECT is(
  (SELECT payload->>'status' FROM public._cash_session_rpc_test_results WHERE key = 'open_self'),
  'open',
  'open_cash_session returns open status'
);

SELECT is(
  (SELECT payload->>'expected_cash_amount' FROM public._cash_session_rpc_test_results WHERE key = 'open_self'),
  '100.00',
  'open_cash_session initializes expected cash from opening amount'
);

SELECT throws_ok(
  $$ SELECT public.open_cash_session(
       '{"company_id":"e1000000-0000-0000-0000-000000000001","actor_user_id":"ebbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb","branch_id":"e1111111-1111-1111-1111-111111111111","opening_amount":25.00}'::JSONB
     ) $$,
  'P0001',
  'An open cash session already exists for this cashier in this branch',
  'open_cash_session rejects duplicate active open session'
);

SELECT _reset_cash_session_rpc_role();

SELECT _set_cash_session_rpc_role('service_role');

SELECT throws_ok(
  $$ SELECT public.open_cash_session(
       '{"company_id":"e1000000-0000-0000-0000-000000000001","actor_user_id":"eaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","branch_id":"e1111111-1111-1111-1111-111111111111","cashier_user_id":"eccccccc-cccc-cccc-cccc-cccccccccccc","opening_amount":50.00}'::JSONB
     ) $$,
  'P0001',
  'cashier_user_id must have cashier role',
  'open_cash_session rejects a non-cashier target user'
);

SELECT _reset_cash_session_rpc_role();

SELECT _set_cash_session_rpc_role('service_role');

INSERT INTO public._cash_session_rpc_test_results (key, payload, session_id)
SELECT
  'close_self',
  r,
  (r->>'cash_session_id')::UUID
FROM public.close_cash_session(
  jsonb_build_object(
    'company_id', 'e1000000-0000-0000-0000-000000000001',
    'actor_user_id', 'ebbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
    'cash_session_id', (SELECT session_id FROM public._cash_session_rpc_test_results WHERE key = 'open_self'),
    'counted_cash_amount', 110.50,
    'notes', 'close self'
  )
) AS r;

SELECT is(
  (SELECT payload->>'status' FROM public._cash_session_rpc_test_results WHERE key = 'close_self'),
  'closed',
  'close_cash_session returns closed status'
);

SELECT is(
  (SELECT payload->>'difference_amount' FROM public._cash_session_rpc_test_results WHERE key = 'close_self'),
  '10.50',
  'close_cash_session stores counted minus expected difference'
);

SELECT throws_ok(
  format(
    'SELECT public.close_cash_session(''{"company_id":"e1000000-0000-0000-0000-000000000001","actor_user_id":"ebbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb","cash_session_id":"%s","counted_cash_amount":111.00}''::JSONB)',
    (SELECT session_id FROM public._cash_session_rpc_test_results WHERE key = 'open_self')
  ),
  'P0001',
  'Cash session is not open',
  'close_cash_session rejects already-closed sessions'
);

INSERT INTO public._cash_session_rpc_test_results (key, payload, session_id, movement_id)
SELECT
  'open_for_movement',
  r,
  (r->>'cash_session_id')::UUID,
  (r->>'movement_id')::UUID
FROM public.open_cash_session(
  '{"company_id":"e1000000-0000-0000-0000-000000000001","actor_user_id":"ebbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb","branch_id":"e1111111-1111-1111-1111-111111111111","opening_amount":50.00,"notes":"movement session"}'::JSONB
) AS r;

SELECT ok(
  (SELECT session_id IS NOT NULL FROM public._cash_session_rpc_test_results WHERE key = 'open_for_movement'),
  'A new session can open after the prior one closes'
);

INSERT INTO public._cash_session_rpc_test_results (key, payload, session_id, movement_id)
SELECT
  'manual_in',
  r,
  (r->>'cash_session_id')::UUID,
  (r->>'movement_id')::UUID
FROM public.record_cash_movement(
  jsonb_build_object(
    'company_id', 'e1000000-0000-0000-0000-000000000001',
    'actor_user_id', 'ebbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
    'cash_session_id', (SELECT session_id FROM public._cash_session_rpc_test_results WHERE key = 'open_for_movement'),
    'movement_type', 'manual_cash_in',
    'amount', 20.00,
    'reason', 'petty cash return'
  )
) AS r;

SELECT is(
  (SELECT payload->>'expected_cash_amount' FROM public._cash_session_rpc_test_results WHERE key = 'manual_in'),
  '70.00',
  'record_cash_movement updates expected cash atomically'
);

SELECT is(
  (SELECT count(*)::INT
   FROM public.cash_movements
   WHERE cash_session_id = (SELECT session_id FROM public._cash_session_rpc_test_results WHERE key = 'open_for_movement')),
  2,
  'record_cash_movement appends exactly one additional ledger row'
);

SELECT throws_ok(
  format(
    'SELECT public.force_close_cash_session(''{"company_id":"e1000000-0000-0000-0000-000000000001","actor_user_id":"ebbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb","cash_session_id":"%s","counted_cash_amount":70.00,"reason":"cashier attempt"}''::JSONB)',
    (SELECT session_id FROM public._cash_session_rpc_test_results WHERE key = 'open_for_movement')
  ),
  'P0001',
  'Only admins can force-close cash sessions',
  'force_close_cash_session is admin-only even on the service_role path'
);

SELECT _reset_cash_session_rpc_role();

SELECT _set_cash_session_rpc_role('service_role');

SELECT throws_ok(
  format(
    'SELECT public.record_cash_movement(''{"company_id":"e1000000-0000-0000-0000-000000000001","actor_user_id":"eaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","cash_session_id":"%s","movement_type":"manual_cash_in","amount":5.00}''::JSONB)',
    (SELECT session_id FROM public._cash_session_rpc_test_results WHERE key = 'open_for_movement')
  ),
  'P0001',
  'Admin cash movements for another cashier require a reason',
  'record_cash_movement requires reason when admin acts on another cashier session'
);

INSERT INTO public._cash_session_rpc_test_results (key, payload, session_id)
SELECT
  'force_close_admin',
  r,
  (r->>'cash_session_id')::UUID
FROM public.force_close_cash_session(
  jsonb_build_object(
    'company_id', 'e1000000-0000-0000-0000-000000000001',
    'actor_user_id', 'eaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    'cash_session_id', (SELECT session_id FROM public._cash_session_rpc_test_results WHERE key = 'open_for_movement'),
    'counted_cash_amount', 85.00,
    'reason', 'admin force close'
  )
) AS r;

SELECT is(
  (SELECT payload->>'status' FROM public._cash_session_rpc_test_results WHERE key = 'force_close_admin'),
  'closed',
  'force_close_cash_session closes the target session'
);

SELECT is(
  (SELECT payload->>'forced' FROM public._cash_session_rpc_test_results WHERE key = 'force_close_admin'),
  'true',
  'force_close_cash_session marks the response as forced'
);

SELECT is(
  (SELECT payload->>'difference_amount' FROM public._cash_session_rpc_test_results WHERE key = 'force_close_admin'),
  '15.00',
  'force_close_cash_session persists the expected difference'
);

SELECT _reset_cash_session_rpc_role();

DROP FUNCTION _set_cash_session_rpc_role(TEXT);
DROP FUNCTION _reset_cash_session_rpc_role();

SELECT * FROM finish();
ROLLBACK;
