# Design: Cash Session Domain

## Technical Approach

Implement `cash-session-domain` as migration `00008_cash_session_domain.sql` plus Edge Functions that call SECURITY DEFINER RPCs. Reads remain SDK + RLS. All money-affecting writes stay behind EF -> RPC to match `project-architecture` R2/R6 and the existing purchasing/inventory handler pattern. Because these cash RPCs are `service_role`-only, the Edge Function MUST pass explicit actor context in `p JSONB` and the SQL MUST validate that actor against membership tables instead of relying on DB-session JWT helpers.

## Architecture Overview

`cash_sessions` is the branch-scoped session header. `cash_movements` is the append-only expected-cash ledger. Open/close/manual movement/force-close mutate both through single-transaction RPCs.

```text
Client -> Edge Function -> shared cash handler -> public.cash_* RPC -> tables
                                                  |-> audit payload/result
```

## Data Model and Index Plan

| Object | Plan |
|------|------|
| `cash_sessions` | `id`, `company_id`, `branch_id`, `cashier_user_id`, `status`, `opened_at`, `closed_at`, `opening_amount`, `expected_cash_amount`, `counted_cash_amount`, `difference_amount`, `notes`, audit columns, logical-delete columns |
| `cash_movements` | `id`, `company_id`, `branch_id`, `cash_session_id`, `movement_type`, `amount`, `reference_type`, `reference_id`, `reason`, `notes`, audit columns |
| Composite FKs | `(company_id, branch_id) -> branches`; `(company_id, cashier_user_id) -> company_users(company_id, user_id)`; `(company_id, cash_session_id) -> cash_sessions(company_id, id)` |
| Supporting indexes | unique `(company_id, id)` on both tables; `cash_sessions(company_id, branch_id, cashier_user_id, status)`; partial unique index on open sessions `WHERE status = 'open' AND is_active`; `cash_movements(company_id, cash_session_id, created_at)` |

Rationale: follow the same-company composite FK pattern from `00006_purchasing_domain.sql` and keep future `sales.cash_session_id -> cash_sessions(company_id, id)` ready for migration `00009`.

## RLS and Grants Plan

| Area | Plan |
|------|------|
| `cash_sessions` SELECT | authenticated users see own company; admin sees all company rows; cashier restricted to assigned branch and, for self-service views, own `cashier_user_id` |
| `cash_movements` SELECT | same company/branch rules, additionally limited to visible sessions |
| Direct writes | no authenticated INSERT/UPDATE/DELETE policies on either cash table |
| Service role | `FOR ALL` policy for RPC/EF execution |
| Grants | authenticated/service_role get `SELECT`; only service_role gets `EXECUTE` on cash RPCs for EF calls; anon gets no access |

## RPC Design

| RPC | Purpose | Key checks |
|------|------|------|
| `open_cash_session(p jsonb)` | create open session and opening ledger row | company match, caller is cashier or admin, branch assignment, no existing open session, insert session + `opening_float` movement |
| `close_cash_session(p jsonb)` | close own session | owned/open session, counted amount required, compute `difference_amount`, persist closed totals atomically |
| `record_cash_movement(p jsonb)` | append manual cash in/out during open session | owned/open session unless admin override, signed amount/movement type validation, update `expected_cash_amount` atomically |
| `force_close_cash_session(p jsonb)` | admin close any open session | admin-only, target session open, counted amount required, optional reason |

All four RPCs should be `SECURITY DEFINER`, fixed `search_path=public`, and lock the target session row `FOR UPDATE`. `open_cash_session` also locks candidate rows for the same `(company_id, branch_id, cashier_user_id)` before insert; the partial unique index is the final guard.

Required payload fields for all service-role cash RPCs:

- `company_id` UUID
- `actor_user_id` UUID

Authorization model inside SQL:

- Query `company_users` for `(company_id, actor_user_id)` with `is_active = true` to derive the actor role.
- Do not rely on `auth.uid()`, `public.get_company_id()`, `public.is_admin()`, or `public.is_cashier()` for mutation authorization in these RPCs.
- Use the explicit actor ID for audit columns (`created_by`, `updated_by`) because `service_role` execution does not carry end-user auth context into the DB session.
- `open_cash_session`: cashier may open only for self; admin may open for another cashier, but the target user must be an active cashier in `company_users` and assigned to the target branch in `branch_users`.
- `close_cash_session`: preserve close-own semantics by requiring `actor_user_id = cash_sessions.cashier_user_id`; admin closes other users via `force_close_cash_session`.
- `record_cash_movement`: cashier may record only on own open session; admin may record on any open same-company session, and if acting on another cashier session a `reason` is required.
- `force_close_cash_session`: admin only via active company membership.

## Edge Function Design

Create `supabase/functions/_shared/cash_session_handler.ts` and `cash_session_schemas.ts`, mirroring inventory/purchasing. Add:

- `cash-session/open-session/index.ts`
- `cash-session/close-session/index.ts`
- `cash-session/record-manual-movement/index.ts`
- `cash-session/force-close-session/index.ts`

Recommended minimal auth extension: shared cash handler accepts allowed roles (`cashier`, `admin`) instead of the current exact-role helper, because V1 mixes cashier self-service with admin force-close.

## Sequence Diagrams

```text
Open session
Cashier -> EF: open(company, branch, opening_amount)
EF -> auth: validate user/company/role/branch
EF -> RPC: open_cash_session(p)
RPC -> DB: lock candidate scope, insert session, insert opening movement, commit
RPC -> EF: session_id + expected_cash_amount
EF -> Cashier: success
```

```text
Close session
Cashier/Admin -> EF: close(session_id, counted_cash_amount)
EF -> auth: validate user/company/role
EF -> RPC: close_cash_session(p) / force_close_cash_session(p)
RPC -> DB: lock session, sum/confirm expected, compute difference, update session closed fields, commit
RPC -> EF: closed totals
EF -> Client: success
```

## Concurrency and Atomicity Strategy

One open session per cashier+branch is enforced by: (1) partial unique index on open rows, (2) RPC pre-check with `FOR UPDATE`, and (3) single-transaction insert/update of session plus ledger. Any uniqueness violation returns a controlled domain error from RPC and EF.

## Testing Strategy

| Layer | What to test | Approach |
|------|------|------|
| pgTAP constraints | FKs, partial unique open-session index, status check, logical deletion behavior | `supabase/tests/test_cash_session_constraints.sql` |
| pgTAP RLS | admin company scope, cashier branch/self scope, direct-write denial, anon denial | `test_cash_session_rls.sql` |
| pgTAP RPC | hardened `SECURITY DEFINER`, `search_path`, open/close totals, manual movement updates, force-close, concurrency error path | `test_cash_session_rpcs.sql` |
| Deno | Zod validation, mixed-role auth handling, RPC invocation contract, EFResult shape | `supabase/functions/_test/cash_session_ef_test.ts` |

## Rollback Plan

Rollback by removing migration `00008_cash_session_domain.sql` before `00009` depends on it, then `supabase db reset`. No existing migration should be edited unless a discovered base-table constraint makes the composite FK impossible.

## Open Decisions and Recommended Choices

| Decision | Recommended choice | Reason |
|------|------|------|
| Session opening movement | Persist an explicit `opening_float` ledger row | keeps ledger complete from session start |
| `expected_cash_amount` source | store denormalized total on session and update in RPCs | close is cheaper and deterministic |
| Force-close in V1 | include it as separate admin RPC/EF | proposal already allows admin review without new states |
| Cashier read scope | own sessions only; admin gets company-wide | reduces exposure while preserving branch isolation |

Main risk: the current EF auth helper only supports one exact role, so cash-session should introduce a dedicated multi-role handler instead of overloading purchasing/inventory behavior.
