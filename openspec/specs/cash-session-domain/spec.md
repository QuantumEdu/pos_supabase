# Cash Session Domain Specification

## Purpose

Branch-scoped cash session control for POS operations. This domain defines the session header, append-only cash ledger, controlled open/close workflows, and the mutation boundary required before POS sales can persist money-affecting operations.

## ADDED Requirements

### RCS1: Cash Session Header Model
<!-- source: proposal.md §Goals, §Data Model Overview; exploration.md §Required V1 Entities -->
The system MUST define a `cash_sessions` table as the branch-scoped session header for cashier cash operations. `cash_sessions` MUST include `id` (UUID PK, `gen_random_uuid()`), `company_id` (UUID NOT NULL), `branch_id` (UUID NOT NULL), `cashier_user_id` (UUID NOT NULL), `status` (TEXT NOT NULL with CHECK `status IN ('open', 'closed')`), `opened_at` (TIMESTAMPTZ NOT NULL), `closed_at` (TIMESTAMPTZ NULL), `opening_amount` (NUMERIC(12,2) NOT NULL), `expected_cash_amount` (NUMERIC(12,2) NOT NULL), `counted_cash_amount` (NUMERIC(12,2) NULL), `difference_amount` (NUMERIC(12,2) NULL), `notes` (TEXT NULL), logical deletion columns (`is_active`, `deleted_at`, `deleted_by`), and audit columns (`created_at`, `updated_at`, `created_by`, `updated_by`). Physical deletion MUST be prohibited. Composite uniqueness MUST include `(company_id, id)`.

- **GIVEN** a cashier opens a session for company A and branch B1 **WHEN** the session is created **THEN** `cash_sessions` stores `company_id = A`, `branch_id = B1`, `cashier_user_id`, `status = 'open'`, `opened_at`, `opening_amount`, and `expected_cash_amount`
- **GIVEN** a session remains open **WHEN** queried **THEN** `closed_at`, `counted_cash_amount`, and `difference_amount` MAY be NULL
- **GIVEN** any actor attempts physical DELETE on `cash_sessions` **WHEN** the statement executes **THEN** the operation MUST be rejected because physical deletion is prohibited

### RCS2: Cash Movement Ledger Model
<!-- source: proposal.md §Goals, §Data Model Overview; exploration.md §Required V1 Entities -->
The system MUST define a `cash_movements` table as the append-only ledger of expected cash changes for a session. `cash_movements` MUST include `id` (UUID PK, `gen_random_uuid()`), `company_id` (UUID NOT NULL), `branch_id` (UUID NOT NULL), `cash_session_id` (UUID NOT NULL), `movement_type` (TEXT NOT NULL), `amount` (NUMERIC(12,2) NOT NULL), `reference_type` (TEXT NULL), `reference_id` (UUID NULL), `reason` (TEXT NULL), `notes` (TEXT NULL), and audit columns (`created_at`, `updated_at`, `created_by`, `updated_by`). Composite uniqueness MUST include `(company_id, id)`. The session reference MUST use a composite foreign key `(company_id, cash_session_id) -> cash_sessions(company_id, id)`.

- **GIVEN** an opening session workflow **WHEN** the system records the opening cash **THEN** at least one `cash_movements` row MAY be created to explain the expected cash baseline for that session
- **GIVEN** a movement row references session S in company A **WHEN** persisted **THEN** the composite FK MUST reject a `cash_session_id` that belongs to another company
- **GIVEN** a movement already exists **WHEN** an authenticated user attempts to overwrite its amount or reason directly **THEN** the operation MUST be rejected because the ledger is append-only

### RCS3: One Open Session Invariant
<!-- source: proposal.md §Goals, §V1 Domain Boundaries; exploration.md §Open Decisions Before Proposal -->
The domain MUST enforce exactly one open session per `(company_id, branch_id, cashier_user_id)` at a time. A cashier MAY have a closed session history in the same branch, but MUST NOT have more than one concurrent `status = 'open'` session in that branch. This invariant MUST be enforced at the database mutation boundary, not only in client code.

- **GIVEN** cashier U already has an open session in branch B1 for company A **WHEN** cashier U attempts to open another session in branch B1 for company A **THEN** the operation MUST be rejected
- **GIVEN** cashier U has a closed session history in branch B1 **WHEN** cashier U opens a new session after closing the prior one **THEN** the operation MUST succeed
- **GIVEN** cashier U has an open session in branch B1 **WHEN** cashier U opens a session in a different branch B2 without branch assignment permission **THEN** branch/authorization checks MUST decide access; the one-open invariant SHALL still be evaluated per branch

### RCS4: Open Session Workflow
<!-- source: proposal.md §Scope, §Critical Mutation Boundary; exploration.md §V1 Scope, §Critical Mutation Boundary -->
Opening a cash session MUST occur only through the Edge Function to SECURITY DEFINER RPC boundary. The open workflow MUST validate authenticated user, company, branch, role, and input before mutation, MUST create the session atomically, and MUST initialize `expected_cash_amount` from the opening amount. If the design uses an opening ledger row, that ledger row MUST be created in the same transaction.

