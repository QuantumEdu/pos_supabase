# Phase 2 Verify Report: Cash Session Domain

## Scope

PR 2 / Phase 2 only: SQL hardening adjustments plus pgTAP coverage for constraints, RLS, and RPCs.

## Files Verified

- `supabase/migrations/00008_cash_session_domain.sql`
- `supabase/tests/test_cash_session_constraints.sql`
- `supabase/tests/test_cash_session_rls.sql`
- `supabase/tests/test_cash_session_rpcs.sql`
- `openspec/changes/cash-session-domain/tasks.md`
- `openspec/changes/cash-session-domain/design.md`

## Commands

```bash
npm run db:reset
npm run test:db
npx supabase test db --debug
```

## Results

- `npm run db:reset` passed after the service-role actor-context fix.
- The first `npm run test:db` attempt hit the known transient Supabase CLI `unexpected EOF` connection failure.
- `npx supabase test db --debug` then passed with all suites green: `Files=14, Tests=511, Result: PASS`.
- Final retry with plain `npm run test:db` also passed: `Files=14, Tests=511, Result: PASS`.

## Verified Behaviors

- Cash RPC EXECUTE is hardened to the EF boundary:
  - `authenticated`, `anon`, and `PUBLIC` do not have direct EXECUTE on cash RPCs.
  - `service_role` retains EXECUTE for Edge Function mediated calls.
- Cash RPC authorization no longer depends on DB-session JWT context for write paths:
  - service-role cash RPCs require `actor_user_id` in `p JSONB`
  - actor company membership and role are derived from `company_users`
  - branch assignment and target cashier validation remain table-driven
  - audit columns use explicit actor identity instead of `auth.uid()`
- `open_cash_session` rejects `cashier_user_id` values that are active company members but do not have the `cashier` role.
- Constraint coverage now proves:
  - valid session and opening movement inserts
  - session status checks
  - composite FK integrity for branch, cashier membership, and session ownership
  - one-open-session uniqueness per company/branch/cashier
  - logical-delete protection on `cash_sessions`
  - append-only protection on `cash_movements`
- RLS coverage now proves:
  - admin company-wide reads
  - cashier self/branch-scoped reads
  - anon zero-row access
  - direct authenticated `INSERT` / `UPDATE` / `DELETE` denial
  - `service_role` read bypass expectations
- RPC coverage now proves:
  - successful open and close flows
  - duplicate open rejection
  - non-cashier target rejection
  - difference calculation on close
  - close already-closed rejection
  - manual movement expected-cash updates with appended ledger rows
  - admin movement-on-behalf requires a reason
  - admin-only force close
  - direct authenticated EXECUTE denial
  - `service_role` EXECUTE success path without JWT-claim session setup

## Notes

- The design doc now explicitly states that service-role cash RPCs must receive explicit actor context from the Edge Function payload and validate that actor through membership tables.
- No Edge Functions were added in this phase; this PR only prepares and proves the database contract for Phase 3.

## Outcome

Phase 2 verification passed. PR 3 can proceed on a runtime-feasible SQL baseline without implementing Edge Functions in this PR.
