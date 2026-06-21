# Verification Report: credit-payments-domain

**Change**: credit-payments-domain
**Version**: N/A (initial implementation)
**Mode**: Standard (strict_tdd = false)
**Date**: 2026-06-20

---

## Completeness

| Metric | Value |
|--------|-------|
| Tasks total | 12 |
| Tasks complete | 12 |
| Tasks incomplete | 0 |

All 12 tasks (8 Phase 1 + 4 Phase 2) are marked [x] in tasks.md. No incomplete tasks.

---

## Build & Tests Execution

### pgTAP Tests (SQL)

```
$ npx supabase test db
All tests successful.
Files=20, Tests=623, 3 wallclock secs
Result: PASS
```

Credit-payments-specific breakdown:
- `test_credit_payments_constraints.sql` — 39 tests ✅
- `test_credit_payments_rpcs.sql` — 22 tests ✅
- `test_credit_payments_rls.sql` — 10 tests ✅

### Deno Tests (Edge Function)

```
$ deno test --no-check --allow-all supabase/functions/_test/credit_payment_ef_test.ts
18 passed | 0 failed (44ms)
Result: PASS
```

### Build / Type Check

Not applicable (Supabase SQL migrations + Deno Edge Function; no separate build step).
`deno check` is known to produce `Request`/`Response` global type errors from `npm:@types/node` conflict — this is a pre-existing project-wide issue, not specific to this change. Verification via `deno test --no-check` is the project standard.

### Coverage

➖ Not available (Supabase pgTAP + Deno; no coverage tooling configured)

---

## Spec Compliance Matrix