- **GIVEN** a cashier with valid branch access and no open session **WHEN** `open-cash-session` is invoked with `opening_amount = 100.00` **THEN** a new `cash_sessions` row is created with `status = 'open'` and `expected_cash_amount = 100.00`
- **GIVEN** invalid input such as a negative opening amount **WHEN** `open-cash-session` is invoked **THEN** the mutation MUST be rejected before any row is committed
- **GIVEN** the session header is created but the related ledger initialization fails **WHEN** the transaction completes **THEN** the entire open workflow MUST roll back with no partial state

### RCS5: Close Session Workflow and Difference Calculation
<!-- source: proposal.md §Acceptance Criteria; exploration.md §Integration With POS Sales -->
Closing a cash session MUST occur only through the Edge Function to SECURITY DEFINER RPC boundary. The close workflow MUST require an open session, MUST store `counted_cash_amount`, MUST compute `difference_amount = counted_cash_amount - expected_cash_amount`, MUST set `closed_at`, and MUST transition `status` from `open` to `closed` atomically. Once closed, the session MUST NOT return to `open` in V1.

- **GIVEN** an open session with `expected_cash_amount = 245.50` **WHEN** `close-cash-session` is invoked with `counted_cash_amount = 250.00` **THEN** the session closes with `difference_amount = 4.50`
- **GIVEN** an open session with `expected_cash_amount = 245.50` **WHEN** `close-cash-session` is invoked with `counted_cash_amount = 240.00` **THEN** the session closes with `difference_amount = -5.50`
- **GIVEN** a closed session **WHEN** `close-cash-session` is invoked again **THEN** the operation MUST be rejected and the closed record MUST remain unchanged

### RCS6: Append-Only Cash Ledger Integrity
<!-- source: proposal.md §Data Model Overview, §Integration With Future POS Sales; project-architecture spec R5 -->
`cash_movements` MUST be append-only for operational users. Authenticated application users MUST NOT update or delete ledger rows directly. Corrections, reversals, and future returns/cancellations MUST be represented as new compensating rows rather than history mutation. `expected_cash_amount` on the session MUST be derivable from the ordered ledger semantics established by the domain workflows.

- **GIVEN** a mistaken manual cash-out was recorded **WHEN** the business needs to correct it **THEN** the correction MUST be represented by a new compensating movement, not by editing the original row
- **GIVEN** a historical movement exists **WHEN** an authenticated user attempts `UPDATE cash_movements SET amount = ...` **THEN** the operation MUST be rejected
- **GIVEN** a historical movement exists **WHEN** an authenticated user attempts `DELETE FROM cash_movements` **THEN** the operation MUST be rejected

### RCS7: EF to RPC Mutation Boundary
<!-- source: proposal.md §Proposed Change, §Critical Mutation Boundary; project-architecture spec R2, R6 -->
All money-affecting mutations in this domain MUST use the Edge Function to SECURITY DEFINER RPC pattern. Frontend and authenticated SDK clients MUST NOT insert, update, or delete `cash_sessions` or `cash_movements` directly for operational workflows. Reads MAY use SDK plus RLS. At minimum, `open-cash-session` and `close-cash-session` MUST exist behind this boundary. Any V1 manual cash in/out operation, if implemented, MUST use the same boundary.

- **GIVEN** a cashier client **WHEN** it needs to open a session **THEN** it MUST call the Edge Function entrypoint rather than direct table writes or direct RPC invocation
- **GIVEN** an authenticated SDK client **WHEN** it attempts direct INSERT into `cash_sessions` **THEN** RLS and policy design MUST reject the write
- **GIVEN** a non-critical read of current open session data **WHEN** performed by an authorized user **THEN** the read MAY use SDK plus RLS without an Edge Function

### RCS8: RLS and Branch Scoping
<!-- source: proposal.md §Scope, §Acceptance Criteria; exploration.md §V1 Scope; project-architecture spec R3 -->
Both `cash_sessions` and `cash_movements` MUST enforce RLS with `company_id` isolation and branch scoping. Cashier read access MUST be limited to their assigned branch and own-company data. Admin MAY read all branch data within their company. Unauthenticated users MUST receive zero rows. No operational DELETE policy SHALL exist on either table.

- **GIVEN** a cashier assigned to branch B1 in company A **WHEN** querying `cash_sessions` **THEN** only company A rows for branch B1 visible to that cashier are returned
- **GIVEN** an admin for company A **WHEN** querying `cash_movements` **THEN** rows from all branches in company A MAY be returned, but rows from company B MUST remain invisible
- **GIVEN** an unauthenticated request **WHEN** querying `cash_sessions` or `cash_movements` **THEN** zero rows MUST be returned

