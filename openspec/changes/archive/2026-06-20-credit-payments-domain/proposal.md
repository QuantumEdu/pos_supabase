# Proposal: Credit Payments Domain

## Intent

MVP requires abono (partial payment) tracking and customer balance visibility. When a sale is paid on credit, the business needs to know who owes what and record payments toward it. Without this domain, credit sales create `payments` rows but no mechanism tracks the resulting debt or its repayment. This is change #8 in the roadmap and depends on completed customers-demand (#5) and pos-sales PR1+PR2 (#6).

## Scope

### In Scope
- `customer_balances` table: company-scoped, sale-linked, status lifecycle (pending → partial → paid → cancelled), total_amount, paid_amount, remaining_amount
- `customer_payments` table: company-scoped, abono records linked to `customer_balances`, amount, payment_method, reference
- AFTER INSERT trigger on `payments` WHERE `payment_method='credit'`: seeds `customer_balances` row atomically with the sale transaction
- AFTER UPDATE trigger on `sales` WHERE status → 'cancelled': transitions balance to 'cancelled'
- `register_customer_payment_transaction()` SECURITY DEFINER RPC: validates abono, inserts `customer_payments`, updates `customer_balances` with `FOR UPDATE` row lock
- `register-payment` Edge Function: auth → role validation → RPC invocation
- RLS policies: company-scoped, admin write, all authenticated read
- pgTAP tests + Deno tests
- Migration 00010

### Out of Scope
- Credit limits per customer (future column on `customers`)
- Installment scheduling / payment plans
- Detailed account statements / credit report view
- Overpayment handling (abono exceeding remaining_amount — rejected in V1)
- Sale cancellation reversing partial abonos (V2)
- pos-sales Edge Functions (PR3+PR4 — separate delivery)

## Capabilities

### New Capabilities
- `credit-payments-domain`: Customer balance seeding, abono processing, and credit payment lifecycle — tables, triggers, RPC, EF, RLS, and tests

### Modified Capabilities
- `project-architecture`: R11 #2 resolved from "Unresolved" to "Resolved: trigger-seeded, RPC-maintained table"

## Approach

**Trigger-seeded, RPC-maintained `customer_balances`** (resolves R11 #2). An AFTER INSERT trigger on `payments` WHERE `payment_method='credit'` creates the balance row atomically in the same transaction as the sale. This is integration code belonging to credit-payments — pos-sales remains unaware of it. The `register_customer_payment_transaction()` RPC handles abono insertion and balance updates with `FOR UPDATE` locking to prevent concurrent-abono race conditions. A trigger on `sales` AFTER UPDATE (status → 'cancelled') transitions the balance to 'cancelled'. The `register-payment` Edge Function follows the project's 8-step critical-op pattern (R2).

## Affected Areas

| Area | Impact | Description |
|------|--------|-------------|
| `supabase/migrations/00010_credit_payments_domain.sql` | New | Tables, triggers, RPC, RLS |
| `supabase/migrations/00009_pos_sales_domain.sql` | Modified | New triggers on `payments` and `sales` |
| `supabase/migrations/00007_customers_demand_domain.sql` | Modified | FK target for new tables |
| `supabase/functions/register-payment/` | New | Edge Function for abono registration |
| `openspec/specs/project-architecture/spec.md` | Modified | R11 #2 status update |
| pgTAP + Deno test files | New | Schema, constraints, triggers, RLS, RPC, EF |

## Risks

| Risk | Likelihood | Mitigation |
|------|------------|------------|
| Trigger cross-domain coupling (triggers on pos-sales tables) | Med | Triggers are minimal (seed row, status transition only); all business logic in credit-payments RPC |
| Concurrent abonos race condition | Med | `SELECT ... FOR UPDATE` on `customer_balances` row in RPC transaction |
| Multiple credit payment rows per sale (mixed payment) | Low | Balance row keyed by `(company_id, sale_id)`, not per payment row; trigger aggregates |
| Cancellation cascade when partial abonos exist | Med | V1: trigger transitions balance to 'cancelled' regardless of abono state; reversal of individual abonos deferred to V2 |
| Double-update with `cancel_sale_transaction` | Low | Balance trigger only transitions status; does not re-process amounts |

## Rollback Plan

Migration 00010 can be reversed by dropping the two new tables, the two triggers, the RPC, and the EF. No pos-sales schema objects are modified — triggers on 00009 tables are created by and owned by the 00010 migration, so dropping 00010 removes them cleanly. R11 #2 rollback: revert status from "Resolved" back to "Unresolved" in project-architecture spec.

## Dependencies

- customers-demand-domain (#5, ✅) — `customers` table exists in 00007
- pos-sales-domain PR1+PR2 (#6, ✅) — `sales`, `payments`, `create_sale_transaction` RPC exist in 00009
- pos-sales-domain PR3+PR4 (EFs) — not needed; credit-payments proceeds independently with its own EF

## Success Criteria

- [ ] `customer_balances` row is created atomically when a credit payment is inserted
- [ ] Abono via `register_customer_payment_transaction` correctly updates `paid_amount`, `remaining_amount`, and status transitions (pending → partial → paid)
- [ ] Cancelling a sale transitions the associated balance to 'cancelled'
- [ ] Concurrent abonos toward the same balance are serialized via `FOR UPDATE` with no lost updates
- [ ] RLS: admin can read/write own company; all authenticated read; unauthenticated sees zero rows
- [ ] R11 #2 updated to "Resolved" in project-architecture spec
- [ ] All pgTAP and Deno tests pass