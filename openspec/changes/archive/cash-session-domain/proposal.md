# Proposal: Cash Session Domain

## Problem Statement

POS sales require an active cash session before selling, but the current system has no session header, no cash ledger, and no controlled close workflow. Without this domain, sales cannot enforce the operating rule "open cash before sell," cash differences are not traceable, and future returns/cancellations would have no ledger foundation.

## Goals

1. Add `cash_sessions` as the branch-scoped cashier session header with open/close lifecycle.
2. Add `cash_movements` as the append-only ledger for expected cash changes.
3. Enforce one open session per cashier per branch.
4. Use Edge Function -> SECURITY DEFINER RPC for all critical mutations.
5. Establish the dependency contract for future POS sales integration.

## Non-Goals

- Denomination-level count rows.
- Extra states beyond `open` and `closed`.
- Shift handoff, safe drops, multi-drawer/device modeling.
- Returns/cancellations reversal logic implementation.
- Frontend/UI.

## Scope

### In Scope

- Migration `00008_cash_session_domain.sql`
- Tables `cash_sessions`, `cash_movements`
- RPC-backed open/close session flow and optional manual cash movement flow
- RLS for company + branch isolation
- Audit, logical deletion, and close difference calculation

### Out of Scope

- Denomination tables (`cash_counts`)
- Admin review/reconcile state machine
- POS sales schema changes
- Treasury/reporting workflows

## Capabilities

### New Capabilities

- `cash-session-domain`: cashier cash sessions, append-only cash ledger, controlled open/close flow

### Modified Capabilities

- `project-architecture`: roadmap dependency is resolved operationally by pulling cash sessions ahead of POS sales implementation while preserving the critical-op EF -> RPC pattern.

## Proposed Change

Implement the cash-session domain as a money-sensitive backend slice: reads may use SDK + RLS, but authenticated users cannot write `cash_sessions` or `cash_movements` directly. Opening, closing, and any ledger-affecting mutation go through Edge Functions that validate user/company/branch/role/input, call SECURITY DEFINER RPCs, audit the action, and return controlled results.

## V1 Domain Boundaries

- Cashier opens and closes only their own session.
- Admin may review and force-close.
- One open session per cashier per branch.
- V1 stores only `counted_cash_amount`, not denomination rows.
- `cash_movements` is the source of expected cash evolution.
- States: `open`, `closed`.

## Data Model Overview

### `cash_sessions`

Header table with `company_id`, `branch_id`, `cashier_user_id`, `status`, `opened_at`, `closed_at`, `opening_amount`, `expected_cash_amount`, `counted_cash_amount`, `difference_amount`, `notes`, audit columns, and logical deletion columns.

### `cash_movements`

Append-only ledger with `company_id`, `branch_id`, `cash_session_id`, `movement_type`, `amount`, `reference_type`, `reference_id`, `reason`, `notes`, and audit columns. No UPDATE/DELETE path for authenticated users.

## Critical Mutation Boundary

Edge Functions are the only application entrypoint for `open-cash-session`, `close-cash-session`, and any manual cash in/out operation included in V1. These functions call SECURITY DEFINER RPCs that enforce ownership, open-session uniqueness, branch/company scope, expected-vs-counted reconciliation, and atomic ledger/session updates.

## Integration With Future POS Sales

POS sales MUST depend on an active `cash_sessions(company_id, id)` record. Future sales RPCs should require an open session, write `cash_movements` inside the sale transaction, and keep cash ledger updates atomic with sale persistence. Returns/cancellations will later add reversing `cash_movements` rather than mutating history.

## Risks and Mitigations

| Risk | Severity | Mitigation |
|------|----------|------------|
| Session/sales ordering drift | High | Make cash-session-domain the prerequisite for POS sales implementation and reference it in downstream specs. |
| Direct cash table writes | High | Deny authenticated writes via RLS; allow mutations only through EF -> SECURITY DEFINER RPC. |
| Close mismatch disputes | Medium | Persist `expected_cash_amount`, `counted_cash_amount`, and `difference_amount` at close with audit metadata. |
| Over-modeling V1 | Medium | Defer denomination rows, review states, and drawer complexity. |

## Rollback Plan

Revert `00008_cash_session_domain.sql` and run `supabase db reset`. Because this change adds new tables and backend entrypoints without modifying existing domain tables, rollback is a clean removal if performed before POS sales depends on it.

## Acceptance Criteria

- `cash_sessions` and `cash_movements` exist with RLS, audit columns, and logical deletion where applicable.
- Authenticated users cannot directly insert/update/delete operational cash records through SDK.
- A cashier can open only one session per branch at a time.
- Closing a session stores expected, counted, and difference amounts atomically.
- Admin can review/force-close without adding new V1 states.
- Proposal establishes `cash_session_id` and ledger expectations for future POS sales.

## Open Decisions Resolved

- One open session per cashier per branch.
- V1 stores total counted cash only.
- `cash_movements` is the append-only cash ledger.
- POS sales will write cash movements inside the sales transaction later.
- Cashier opens/closes own session; admin may review/force-close.
- V1 states are only `open` and `closed`.
- Returns/cancellations will use reversing cash movements in later domains.
