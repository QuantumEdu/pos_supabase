# Design: Migrate Existing Planning to Gentle AI

## Technical Approach

Constitution-First Bootstrap: extract 12 business principles as architecture guardrails, establish Supabase-only+Edge-Functions enforcement, require frontend delivery as static SPA/build artifacts only, define source-to-SDD migration authority, and scaffold the project foundation with test infrastructure. This design covers ONLY the bootstrap change — per-domain specs follow as chained downstream changes (2–11 per roadmap R10).

References: Proposal `sdd/migrate-existing-planning-to-gentle-ai/proposal`, Spec `project-architecture/spec.md` R1–R11.

## Architecture Decisions

### D1: Supabase-Only Runtime Enforcement

| Option | Tradeoff | Decision |
|--------|----------|----------|
| Express/Nest backend | Familiar but violates constraint | **Rejected** |
| Next.js API routes | Dual stack, complexity drift | **Rejected** |
| Next/Nuxt SSR or app server frontend | Requires non-Supabase server runtime | **Rejected** |
| Supabase-only (Auth + PostgreSQL + RLS + Edge Functions + Storage) | Single platform, enforced simplicity | **Chosen** |

**Rationale**: Constitution principles 10 (consistency over convenience) and 12 (modular evolution) demand a single source of truth. Adding frameworks would violate R1 and create drift. Enforce via: (1) `config.yaml` rule, (2) CI lint rejecting `express`/`next`/`nest` in dependencies, (3) Edge Function as sole backend entry point for critical ops, (4) PR3 package/script/config review rejecting SSR, app-server, Node runtime server, Next/Nuxt server, or external non-Supabase frontend runtime requirements.

### D2: Source-Doc-to-SDD Artifact Authority

| Artifact | Authority | Source | Status |
|----------|-----------|--------|--------|
| `openspec/specs/*` | **Authoritative** | SDD delta specs | Active truth |
| `openspec/changes/*/design.md` | Authoritative | Design phase | Active truth |
| `constitution.md` | Deprecated reference | Original doc | Frozen once migrated |
| `spec.md` | Deprecated reference | Original doc | Frozen once all domains archived |
| `plan_*.md` | Deprecated reference | Original docs | Frozen once all domains archived |

**Migration model**: Each delta spec MUST include `(source: {filename} §N)` annotations (R9). After all 11 changes archive, add deprecation headers to original docs pointing to OpenSpec.

### D3: Edge Function Authorization Sequence (8-Step Pattern)

Every critical Edge Function MUST follow this sequence (from plan_2da §16.2):

```
Client Request → EF
  1. Validate user (auth JWT via Supabase Auth)
  2. Validate company (company_id from JWT claims or request body vs RLS)
  3. Validate branch (branch_id for cashier-scoped ops)
  4. Validate role (admin/cashier from company_users.role)
  5. Validate input (zod/joi schema on request body)
  6. Invoke RPC SQL (transactional boundary — see D4)
  7. Register audit (insert audit_logs within RPC or EF)
  8. Return consistent result (typed success/error response)
```

**Non-critical reads**: MAY use Supabase JS SDK directly with RLS enforcement. No EF required.

### D4: RPC SQL Transactional Boundary

| Concern | Pattern |
|---------|---------|
| Multi-table mutations | RPC function wrapping `BEGIN...COMMIT`/`ROLLBACK` |
| EF → RPC interface | EF calls `supabase.rpc('function_name', params)` |
| Audit within transaction | `audit_logs` INSERT inside same RPC transaction |
| Error handling | RPC raises exception → EF catches → returns typed error |
| Idempotency | RPC input validates preconditions before mutation |

RPC functions are `SECURITY DEFINER` to bypass RLS for atomicity; RLS still guards direct table access. The EF acts as orchestrator/validator; the RPC is the transactional workhorse.

### D5: RLS-First Multi-Tenant Policy Pattern

```
-- Template for all operational tables
CREATE POLICY "{table}_company_select" ON {table}
  FOR SELECT USING (company_id = get_company_id());

-- Template for branch-scoped tables (sales, cash, inventory)
CREATE POLICY "{table}_branch_select" ON {table}
  FOR SELECT USING (company_id = get_company_id()
    AND (
      get_user_role() = 'admin'
      OR branch_id = get_user_branch_id()
    ));

-- Admin: see all own-company data
-- Cashier: see only assigned-branch data
```

`get_company_id()`, `get_user_role()`, `get_user_branch_id()` — helper SQL functions reading from JWT claims or `company_users`/`branch_users`.

### D6: Supabase CLI Local Development Workflow

```
supabase init                          → creates supabase/ directory
supabase start                         → local stack (Postgres, Auth, Studio)
supabase migration new <name>          → create migration file
supabase db push                       → apply migrations locally
supabase functions serve               → local EF dev server
supabase test db                       → run pgTAP tests
supabase db reset                      → reset + re-seed
supabase functions deploy <name>       → deploy EF to remote
supabase db push --linked              → apply migrations to remote
```

Project scaffold: monorepo root with `supabase/` (migrations, functions, config), `src/` (Vue 3 static SPA app), `tests/` (Vitest). Vue 3 is permitted only as client-side static build output; no SSR mode or separate frontend server runtime is allowed.

### D7: Test Foundation Strategy

| Phase | Action | Strict TDD |
|-------|--------|------------|
| Bootstrap (this change) | Install Vitest + Vue Test Utils + pgTAP. Write zero app tests. | **Disabled** |
| After scaffold | First test: EF auth validation unit test. First integration: `supabase test db` for RLS. | Re-evaluate |
| Domain changes (2–11) | Each task includes test criteria. Runner exists → RED-GREEN-REFACTOR. | **Enabled** |