| Requirement | Scenario | Test | Result |
|-------------|----------|------|--------|
| **RCP1: Customer Balances Schema** | Migration 00010 applied → table exists with CHECK, unique, composite FK constraints | `test_credit_payments_constraints.sql` > has_table, has_column, col_not_null, throws_ok (CHECKs) | ✅ COMPLIANT |
| RCP1 | Two balance rows for same (company_id, sale_id) → UNIQUE rejects | `test_credit_payments_constraints.sql` > "UNIQUE (company_id, sale_id) rejects second balance for same sale" | ✅ COMPLIANT |
| RCP1 | status='foo' → CHECK rejects | `test_credit_payments_constraints.sql` > "status CHECK rejects invalid enum value" | ✅ COMPLIANT |
| RCP1 | total_amount=0 or negative → CHECK rejects | `test_credit_payments_constraints.sql` > "total_amount CHECK rejects zero" + "rejects negative" | ✅ COMPLIANT |
| RCP1 | paid_amount negative → CHECK rejects | `test_credit_payments_constraints.sql` > "paid_amount CHECK rejects negative" | ✅ COMPLIANT |
| RCP1 | remaining_amount generated correctly (total - paid) | `test_credit_payments_constraints.sql` > "remaining_amount is generated (100 - 30 = 70)" + "default remaining = total" | ✅ COMPLIANT |
| RCP1 | Composite FK (company_id, sale_id)→sales | `test_credit_payments_constraints.sql` > "composite FK rejects unknown sale" | ✅ COMPLIANT |
| RCP1 | Composite FK (company_id, customer_id)→customers | `test_credit_payments_constraints.sql` > "composite FK rejects unknown customer" | ✅ COMPLIANT |
| RCP1 | customer_payments payment_method excludes 'credit' | `test_credit_payments_constraints.sql` > "payment_method CHECK rejects credit" | ✅ COMPLIANT |
| RCP1 | customer_payments amount > 0 | `test_credit_payments_constraints.sql` > "amount CHECK rejects zero" | ✅ COMPLIANT |
| RCP1 | customer_payments composite FK (company_id, balance_id) | `test_credit_payments_constraints.sql` > "composite FK rejects unknown balance" | ✅ COMPLIANT |
| RCP1 | Append-only: no UPDATE on customer_payments | `test_credit_payments_constraints.sql` > "direct UPDATE is rejected (append-only)" | ✅ COMPLIANT |
| RCP1 | No physical DELETE on either table | `test_credit_payments_constraints.sql` > "physical DELETE is rejected" × 2 | ✅ COMPLIANT |
| **RCP2: Seed Trigger** | Credit payment inserted → balance row created with total=credit amount, status='pending' | `test_credit_payments_rpcs.sql` > "one credit payment seeds exactly one customer_balances row" + "seeded balance starts in pending status" + "total_amount equals credit payment amount" + "remaining_amount equals total_amount" + "customer_id comes from sale" | ✅ COMPLIANT |
| RCP2 | Two credit payments for one sale → ONE balance (aggregated) | `test_credit_payments_rpcs.sql` > "two credit payments converge into one balance row" + "aggregated total = 60+25=85" | ✅ COMPLIANT |
| RCP2 | Non-credit payment → no balance row | `test_credit_payments_rpcs.sql` > "non-credit payment does not seed a balance" | ✅ COMPLIANT |
| **RCP3: Cancellation Trigger** | Sale cancelled → linked balance transitions to 'cancelled' | `test_credit_payments_rpcs.sql` > "cancelling a sale transitions linked balance to cancelled" | ✅ COMPLIANT |
| RCP3 | Balance already 'paid' → sale cancelled → balance transitions to 'cancelled' | ⚠️ Not explicitly tested for 'paid'→'cancelled' (only 'pending'→'cancelled' is tested). The trigger's `status NOT IN ('cancelled')` condition means it WILL transition 'paid'→'cancelled'. Partial coverage. | ⚠️ PARTIAL |
| **RCP4: RPC Happy Path** | Abono on pending → partial status | `test_credit_payments_rpcs.sql` > "first abono (pending→partial) returns success" + "balance is partial after partial abono" | ✅ COMPLIANT |
| RCP4 | Abono reaches total → paid status, remaining=0 | `test_credit_payments_rpcs.sql` > "second abono (partial→paid) returns success" + "balance is paid once abonos sum to total" + "remaining_amount is 0 once fully paid" | ✅ COMPLIANT |
| RCP4 | Two sequential abonos (exercise FOR UPDATE code path) | `test_credit_payments_rpcs.sql` > sequential abono tests on same balance_id (pending→partial→paid); no cross-session concurrency test (noted as pgTAP limitation) | ✅ COMPLIANT |
| **RCP5: Abono Validation** | Overpayment (amount > remaining) → rejected, no row created | `test_credit_payments_rpcs.sql` > "overpayment is rejected" + "overpayment rejection creates no customer_payments row" | ✅ COMPLIANT |
| RCP5 | Paid balance → abono rejected | `test_credit_payments_rpcs.sql` > "abono against a paid balance is rejected" | ✅ COMPLIANT |
| RCP5 | Cancelled balance → abono rejected | `test_credit_payments_rpcs.sql` > "abono against a cancelled balance is rejected" | ✅ COMPLIANT |
| RCP5 | Amount ≤ 0 → rejected | `test_credit_payments_rpcs.sql` > "zero-amount abono is rejected" + "negative-amount abono is rejected" | ✅ COMPLIANT |
| RCP5 | Invalid payment_method → rejected | `test_credit_payments_rpcs.sql` > "credit payment_method for abono is rejected" | ✅ COMPLIANT |
| RCP5 | Unknown balance_id → NOT_FOUND | `test_credit_payments_rpcs.sql` > "unknown balance_id returns failure (NOT_FOUND)" | ✅ COMPLIANT |
| **RCP6: Row-Level Security** | Authenticated user → own-company SELECT | `test_credit_payments_rls.sql` > "admin A sees only company A balances/payments" + "admin B sees only company B balances" | ✅ COMPLIANT |
| RCP6 | Cross-company rows invisible | `test_credit_payments_rls.sql` > "admin B sees only company B balances (cross-company invisible)" | ✅ COMPLIANT |
| RCP6 | Unauthenticated → zero rows | `test_credit_payments_rls.sql` > "anon sees 0 customer_balances/payments" | ✅ COMPLIANT |
| RCP6 | Admin → INSERT/UPDATE succeeds | `test_credit_payments_rls.sql` > "admin can INSERT a balance (is_admin policy + grant)" | ✅ COMPLIANT |
| RCP6 | service_role → RLS bypassed | `test_credit_payments_rls.sql` > "service_role bypasses RLS (sees all 3 balances)" | ✅ COMPLIANT |
| RCP6 | No DELETE (logical deletion only) | `test_credit_payments_rls.sql` > "DELETE is denied (no DELETE grant)" + constraints file also tests triggers | ✅ COMPLIANT |
| RCP6 | Non-admin INSERT denied | `test_credit_payments_rls.sql` > "non-admin authenticated INSERT is denied (is_admin policy fails)" | ✅ COMPLIANT |
| **RCP7: Edge Function** | Authenticated admin → EF validates role/input → invokes RPC → returns result | `credit_payment_ef_test.ts` > "admin role is allowed" + "correct RPC name and server-derived payload" | ✅ COMPLIANT |
| RCP7 | Unauthenticated → rejected at step 1 | `credit_payment_ef_test.ts` > "unauthenticated request rejected at step 2" | ✅ COMPLIANT |
| RCP7 | Non-admin → rejected at role step | `credit_payment_ef_test.ts` > "non-admin role rejected at step 4 (FORBIDDEN)" + "cashier role is rejected (admin-only)" | ✅ COMPLIANT |
| RCP7 | Zod validation rejects invalid input | `credit_payment_ef_test.ts` > "invalid input rejected at step 5 (Zod)" + 9 Zod schema tests | ✅ COMPLIANT |
| RCP7 | CORS preflight → 200 | `credit_payment_ef_test.ts` > "CORS preflight returns 200" | ✅ COMPLIANT |
| RCP7 | Spoofed auth fields (actor_user_id, company_id) stripped | `credit_payment_ef_test.ts` > "valid input passes and strips spoofed auth fields" + "correct RPC payload uses server-derived IDs" | ✅ COMPLIANT |
| **RCP8: Test Coverage** | pgTAP: all tests pass | `supabase test db` → 623 tests, 0 failures | ✅ COMPLIANT |
| RCP8 | Deno: all EF tests pass | `deno test` → 18 passed, 0 failed | ✅ COMPLIANT |

