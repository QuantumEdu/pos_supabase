# Tasks: Credit Payments Domain

## Review Workload Forecast

| Field | Value |
|-------|-------|
| Estimated changed lines | 770+ (migration ~250, EF/schema ~150, pgTAP ~250, Deno ~120) |
| 400-line budget risk | High |
| Chained PRs recommended | Yes |
| Suggested split | PR1 (SQL foundation + pgTAP) → PR2 (Edge Function + Deno tests) |
| Delivery strategy | force-chained |
| Chain strategy | feature-branch-chain |

Decision needed before apply: No
Chained PRs recommended: Yes
Chain strategy: feature-branch-chain
400-line budget risk: High

### Suggested Work Units

| Unit | Goal | Likely PR | Notes |
|------|------|-----------|-------|
| 1 | SQL foundation: tables, triggers, RPC, RLS, grants + all pgTAP tests | PR 1 | Base: feature/credit-payments-domain tracker branch |
| 2 | Edge Function: schemas, handler, entry point + Deno test | PR 2 | Base: PR 1 branch; depends on PR 1 RPC |

## Phase 1: SQL Foundation (PR 1)

- [x] 1.1 Create `supabase/migrations/00010_credit_payments_domain.sql` — `customer_balances` + `customer_payments` tables with all columns, CHECKs, composite FK `(company_id, sale_id)→sales(company_id, id)`, UNIQUE `(company_id, sale_id)`, generated column `remaining_amount`, audit + soft-delete columns. Verify: migration applies cleanly via `supabase db reset` ✅
- [x] 1.2 Create `trg_seed_customer_balance` — AFTER INSERT trigger on `payments` WHERE `payment_method='credit'`: seeds `customer_balances` row with `ON CONFLICT (company_id, sale_id) DO UPDATE` aggregation. Verify: insert credit payment → balance row created; insert non-credit → no row ✅
- [x] 1.3 Create `trg_cancel_customer_balance` — AFTER UPDATE trigger on `sales` WHERE `status→'cancelled'`: sets `customer_balances.status='cancelled'` unconditionally. Verify: cancel sale → linked balance transitions to 'cancelled' ✅
- [x] 1.4 Create `register_customer_payment_transaction()` — SECURITY DEFINER RPC with `SELECT ... FOR UPDATE` lock on `customer_balances`, validates abono (positive, ≤ remaining, active/partial status), inserts `customer_payments`, updates `paid_amount` + status. Verify: happy path inserts payment + updates balance; overpayment rejected; paid/cancelled rejected ✅
- [x] 1.5 Create RLS policies + grants — `customer_balances` and `customer_payments`: company-scoped SELECT for authenticated, admin-only INSERT/UPDATE, no DELETE, service_role bypass. Verify: cross-company rows invisible to non-admin; admin can write; unauthenticated sees zero rows ✅
- [x] 1.6 Create `supabase/tests/test_credit_payments_constraints.sql` — pgTAP: column presence, NOT NULL, CHECK constraints (`total_amount > 0`, `paid_amount >= 0`, `remaining_amount >= 0`, status IN enum), UNIQUE `(company_id, sale_id)`, composite FK `(company_id, sale_id)`, generated column correctness. Verify: `supabase test db` all pass ✅ (39 tests)
- [x] 1.7 Create `supabase/tests/test_credit_payments_rpcs.sql` — pgTAP: seed trigger fires on credit payment only; aggregates multiple credits into one balance; no seed on non-credit; cancel trigger transitions status; abono RPC happy path (pending→partial→paid); overpayment rejection; paid/cancelled rejection; amount≤0 rejection; FOR UPDATE serialization. Verify: `supabase test db` all pass ✅ (22 tests)
- [x] 1.8 Create `supabase/tests/test_credit_payments_rls.sql` — pgTAP: company-scoped SELECT, admin INSERT/UPDATE, cross-company invisible, unauthenticated zero rows, no DELETE policy. Verify: `supabase test db` all pass ✅ (10 tests)

## Phase 2: Edge Function + Deno Tests (PR 2)

- [x] 2.1 Create `supabase/functions/_shared/credit_payment_schemas.ts` — Zod schemas `RegisterCustomerPaymentRequest` and TypeScript types `RegisterCustomerPaymentResult` matching RPC contract. Verify: `deno check` passes; schema rejects invalid input ✅
- [x] 2.2 Create `supabase/functions/_shared/credit_payment_handler.ts` — Shared handler following cash-session pattern: `validateAuth` → role check (admin) → Zod parse → inject `actor_user_id`/`company_id` → `serviceRole.rpc('register_customer_payment_transaction', {...})` → return EFResult. Verify: handler returns correct structure for valid/invalid inputs ✅
- [x] 2.3 Create `supabase/functions/register-payment/index.ts` — 8-step critical-op EF entry point: CORS preflight → `validateAuth` → role check → Zod parse → inject IDs → RPC invoke → (audit placeholder) → return EFResult. Verify: `deno check` passes; EF responds to preflight ✅
- [x] 2.4 Create `supabase/functions/_test/credit_payment_ef_test.ts` — Deno test: 8-step EF validation covering authenticated admin success, unauthenticated rejection (step 1), non-admin rejection (step 4), invalid input rejection (step 5), RPC invocation with correct payload. Verify: `deno test` all pass ✅ (18 tests)