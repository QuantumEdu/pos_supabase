# Tasks: Cash Session Domain

## Review Workload Forecast

| Field | Value |
|-------|-------|
| Estimated changed lines | 900-1300 |
| 400-line budget risk | High |
| Chained PRs recommended | Yes |
| Suggested split | PR1 SQL foundation -> PR2 pgTAP hardening -> PR3 shared EF + open/close -> PR4 manual/force-close + Deno tests + verify report |
| Delivery strategy | auto-chain |
| Chain strategy | pending |

Decision needed before apply: Yes
Chained PRs recommended: Yes
Chain strategy: pending
400-line budget risk: High

### Suggested Work Units

| Unit | Goal | Likely PR | Notes |
|------|------|-----------|-------|
| 1 | Create cash schema and RPC foundation | PR 1 | Base slice; enables all later work |
| 2 | Add pgTAP constraints/RLS/RPC coverage | PR 2 | Depends on PR 1; proves SQL contract |
| 3 | Add shared EF handler and open/close functions | PR 3 | Depends on PR 2; first runtime path |
| 4 | Add manual/force-close functions, Deno tests, verify report | PR 4 | Depends on PR 3; closes V1 scope |

## Phase 1: SQL Foundation

- [x] 1.1 Create `supabase/migrations/00008_cash_session_domain.sql` with `cash_sessions`, `cash_movements`, composite FKs, partial unique open-session index, audit/logical-delete columns. Verify with `supabase db reset` and schema inspection for required columns/constraints.
- [x] 1.2 Add RLS, grants, and `SECURITY DEFINER` RPCs `open_cash_session`, `close_cash_session`, `record_cash_movement`, `force_close_cash_session` in the same migration. Verify direct authenticated writes fail while service-role RPC execution remains available.

## Phase 2: Database Test Hardening

- [x] 2.1 Add `supabase/tests/test_cash_session_constraints.sql` for table existence, status checks, composite FK integrity, logical-delete behavior, and one-open-session uniqueness. Verify `supabase test db` passes constraint assertions.
- [x] 2.2 Add `supabase/tests/test_cash_session_rls.sql` for cashier branch/self reads, admin company-wide reads, anon zero-row access, and absence of operational DELETE/UPDATE/INSERT paths. Verify `supabase test db` proves RLS isolation and write denial.
- [x] 2.3 Add `supabase/tests/test_cash_session_rpcs.sql` for open/close totals, append-only ledger behavior, manual movement expected-cash updates, force-close, and duplicate-open rejection. Verify `supabase test db` covers atomic RPC outcomes and controlled failures.

## Phase 3: Shared EF Runtime

- [x] 3.1 Add `supabase/functions/_shared/cash_session_schemas.ts` for open, close, manual movement, and force-close payload validation. Verify invalid amounts, missing IDs, and unsupported movement types fail schema parsing.
- [x] 3.2 Add `supabase/functions/_shared/cash_session_handler.ts` and extend `supabase/functions/_shared/auth.ts` for allowed-role auth (`cashier`, `admin`) plus company checks before RPC calls. Verify handler returns consistent `EFResult` errors for auth, scope, and RPC failures.
- [x] 3.3 Add `supabase/functions/cash-session/open-session/index.ts` and `supabase/functions/cash-session/close-session/index.ts` using the shared handler. Verify each function only orchestrates validation plus the correct RPC invocation.

## Phase 4: Remaining Runtime and Verification

- [ ] 4.1 Add `supabase/functions/cash-session/record-manual-movement/index.ts` and `supabase/functions/cash-session/force-close-session/index.ts` with the same shared contract. Verify cashier/admin boundaries and open-session requirements are enforced end to end.
- [ ] 4.2 Add `supabase/functions/_test/cash_session_ef_test.ts` covering validation failures, duplicate-open rejection, successful open/close totals, rollback/error propagation, manual movement, and force-close orchestration. Verify `deno test supabase/functions/_test/` passes.
- [ ] 4.3 Capture implementation evidence in `openspec/changes/cash-session-domain/verify.md` with `supabase db reset`, `supabase test db`, and `deno test supabase/functions/_test/` results. Verify the report maps passing evidence back to spec requirements RCS1-RCS12.
