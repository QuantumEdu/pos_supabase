# Phase 4 Verify Report: Cash Session Domain (PR4)

## Scope

PR4 / Phase 4 completes the cash-session Edge Function runtime by adding `record-manual-movement` (cashier/admin) and `force-close-session` (admin-only) entrypoints, expands Deno test coverage for all four EF routes, and captures final verification evidence.

## Files Changed

- `supabase/functions/_test/cash_session_ef_test.ts` — extended from 11 to 24 tests covering all 4 cash-session EFs
- `openspec/changes/cash-session-domain/phase4-verify-report.md` — this file

Previously created (PR3):
- `supabase/functions/_shared/cash_session_schemas.ts`
- `supabase/functions/_shared/cash_session_handler.ts`
- `supabase/functions/_shared/auth.ts` (CORS header fix)
- `supabase/functions/cash-session/open-session/index.ts`
- `supabase/functions/cash-session/close-session/index.ts`

Previously created (inline during session):
- `supabase/functions/cash-session/record-manual-movement/index.ts`
- `supabase/functions/cash-session/force-close-session/index.ts`

## Verification Results

### 1. Deno Edge Function tests (cash-session only)

Command:
```bash
deno test --no-check supabase/functions/_test/cash_session_ef_test.ts
```

Result:
- **PASS**
- **24 passed | 0 failed**

Coverage includes:
- Schema validation (open, close, manual-movement, force-close)
- Auth/CORS error propagation (401 + 403 with CORS headers) for all 4 EFs
- Cashier-allowed routes: `open-session`, `close-session`, `record-manual-movement`
- Admin-allowed routes: all 4, including `force-close-session` (admin-only)
- Server-derived `actor_user_id`/`company_id` override across all routes
- Correct RPC name mapping per function
- `movement_type` enum validation (`manual_cash_in` / `manual_cash_out`)
- Positive-amount enforcement for manual movements
- Admin-only role gate for `force-close-session`

### 2. Full Deno fallback suite

Command:
```bash
deno test --no-check supabase/functions/_test/
```

Result:
- **PASS**
- **142 passed | 0 failed**

This confirms the expanded cash-session test file (now 24 tests) integrates cleanly with the full 142-test suite and does not regress any existing tests.

### 3. Database baseline regression suite (pgTAP)

Command:
```bash
npm run test:db
```

Result:
- **PASS**
- **Files=14, Tests=511, Result=PASS**

All 14 pgTAP test files pass including cash-session constraints, RLS, and RPC coverage (511 tests total).

### 4. Build verification (db reset)

Command:
```bash
npx supabase db reset
```

Result:
- **PASS**
- All 8 migrations apply cleanly including `00008_cash_session_domain.sql`
- Seed data loads without errors
- Known NOTICE messages for pre-refactor policy drops are expected and benign

## Spec Requirement Traceability

| Requirement | Evidence | Status |
|-------------|----------|--------|
| RCS1: cash_sessions table exists | pgTAP test_cash_session_constraints.sql | ✅ PASS |
| RCS2: cash_movements table exists | pgTAP test_cash_session_constraints.sql | ✅ PASS |
| RCS3: composite FKs to company+branch | pgTAP test_cash_session_constraints.sql | ✅ PASS |
| RCS4: open_cash_session RPC | pgTAP test_cash_session_rpcs.sql | ✅ PASS |
| RCS5: close_cash_session RPC | pgTAP test_cash_session_rpcs.sql | ✅ PASS |
| RCS6: record_cash_movement RPC | pgTAP test_cash_session_rpcs.sql | ✅ PASS |
| RCS7: force_close_cash_session RPC | pgTAP test_cash_session_rpcs.sql | ✅ PASS |
| RCS8: one open session per branch | pgTAP test_cash_session_constraints.sql | ✅ PASS |
| RCS9: RLS company isolation | pgTAP test_cash_session_rls.sql | ✅ PASS |
| RCS10: open-session EF | Deno test 24/24 | ✅ PASS |
| RCS11: close-session EF | Deno test 24/24 | ✅ PASS |
| RCS12: service_role-only RPC access | pgTAP test_cash_session_rpc.sql | ✅ PASS |

## Known Issues

- Deno verification runs with `--no-check` due to the known typed `npm:@types/node` resolution gap (consistent across all EF test files).
- The `force-close-session` admin-only gate is enforced at the Edge Function auth layer; the SQL RPC provides a secondary enforcement layer.

## Outcome

**Phase 4 complete. All verification evidence collected and passing.**

The full `cash-session-domain` change is implemented across 4 PR slices:
- PR1: SQL foundation (migration `00008`)
- PR2: pgTAP hardening (14 files, 511 tests)
- PR3: Shared EF runtime + open/close EFs
- PR4: record-manual-movement + force-close-session EFs + full Deno coverage + verification

## Next Recommended Step

Archive `cash-session-domain` via `sdd-archive` to:
1. Sync delta specs to main specs
2. Persist final state in the selected artifact store
3. Provide an archive report for the change
