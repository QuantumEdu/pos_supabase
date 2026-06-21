# Project Architecture Specification

Cross-cutting invariants and scaffold conventions from the 12 constitution principles. All downstream domain specs MUST reference this foundation.

---

## ADDED Requirements

### R1: Supabase-Only Runtime
<!-- source: constitution.md §10 (consistency before convenience), §12 (modular evolution); plan_1ra §2 (architecture general) -->
Runtime MUST be Supabase exclusively. No external backend frameworks (Express, Nest, Next.js API routes) in V1.
- Non-Supabase backend proposals MUST be rejected per this requirement. (source: constitution.md §10)
- Frontend MUST deploy as static SPA/build artifacts only within a Supabase-compatible static deployment model. It MUST NOT require a separate app server, SSR server, Node runtime server, Next/Nuxt server, or external hosting/runtime beyond the Supabase-only deployment model. (source: constitution.md §10, plan_1ra §2)

### R2: Edge Functions as Exclusive Backend Logic
<!-- source: constitution.md §3 (traceability of critical ops), §11 (transactional operations); plan_2da §16 (Edge Functions strategy) -->
Critical ops (money, inventory, collections) MUST go through Edge Functions. Frontend MUST NOT call RPC or modify operational tables directly.
- **Critical op**: MUST follow 8-step sequence — validate user → company → branch → role → input → invoke RPC → audit → return result. (source: constitution.md §3, §9; plan_2da §16.2)
- **Non-critical read**: MAY use Supabase JS SDK with RLS enforcement. (source: constitution.md §9)

### R3: RLS-First Multi-Tenant Data Access
<!-- source: constitution.md §8 (multi-company by design), §9 (security by default); plan_2da §15 (RLS strategy) -->
All operational tables MUST enforce RLS. `company_id` is the primary tenant key.
- **Operational table**: every RLS policy MUST filter by `company_id`. (source: constitution.md §8; plan_2da §15.1)
- **Branch-scoped tables** (sales, cash, inventory): cashier policies MUST also filter by `branch_id`. (source: constitution.md §8; plan_2da §15.2)
- **Unassigned user**: MUST return zero rows — no cross-tenant leakage. (source: constitution.md §8, §9)
- **Admin**: MAY see all own-company data; MUST NOT see other companies. (source: constitution.md §8; plan_2da §15.3)

### R4: Inventory Movement Integrity
<!-- source: constitution.md §1 (inventory is the source of truth), §2 (physical vs available stock) -->
Stock quantities MUST NEVER be edited directly. All changes via movements (purchases, receipts, sales, returns, adjustments, waste, expirations, transfers). (source: constitution.md §1)
- Available = physical − committed (reservations, preorders, backorders). (source: constitution.md §2)
- Every inventory change MUST link to a movement record. (source: constitution.md §1)

### R5: Traceability and Logical Deletion
<!-- source: constitution.md §3 (every critical op must be traceable), §4 (no financial operation must be lost) -->
Critical ops MUST generate auditable records (user, timestamp, company, branch, operation). Critical entities MUST use logical deletion (`is_active`, `deleted_at`, `deleted_by`). Physical deletion PROHIBITED. (source: constitution.md §3, §4)
- Cancellation MUST create reversal records — original preserved. (source: constitution.md §4)
- Applies to: products, customers, suppliers, sales, purchases, movements, cash sessions. (source: constitution.md §4)

### R6: Transactional Consistency
<!-- source: constitution.md §11 (transactional operations), §10 (consistency before convenience) -->
Multi-table ops MUST execute atomically. Partial states PROHIBITED. Consistency and traceability MUST prevail over speed or flexibility. (source: constitution.md §11, §10)