**Compliance summary**: 35/36 scenarios compliant (1 ⚠️ PARTIAL — RCP3 'paid→cancelled' transition not explicitly tested)

---

## Correctness (Static — Structural Evidence)

| Requirement | Status | Notes |
|------------|--------|-------|
| RCP1: customer_balances table | ✅ Implemented | All columns, CHECKs, UNIQUE, composite FKs, generated column present in migration |
| RCP1: customer_payments table | ✅ Implemented | All columns, CHECKs (amount > 0, payment_method IN cash/card/transfer), append-only triggers |
| RCP2: Seed trigger | ✅ Implemented | `trg_seed_customer_balance` AFTER INSERT on payments, fires on credit only, ON CONFLICT DO UPDATE aggregates |
| RCP3: Cancellation trigger | ✅ Implemented | `trg_cancel_customer_balance` AFTER UPDATE on sales, transitions to cancelled |
| RCP4: RPC with FOR UPDATE | ✅ Implemented | `register_customer_payment_transaction()` SECURITY DEFINER, SELECT...FOR UPDATE, status transitions |
| RCP5: Abono validation | ✅ Implemented | Validates positive amount, ≤ remaining, active status, payment_method enum |
| RCP6: RLS policies | ✅ Implemented | company-scoped SELECT, admin INSERT/UPDATE, service_role ALL, no DELETE grant |
| RCP7: Edge Function | ✅ Implemented | register-payment/index.ts → credit_payment_handler.ts → handleCashSessionRpc with admin role |