Verification before runner: manual criteria in task specs. Once `vitest run` and `supabase test db` both pass, enable `strict_tdd: true` in `config.yaml`.

### D8: Chained Roadmap Governance

Roadmap order per R10. Enforcement:
- Each change depends on previous being **archived** (not just merged).
- PR review budget: 400 lines max. Forecast in `tasks.md` per SDD rules.
- If a task exceeds 400 lines, split into chained PR slices with clear start/finish/verification.
- `state.yaml` in each change directory tracks DAG status.

### D9: Artifact Authority & Drift Prevention

- SDD workflows are the **single source of truth** after migration.
- Original docs (`constitution.md`, etc.) get frozen with deprecation headers pointing to OpenSpec.
- `(source: {filename} §N)` annotations required in all migrated delta specs.
- Any edit to original docs after migration MUST be reflected in the corresponding OpenSpec spec — no dual maintenance.

## Data Flow

```
Client (Vue 3 + TS static SPA build)
    │
    │ Supabase JS SDK
    ▼
┌─────────────────────────────┐
│  Critical Ops                │  Non-Critical Reads
│  ┌──────────────────────┐   │  ┌────────────────┐
│  │ Edge Function (Deno)  │   │  │ Direct SDK+RLS  │
│  │ 1. Auth (JWT)         │   │  │ SELECT with     │
│  │ 2. Company match      │   │  │ RLS enforcement │
│  │ 3. Branch match       │   │  └────────────────┘
│  │ 4. Role check         │   │
│  │ 5. Input validation   │   │
│  │ 6. RPC SQL call       │   │
│  │ 7. Audit log          │   │
│  │ 8. Return result      │   │
│  └──────────┬─────────────┘   │
│             │                │
│             ▼                │
│  ┌──────────────────────┐   │
│  │ PostgreSQL RPC       │   │
│  │ (SECURITY DEFINER)   │   │
│  │ BEGIN                │   │
│  │  validate precond    │   │
│  │  mutate tables       │   │
│  │  insert audit_log    │   │
│  │ COMMIT               │   │
│  └──────────┬─────────────┘   │
│             │                │
│             ▼                │
│  ┌──────────────────────┐   │
│  │ PostgreSQL + RLS     │   │
│  │ company_id ∈ every   │   │
│  │ operational table    │   │
│  │ branch_id where scpd │   │
│  └──────────────────────┘   │
└─────────────────────────────┘
```

## File Changes

| File | Action | Description |
|------|--------|-------------|
| `openspec/changes/migrate-existing-planning-to-gentle-ai/design.md` | Create | This design document |
| `openspec/changes/migrate-existing-planning-to-gentle-ai/state.yaml` | Create | DAG state tracking |
| `supabase/` | Create (task) | Supabase CLI init directory structure |
| `supabase/migrations/` | Create (task) | Initial migration: companies, branches, profiles |
| `supabase/functions/` | Create (task) | Edge Functions directory |
| `src/` | Create (task) | Vue 3 + TypeScript static SPA scaffold |
| `tests/` | Create (task) | Vitest + Vue Test Utils config |
| `vitest.config.ts` | Create (task) | Test runner configuration |
| `package.json` | Create (task) | Project dependencies and scripts; no SSR/server framework mode or frontend server runtime dependencies |

## Interfaces / Contracts

```typescript
// Edge Function standard response
interface EFResult<T> {
  success: boolean;
  data?: T;
  error?: { code: string; message: string };
}

// RPC function standard signature (PL/pgSQL)
// create_sale_transaction(p_company_id uuid, p_branch_id uuid,
//   p_user_id uuid, p_sale_data jsonb) → jsonb

// Helper RLS functions (SQL)
// get_company_id() → uuid
// get_user_role(p_company_id uuid) → text
// get_user_branch_id(p_company_id uuid) → uuid
```

## Testing Strategy

| Layer | What | Approach |
|-------|------|----------|
| Unit (EF) | Auth validation, input schemas | Vitest + Deno test runner |
| Unit (SQL) | RLS policy isolation | pgTAP (`supabase test db`) |
| Integration | EF → RPC → DB roundtrip | Vitest + local Supabase |
| E2E | Full user flows | Disabled until scaffold complete |

## Migration / Rollout

This change produces documentation + project scaffold only — no runtime risk.

**Artifact migration rollback**: Delete `openspec/changes/migrate-existing-planning-to-gentle-ai/`. Original docs in repo root are untouched. Re-create proposal with corrected scope.

**Scaffold rollback**: Delete `supabase/`, `src/`, `package.json`. No database deployed yet. `supabase stop` cleans local stack.

**Drift mitigation**: If original docs are edited after migration, update SDD specs and add `(source: {filename} §N)` annotation showing the updated reference.

## Open Questions

- [ ] `customer_balances` design — materialized view, trigger-maintained table, or always-computed? Resolve before `credit-payments-domain` (change 8).
- [ ] Excel export — CSV-only for MVP, or XLSX via Edge Function library? Resolve before `dashboard-reports-domain` (change 10).
- [ ] `cancel_purchase_order` EF has no matching RPC. Add `cancel_purchase_transaction()`? Resolve in `purchasing-domain` (change 3).
- [ ] Subscription tables — excluded from MVP per R11, but table stubs in Phase 1 schema. Include minimal stub or exclude entirely? Resolve in `catalog-domain` (change 2).