### RCS9: POS Sales Integration Contract
<!-- source: proposal.md §Integration With Future POS Sales; exploration.md §Integration With POS Sales; pos-sales-domain exploration.md §Cash Session Dependency -->
This domain MUST establish the dependency contract for POS sales. Future POS sales mutations MUST require an active open cash session, MUST reference that session from the sales transaction, and MUST write cash-affecting ledger entries atomically with sale persistence. The sales domain MUST treat this change as a prerequisite and MUST NOT bypass the session invariant.

- **GIVEN** a future sale attempt by a cashier without an open cash session **WHEN** the POS sales mutation is invoked **THEN** the sale MUST be rejected by the downstream sales contract
- **GIVEN** a future cash sale linked to an open session **WHEN** the sale commits **THEN** the sale transaction MUST also append the corresponding cash ledger effect atomically
- **GIVEN** a future return or cancellation **WHEN** it affects cash expectations **THEN** the downstream domain MUST add reversing `cash_movements` rows rather than mutating prior history

### RCS10: V1 State and Modeling Exclusions
<!-- source: proposal.md §Non-Goals, §V1 Domain Boundaries; exploration.md §Optional / Deferred Entities, §Workflow States, §V1 Scope -->
V1 MUST model only the `open` and `closed` session states. V1 MUST NOT introduce denomination-level count rows, `cash_counts`, `cash_session_counts`, `reconciled`, `reviewed`, or any equivalent admin-review state. V1 MUST store only the total `counted_cash_amount` on `cash_sessions`. V1 MUST NOT model shift handoff, safe drops, multi-drawer, device-specific register assignment, or session transfer.

- **GIVEN** V1 session close **WHEN** counted cash is persisted **THEN** only the total `counted_cash_amount` is stored, with no denomination breakdown rows
- **GIVEN** an implementer proposes a `reviewed` or `reconciled` status **WHEN** validating against this spec **THEN** the proposal MUST be rejected as out of V1 scope
- **GIVEN** V1 schema review **WHEN** inspecting domain artifacts **THEN** no denomination-level count table and no review-state machine SHALL exist

### RCS11: Manual Cash Movement Scope
<!-- source: proposal.md §Scope; exploration.md §Critical Mutation Boundary -->
The domain MAY include manual cash in/out movements in V1, but only if they follow the same money-safe invariants as session open/close. If implemented, each manual movement MUST target an open session, MUST append exactly one new `cash_movements` row, MUST explain the operation through `movement_type` and/or `reason`, and MUST update session-level expected cash atomically through the controlled mutation boundary. If manual cash in/out is not implemented in V1, the schema and policies MUST still preserve room for that extension without weakening the append-only contract.

- **GIVEN** manual cash-in is included in V1 **WHEN** a cashier records it against an open session **THEN** one new ledger row is appended and the expected cash change is committed atomically
- **GIVEN** manual cash-out is attempted against a closed session **WHEN** the mutation runs **THEN** the operation MUST be rejected
- **GIVEN** manual cash movement capability is deferred **WHEN** reviewing V1 artifacts **THEN** open/close workflows still satisfy this spec without requiring manual movement endpoints

### RCS12: Test Requirements
<!-- source: proposal.md §Acceptance Criteria; project-architecture spec R8 -->
The change MUST include pgTAP coverage for SQL schema, constraints, composite foreign keys, RLS isolation, policy absence for direct operational deletes, and the one-open-session invariant. The change MUST also include `Deno.test` coverage for Edge Function validation and RPC orchestration of `open-cash-session` and `close-cash-session`. Tests MUST prove that direct authenticated writes are rejected, reads remain RLS-governed, and close difference calculation is persisted correctly.

pgTAP coverage MUST include:

- `cash_sessions` and `cash_movements` table existence, required columns, constraints, and composite FK integrity
- RLS isolation by company and branch for cashier/admin/unauthenticated access
- rejection of direct authenticated INSERT/UPDATE/DELETE attempts on operational cash tables
- enforcement of one open session per cashier per branch
- prohibition of invalid session states outside `open` and `closed`

`Deno.test` coverage MUST include:

- Edge Function validation failures for invalid auth, branch scope, and invalid amounts
- successful open workflow response and rejection of duplicate open session attempts
- successful close workflow response with persisted `expected_cash_amount`, `counted_cash_amount`, and `difference_amount`
- transaction rollback behavior when a ledger/session mutation step fails

- **GIVEN** `supabase test db` **WHEN** the cash-session-domain tests run **THEN** all pgTAP assertions MUST pass
- **GIVEN** `deno test` for cash session Edge Functions **WHEN** the suite runs **THEN** open/close workflow tests MUST pass
- **GIVEN** a regression allows direct SDK writes **WHEN** tests execute **THEN** the suite MUST fail because the mutation boundary was broken

## Non-Goals

- Frontend or UI flows
- POS sales schema implementation
- Returns/cancellations implementation details beyond the append-only contract
- Treasury reporting workflows
- Denomination-level counts
- Reconciled or reviewed session states
