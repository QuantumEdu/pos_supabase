# Cash Session Domain Exploration

## Executive Summary

The cash-session domain must be pulled forward before POS sales because the planning documents require an open cash session before selling and require every sale to be linked to a session. V1 should create the cash session foundation and cash movement ledger using Edge Functions -> SECURITY DEFINER RPCs, because opening/closing cash affects money and operational traceability.

## Required V1 Entities

### `cash_sessions`

Core session header for a cashier operating at a branch.

Suggested fields:

- `id`
- `company_id`
- `branch_id`
- `cashier_user_id`
- `status`
- `opened_at`
- `closed_at`
- `opening_amount`
- `expected_cash_amount`
- `counted_cash_amount`
- `difference_amount`
- `notes`
- audit and logical deletion columns

### `cash_movements`

Append-only ledger for events that affect or explain the cash session.

Suggested fields:

- `id`
- `company_id`
- `branch_id`
- `cash_session_id`
- `movement_type`
- `amount`
- `reference_type`
- `reference_id`
- `reason`
- `notes`
- audit columns

## Optional / Deferred Entities

### `cash_counts` / `cash_session_counts`

Only needed if denomination-level arqueo is required. V1 can store total counted cash directly on `cash_sessions`.

### `shifts`

No separate shift model appears in the source material. In V1, a cash session is the operative shift.

### `cash_closures`

Likely unnecessary. Closing is the terminal state of `cash_sessions`.

## Workflow States

Recommended V1 state machine:

```text
open -> closed
```

Do not add `reconciled`/`reviewed` unless the business explicitly defines an admin-review workflow.

## Critical Mutation Boundary

The following operations MUST use Edge Function -> SECURITY DEFINER RPC:

- `open-cash-session`
- `close-cash-session`
- manual cash in/out movements if included in V1
- any future operation that changes expected cash or session totals

Direct SDK writes to `cash_sessions` and `cash_movements` should be denied for authenticated users.

## Integration With POS Sales

POS sales should be built on top of this domain:

- A cashier must have an active open session before creating a sale.
- `sales.cash_session_id` should reference `cash_sessions(company_id, id)` in the POS sales domain.
- Cash sale payments should create `cash_movements` rows or be reflected in the cash session ledger inside the sales transaction.
- Closing a session should compare expected cash against counted cash and produce a difference.

## V1 Scope

In scope:

- Open cash session.
- Close cash session.
- Opening cash amount.
- Counted cash amount.
- Expected-vs-counted difference.
- One session tied to cashier + branch.
- `cash_sessions`.
- `cash_movements`.
- RLS + branch scoping.
- EF -> RPC mutation boundary.

Deferred:

- Denomination-level cash counts.
- `reconciled`/`reviewed` workflow.
- Shift handoff.
- Multiple drawer/register/device modeling.
- Safe drops and advanced treasury.
- Session transfer.
- Report exports.
- Return/cancellation cash reversal details.

## Migration

Because cash sessions are pulled forward before POS sales, use:

```text
00008_cash_session_domain.sql
```

Then POS sales should use:

```text
00009_pos_sales_domain.sql
```

## Open Decisions Before Proposal

Recommended defaults:

1. Session ownership: one open session per cashier per branch.
2. Cash count granularity: total counted cash only; denomination counts deferred.
3. Cash ledger: `cash_movements` is the append-only ledger of expected cash.
4. Sales integration: POS sales RPC writes cash movements inside the sale transaction.
5. Authorization: cashier can open/close own sessions; admin can review and force-close.
6. State model: only `open` and `closed` in V1.
7. Returns/cancellations: later domains create reversing cash movements.

## Recommendation

Proceed to proposal for `cash-session-domain` after confirming the recommended defaults above.
