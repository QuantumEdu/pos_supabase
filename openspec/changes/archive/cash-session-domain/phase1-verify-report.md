# Phase 1 Verify Report: Cash Session Domain

## Scope

PR 1 / Phase 1 only: SQL foundation for `cash-session-domain`.

## Files Verified

- `supabase/migrations/00008_cash_session_domain.sql`

## Commands

```bash
npm run db:reset
docker exec supabase_db_Pos_supabase psql -U postgres -d postgres \
  -c "SELECT table_name FROM information_schema.tables WHERE table_schema = 'public' AND table_name IN ('cash_sessions','cash_movements') ORDER BY table_name;" \
  -c "SELECT indexname, indexdef FROM pg_indexes WHERE schemaname = 'public' AND tablename = 'cash_sessions' AND indexname = 'idx_cash_sessions_one_open_per_cashier_branch';" \
  -c "SELECT conname FROM pg_constraint WHERE conname IN ('fk_cash_sessions_branch_same_company','fk_cash_sessions_cashier_company_membership','fk_cash_movements_branch_same_company','fk_cash_movements_session_same_company') ORDER BY conname;" \
  -c "SELECT routine_name FROM information_schema.routines WHERE routine_schema = 'public' AND routine_name IN ('open_cash_session','close_cash_session','record_cash_movement','force_close_cash_session') ORDER BY routine_name;"
docker exec supabase_db_Pos_supabase psql -U postgres -d postgres \
  -c "SELECT tablename, policyname, roles, cmd FROM pg_policies WHERE schemaname = 'public' AND tablename IN ('cash_sessions','cash_movements') ORDER BY tablename, policyname;" \
  -c "SELECT routine_name, security_type FROM information_schema.routines WHERE routine_schema = 'public' AND routine_name IN ('open_cash_session','close_cash_session','record_cash_movement','force_close_cash_session') ORDER BY routine_name;"
docker exec supabase_db_Pos_supabase psql -U postgres -d postgres -v ON_ERROR_STOP=0 \
  -c "SET ROLE authenticated; INSERT INTO public.cash_sessions (company_id, branch_id, cashier_user_id, status, opened_at, opening_amount, expected_cash_amount) VALUES (gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), 'open', now(), 0, 0);"
```

## Results

- `npm run db:reset` passed; migration `00008_cash_session_domain.sql` applied cleanly.
- Schema inspection confirmed both tables exist: `cash_sessions`, `cash_movements`.
- Required partial unique index exists: `idx_cash_sessions_one_open_per_cashier_branch` on `(company_id, branch_id, cashier_user_id)` with `WHERE status = 'open' AND is_active = true`.
- Required composite foreign keys exist:
  - `fk_cash_sessions_branch_same_company`
  - `fk_cash_sessions_cashier_company_membership`
  - `fk_cash_movements_branch_same_company`
  - `fk_cash_movements_session_same_company`
- Required RPCs exist and are `SECURITY DEFINER`:
  - `open_cash_session`
  - `close_cash_session`
  - `record_cash_movement`
  - `force_close_cash_session`
- RLS policies exist for authenticated reads and service-role full access on both tables.
- Direct authenticated insert into `cash_sessions` failed with `permission denied for table cash_sessions`, confirming the write boundary is closed for client writes in this slice.

## Notes

- No pgTAP files were added in Phase 1 by design; `npx supabase test db --debug` was intentionally deferred to Phase 2.
- Cashier ownership FK was implemented safely via `cash_sessions(company_id, cashier_user_id) -> company_users(company_id, user_id)` after adding `idx_company_users_company_id_user_id`. This avoids changing existing membership semantics while preserving same-company ownership integrity.

## Outcome

Phase 1 verification passed. PR 2 can proceed on top of this SQL foundation.