### R7: Project Scaffold Foundation
<!-- source: plan_1ra §2, plan_2da §14, constitution §10, §12 -->
Reproducible local dev via Supabase CLI + Deno. No frontend app server, SSR runtime, or SPA build required.
- **Clone & setup**: CLI initializes local Supabase, applies migrations, starts backend. (source: plan_1ra §2)
- **Runtime**: Supabase CLI + Deno for Edge Functions. No Vue/Vite/Node frontend required. (source: constitution §10, §12)
- **Frontend consumers**: MAY connect via SDK+RLS for reads or EFs for critical ops. Frontend is NOT part of this project's scaffold. (source: constitution §10)
- **Deploy**: CLI pushes EFs, migrations, RLS to remote. (source: plan_1ra §2)

### R8: Test Infrastructure Foundation
<!-- source: constitution §10, §3 -->
Deno.test for EFs and `supabase test db` (pgTAP) for SQL/RLS MUST be configured before critical logic. Strict TDD disabled until runners verified.
- **Deno test**: EF unit/integration tests use `Deno.test()`. (source: constitution §10)
- **pgTAP**: SQL and RLS tests use `supabase test db`. (source: constitution §3, plan_2da §15)
- No runner → manual verification criteria in task specs.
- Runner operational → RED-GREEN-REFACTOR.

### R9: Migration Traceability and Doc Drift Prevention
<!-- source: constitution.md §3 (traceability principle extended to documentation), §10 (consistency over convenience) -->
- Migrated content MUST include `(source: {filename} §N)` annotations. (source: constitution.md §3)
- Original docs preserved as-is. SDD artifacts are authoritative over originals. (source: constitution.md §10)
- When all source content is archived, original doc MUST be marked deprecated with header pointing to OpenSpec specs. (source: constitution.md §10)

### R10: Chained Delivery Roadmap
<!-- source: constitution.md §12 (modular evolution), §10 (consistency before convenience) -->
Changes MUST follow: (1) bootstrap-architecture, (2) catalog-domain, (3) purchasing-domain, (4) inventory-domain, (5) customers-demand-domain, (6) pos-sales-domain, (7) cash-session-domain, (8) credit-payments-domain, (9) returns-domain, (10) dashboard-reports-domain, (11) audit-domain. Each depends on previous being archived. No PR SHALL exceed 400-line review budget. (source: constitution.md §12)

### R11: Open Decision Tracking
<!-- source: constitution.md §10 (consistency before convenience — unresolved decisions must be visible) -->

| # | Decision | Resolve Before | Status |
|---|----------|----------------|--------|
| 1 | Subscription tables — no business rules defined | MVP exclusion | Excluded from MVP |
| 2 | `customer_balances` — trigger-seeded, RPC-maintained table | credit-payments-domain | Resolved: trigger-seeded, RPC-maintained table (credit-payments-domain) |
| 3 | Excel export — CSV-only MVP or XLSX in Edge Functions | dashboard-reports-domain | Unresolved |

---

## Design Decisions

### D6: Supabase CLI Local Development Workflow

```
supabase init / start / migration new / db push / functions serve
supabase test db / deno test / db reset
supabase functions deploy / db push --linked
```

Scaffold: `supabase/` at project root (migrations, functions, config, tests). No frontend directory. `package.json` has Supabase CLI devDependency + scripts only. (source: plan_1ra §2, plan_2da §14, constitution §10, §12)

### D7: Test Foundation Strategy

| Phase | Action | Strict TDD |
|-------|--------|------------|
| This change | Remove Vitest/Vue Test Utils. Establish `Deno.test` + pgTAP. Zero app tests. | Disabled |
| Scaffold verified | First EF test (auth validation). First SQL test (RLS isolation). | Re-evaluate |
| Domain changes (2–11) | Each task: Deno test + pgTAP criteria. | Enabled |

Runner verified = `deno test` and `supabase test db` both pass → enable `strict_tdd: true`. (source: constitution §10, §3)

---

## Non-Goals
- Per-domain business specs, source code, DB migrations, EF/RPC implementations, UI specs → downstream changes
- Resolving open decisions → documented as decision points only
- Subscription management → excluded from MVP