---

## Coherence (Design)

| Decision | Followed? | Notes |
|----------|-----------|-------|
| D1: Generated column for remaining_amount | ✅ Yes | `GENERATED ALWAYS AS (total_amount - paid_amount) STORED` in migration |
| D2: Trigger-seeded from payments (not sales) | ✅ Yes | `trg_seed_customer_balance` on payments INSERT WHERE `payment_method='credit'` with ON CONFLICT aggregation |
| D3: Cancel unconditionally (V1) | ✅ Yes | Trigger sets `status='cancelled'` regardless of current status (except already cancelled) |
| D4: FOR UPDATE lock in abono RPC | ✅ Yes | `SELECT ... FOR UPDATE` in `register_customer_payment_transaction()` |
| D5: EF follows critical-op pattern | ✅ Yes | Handler delegates to `handleCashSessionRpc` with `["admin"]` role array, matching cash-session pattern |

File changes match the design table:
- ✅ `supabase/migrations/00010_credit_payments_domain.sql` — created (462 lines)
- ✅ `supabase/functions/_shared/credit_payment_handler.ts` — created (38 lines)
- ✅ `supabase/functions/_shared/credit_payment_schemas.ts` — created (28 lines)
- ✅ `supabase/functions/register-payment/index.ts` — created (13 lines)
- ✅ `supabase/tests/test_credit_payments_constraints.sql` — created (387 lines)
- ✅ `supabase/tests/test_credit_payments_rpcs.sql` — created (382 lines)
- ✅ `supabase/tests/test_credit_payments_rls.sql` — created (251 lines)
- ✅ `supabase/functions/_test/credit_payment_ef_test.ts` — created (376 lines)

Minor design deviation (non-blocking): The API design in design.md showed a simplified `RegisterCustomerPaymentResult` type with 4 fields (`payment_id`, `balance_id`, `amount_paid`, `new_status`), but the actual implementation returns 6 fields (`payment_id`, `balance_id`, `amount_paid`, `new_paid_amount`, `new_remaining_amount`, `new_status`). This is an improvement — more informative response. The Zod schema type and EF test both match the actual RPC output.

---

## Issues Found

**CRITICAL** (must fix before archive):
None

**WARNING** (should fix):
1. ⚠️ RCP3 scenario "balance already 'paid' → sale cancelled → transitions to 'cancelled'" is not explicitly tested. The trigger logic covers it (WHERE status NOT IN ('cancelled')), and the 'paid'→'cancelled' path is implicit in the trigger's unconditional UPDATE. But no pgTAP test specifically sets a balance to 'paid' status then cancels the sale and verifies 'cancelled'. Consider adding a test case to close this gap.

**SUGGESTION** (nice to have):
1. The RPC concurrency scenario (RCP4: "two concurrent abonos serialized by FOR UPDATE") cannot be tested in a single pgTAP session. The test file acknowledges this (lines 6-9) and tests two sequential abonos instead. True cross-session concurrency testing would require a different test framework or manual verification. This is acceptable for V1.
2. The `anon` role has `SELECT` grants on both `customer_balances` and `customer_payments`, but the RLS policy only has `TO authenticated` for SELECT. The `anon` role will see zero rows due to RLS. This matches RCP6 spec ("unauthenticated → zero rows") but the separate `GRANT SELECT ... TO anon` is redundant given RLS already blocks. Not a bug, just redundant grant.

---

## Verdict

**PASS WITH WARNINGS**

12/12 tasks complete. All 623 pgTAP tests pass; all 18 Deno tests pass. 35/36 spec scenarios are fully compliant. One partial scenario (RCP3 'paid→cancelled' transition) lacks explicit test coverage — the implementation is correct but the test gap should be addressed in a follow-up. No CRITICAL issues found. Implementation matches design decisions D1–D5 fully.