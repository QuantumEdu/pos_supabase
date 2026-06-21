# Exploration: Edge Functions-Only Module Architecture

## Change: `edge-functions-only-modules`

**Intent**: Pivot from frontend/npm-driven bootstrap to an Edge Functions-only module architecture where Supabase (migrations, RLS, RPC, Edge Functions) is the authoritative runtime, and the Vue/Vite frontend scaffold is demoted to removable/non-authoritative status.

---

## Current State

The project was bootstrapped as a **monorepo** with two intertwined layers:

1. **Supabase runtime layer** (authoritative, should be preserved):
   - `supabase/config.toml` — CLI config with custom ports (Windows Hyper-V conflict resolved)
   - `supabase/migrations/00001_companies_branches_profiles.sql` — 5 tables (companies, branches, profiles, company_users, branch_users) with UUID PKs, audit columns, logical deletion, `set_updated_at()` trigger
   - `supabase/migrations/00002_rls_helpers.sql` — 6 SQL helper functions (`get_company_id()`, `get_user_role()`, `get_user_branch_id()`, `is_admin()`, `is_cashier()`) reading JWT claims
   - `supabase/migrations/00003_rls_policies.sql` — 18 RLS policies across 5 tables, enforcing `company_id` isolation and `branch_id` scoping; service_role ALL policies for EF→RPC boundary
   - `supabase/functions/_shared/cors.ts` — CORS helper for EFs
   - `supabase/functions/health/index.ts` — Health EF following D3 abbreviated pattern

2. **Frontend/npm scaffold layer** (non-authoritative per user clarification):
   - `src/` (Vue 3 SPA: `main.ts`, `App.vue`, `router/index.ts`, `views/HomeView.vue`, `lib/supabase.ts`)
   - `index.html` — SPA entry point
   - `vite.config.ts` — Vite config for Vue build
   - `vitest.config.ts` — Vitest config for Vue/component testing
   - `tsconfig.json`, `tsconfig.node.json` — TypeScript configs targeting Vue/SPA
   - `env.d.ts` — Vite env type declarations
   - `package.json` — npm package with Vue 3, Vue Router, Supabase JS SDK, Vitest, Vue Test Utils, Supabase CLI
   - `tests/setup.ts`, `tests/ef-auth.test.ts`, `tests/supabase-rls.test.ts` — Vitest placeholder stubs
   - `dist/` — Build output

3. **OpenSpec governance** (preserve, needs updates):
   - `openspec/config.yaml` — currently says "Vue 3, TypeScript, Supabase" and "Frontend: Vue 3 + TypeScript, Supabase JS SDK"
   - `openspec/specs/project-architecture/spec.md` — R7 references "Vue 3 + TypeScript as a static client-side SPA build"
   - Archived change `migrate-existing-planning-to-gentle-ai/` with all artifacts

4. **Root planning docs** (frozen per R9/D2):
   - `constitution.md`, `spec.md`, `plan_1ra_parte.md`, `plan_2da_parte.md`

---

## Affected Areas

### Files to PRESERVE (Supabase runtime, governance)

- `supabase/config.toml` — Core CLI config; custom ports must be kept
- `supabase/migrations/00001_companies_branches_profiles.sql` — Foundation tables
- `supabase/migrations/00002_rls_helpers.sql` — RLS helper functions
- `supabase/migrations/00003_rls_policies.sql` — RLS policies
- `supabase/functions/_shared/cors.ts` — Shared EF utility
- `supabase/functions/health/index.ts` — Health EF scaffold
- `supabase/seed.sql` — Seed placeholder
- `openspec/specs/project-architecture/spec.md` — Authoritative spec (needs R7 update)
- `openspec/config.yaml` — Needs update for EF-only stack description
- `openspec/changes/archive/2026-06-10-migrate-existing-planning-to-gentle-ai/` — Archive (immutable)
- `constitution.md`, `spec.md`, `plan_1ra_parte.md`, `plan_2da_parte.md` — Frozen original docs
- `.gitignore` — Needs updating (remove frontend build artifacts, adjust for Deno/EF workflow)

### Files to REMOVE or DEMOTE (frontend/npm scaffold)

- `src/App.vue` — Vue SPA root component
- `src/main.ts` — Vue app bootstrap
- `src/router/index.ts` — Vue Router config
- `src/views/HomeView.vue` — Placeholder home view
- `src/lib/supabase.ts` — Frontend Supabase client (browser-side)
- `index.html` — SPA HTML entry
- `vite.config.ts` — Vite build config
- `vitest.config.ts` — Vitest config (Vue-specific)
- `tsconfig.json` — TypeScript config (Vue/SPA target)
- `tsconfig.node.json` — TypeScript config for Node configs
- `env.d.ts` — Vite env type declarations
- `tests/setup.ts` — Vue Test Utils setup
- `tests/ef-auth.test.ts` — Vitest EF stubs (need Deno test format instead)
- `tests/supabase-rls.test.ts` — Vitest RLS stubs (need pgTAP format instead)
- `package.json` — Needs complete rewrite (remove Vue deps, keep Supabase CLI, add Deno tooling)
- `package-lock.json` — Will regenerate with new `package.json`
- `dist/` — Build output (delete entirely)

### Specs that need UPDATES

- `openspec/specs/project-architecture/spec.md`:
  - R7 currently mandates "Vue 3 + TypeScript as a static client-side SPA build" — must be reframed
  - R8 currently mandates "Vitest + Vue Test Utils" — must be reframed for Deno test + pgTAP
  - D6 currently describes "monorepo root with `src/` (Vue 3)">" must be reframed
  - D7 must be updated for Deno test + pgTAP
- `openspec/config.yaml`:
  - Stack description says "Vue 3, TypeScript, Supabase"
  - `test_command` says `"vitest run"` — needs update
  - `build_command` says `"npm run build"` — needs replacement or removal

---

## Approaches

### 1. Clean Break — Remove Frontend Scaffold, Repackage as Supabase-Only Project

**Description**: Delete all `src/`, Vue/Vite/SPA files. Rewrite `package.json` to include only Supabase CLI + Deno tooling. Replace Vitest test stubs with Deno test format for EFs and pgTAP for SQL/RLS. Update specs to remove Vue mandates.

- **Pros**:
  - Clean architecture — no confusion about what's authoritative
  - Repo structure directly reflects the EF-only module pattern
  - No dead code to maintain or explain to future developers
  - `package.json` becomes lean: only `supabase` CLI + dev scripts
  - Tests are in the right format (Deno for EFs, pgTAP for SQL) — no Vue test wrappers
  - Aligns perfectly with user's intent: "Supabase-only means core behavior should not require a frontend app scaffold"
- **Cons**:
  - Larger diff — removes significant scaffold code
  - Need to establish new test infrastructure (Deno test runner, pgTAP setup)
  - If user later wants a frontend, there's nothing to start from (small risk — Vue scaffold is trivial to recreate)
  - Breaking change to existing CI/workflow assumptions
- **Effort**: Medium

### 2. Demote to Subdirectory — Keep Frontend in `/frontend` as Optional

**Description**: Move `src/`, `index.html`, Vue/Vite config to `/frontend/` subdirectory. Update `package.json` to have scripts for both Supabase and frontend. Specs remain neutral about frontend.

- **Pros**:
  - Preserves the work done on frontend scaffold
  - Clear separation: `/supabase/` = authoritative runtime, `/frontend/` = optional UI
  - Can regenerate frontend later without starting from zero
- **Cons**:
  - Still carries the npm/Vue dependency baggage
  - `package.json` at root is a Node project — implies Node is primary
  - Confusing signal about what's authoritative vs. optional
  - User explicitly said they do NOT want frontend-centered/npm-driven app
  - TypeScript configs conflict (SPA tsconfig vs. Deno tsconfig)
  - Vitest is still the test runner, but EFs and SQL need different test frameworks
- **Effort**: Medium

### 3. Hybrid — Keep Scaffold Minimal Until First Module, Then Decide

**Description**: Leave frontend scaffold in place as-is. Focus next SDD change (catalog-domain) entirely on Supabase artifacts (migrations + RPC + EFs). Frontend stays dormant until it becomes a blocker.

- **Pros**:
  - Smallest immediate change
  - Deferred decision — can remove scaffold later
- **Cons**:
  - Does NOT address user frustration about frontend-centered expectations
  - Specs still say "Vue 3" — sends wrong signal
  - Tests (.test.ts stubs in Vitest) are wrong format for EF/SQL testing
  - `package.json` still implies Node/Vue project
  - R7/R8 in spec actively mandate Vue — blocks or contradicts EF-only direction
  - User was explicit: they don't want this approach
- **Effort**: Low (but poor alignment with user intent)

---

## Recommendation

**Approach 1: Clean Break** — Remove the frontend scaffold entirely and repackage as a Supabase-only project.

**Why**: The user explicitly stated they are frustrated with the frontend-centered/npm-driven approach. The Vue/Vite scaffold is a trivial placeholder with no business logic. Removing it:
1. Makes the project structure match the architecture intent (EF-only modules)
2. Eliminates the mixed signal about what's authoritative
3. Forces the right test strategy (Deno + pgTAP, not Vitest for Vue components)
4. Simplifies `package.json` — only `supabase` CLI + Deno tooling
5. The Vue scaffold can be recreated in 30 minutes if ever needed — it has zero business logic

The key migration risk is establishing the Deno test runner + pgTAP test infrastructure, but this is necessary regardless of approach because Vitest/Vue Test Utils are the wrong tools for testing EFs and SQL policies.

---

## Proposed Module Sequence (from Archived Spec R10)

The roadmap order is authoritative and confirmed by both the archived spec and planning docs:

| # | Module | Key Domain Entities | EFs | RPCs |
|---|---------|---------------------|-----|------|
| 2 | **catalog-domain** | brands, categories, units, products, product_variants | — (CRUD via SDK+RLS for admin reads; EF only if critical ops like batch import) | Optional |
| 3 | purchasing-domain | suppliers, purchase_orders, purchase_receipt_items | create-purchase-order, receive-purchase-order, cancel-purchase-order | receive_purchase_transaction() |
| 4 | inventory-domain | inventory_batches, inventory_movements, inventory_adjustments, inventory_reservations | adjust-inventory, register-waste | adjust_inventory_transaction() |
| 5 | customers-demand-domain | customers, customer_requests, preorders, preorder_items | — (CRUD via SDK+RLS) | Optional |
| 6 | pos-sales-domain | sales, sale_items, sale_item_batches, payments, discount_authorizations | create-sale, cancel-sale, authorize-discount | create_sale_transaction(), cancel_sale_transaction() |
| 7 | cash-session-domain | cash_sessions, cash_movements | open-cash-session, close-cash-session | close_cash_session_transaction() |
| 8 | credit-payments-domain | customer_balances, customer_payments | register-payment | register_customer_payment_transaction() |
| 9 | returns-domain | returns, return_items | return-sale-item | return_sale_item_transaction() |
| 10 | dashboard-reports-domain | Views/aggregations | — | Reporting RPCs |
| 11 | audit-domain | audit_logs | — (triggered within RPCs) | — |

**First module to implement: catalog-domain** (Module 2, after bootstrap). This is confirmed by R10 and all planning docs.

---

## First Slice Recommendation: catalog-domain

The catalog domain includes brands, categories, units, products, and product variants. This is the foundation for all downstream modules (purchasing, inventory, sales all depend on products).

### Proposed catalog-domain slice structure:

```
supabase/
├── migrations/
│   └── 00004_catalog_domain.sql          # Tables: brands, categories, units, products, product_variants
│                                          # + indexes, constraints, audit columns, RLS policies
├── functions/
│   ├── _shared/
│   │   ├── cors.ts                       # (existing)
│   │   └── auth.ts                        # NEW: shared EF auth validation (D3 8-step helpers)
│   └── catalog/
│       ├── create-product/index.ts        # EF: admin creates product variant (8-step)
│       ├── update-product/index.ts        # EF: admin updates product variant
│       └── deactivate-product/index.ts    # EF: logical deletion (R5)
└── tests/
    └── catalog/
        ├── test_rls_catalog.sql           # pgTAP: RLS isolation tests
        └── test_product_create.test.ts    # Deno: EF unit tests
```

### Key decisions needed before implementation:

1. **Subscription tables**: spec R11 says "Excluded from MVP" — should migration 00004 include `subscription_plans`/`company_subscriptions` stubs or exclude entirely?
2. **Product variant pricing model**: `plan_2da` says "price is unique per company" and "last cost stored in variant" — should pricing be a separate table or column on `product_variants`?
3. **Category hierarchy**: Should `categories` support nesting (parent_id FK to self), or flat list only for MVP?
4. **Brand autonomy**: Are `brands` CRUD-by-admin-only, or should there be a way for suppliers to suggest brands?
5. **EF coverage for catalog**: Most catalog operations are admin CRUD reads/writes. Should ALL catalog mutations go through EFs (per R2 strict reading), or can admin CRUD use SDK+RLS (per D3 "Non-critical reads MAY use Supabase JS SDK with RLS enforcement")?

---

## Risks

1. **Spec R7/R8 contradiction**: The current `project-architecture/spec.md` mandates Vue 3 + Vitest. Removing the frontend scaffold requires updating R7 and R8 to remove Vue mandates and add Deno test + pgTAP as the test infrastructure. Failure to update these specs creates a drift between spec and implementation.

2. **Test infrastructure gap**: Removing Vitest removes the `npm run test` workflow. Must establish Deno test runner for EFs and `supabase test db` (pgTAP) for SQL/RLS. This is a hard dependency — the project needs a confirmed working test runner before strict TDD can be re-enabled.

3. **package.json scope change**: Current `package.json` is a Node/Vue project. Removing Vue deps leaves `supabase` CLI as the only devDependency. Needs careful scoping: should it include Deno? Or should Deno be handled via Supabase CLI's built-in EF dev server?

4. **Frontend consumer contract**: Without `src/lib/supabase.ts`, there's no documented EF response interface (`EFResult<T>`). The design D3 specifies this but it's not materialized. Each domain module should export its TypeScript type definitions for future frontend consumption.

5. **CORS wildcard**: `cors.ts` uses `Access-Control-Allow-Origin: "*"` — this is fine for development but must be restricted per-ENV before production. This isn't a blocker for the pivot but should be tracked.

6. **config.toml auth.site_url**: Currently defaults to `http://127.0.0.1:3000` — assumes frontend dev server. Should be updated to reflect EF-only architecture (no SPA port dependency).

7. **Breaking change for any existing remote deployment**: If the Supabase Cloud project is linked, removing the frontend scaffold doesn't affect remote DB/EFs, but any CI/CD assumptions about `npm run build` will break.

---

## Ready for Proposal

**Yes** — with clarification needed on the following questions before the `catalog-domain` proposal.

---

## Questions Before Proposal

1. **Frontend removal scope**: Should all Vue/Vite/frontend files be removed entirely in this change, or should they be moved to a `/frontend` subdirectory as "optional, non-authoritative"? (Recommendation: remove entirely.)

2. **Test runner choice**: For Edge Function tests, should we use the Deno built-in test runner (`Deno.test`) with `supabase functions test`, or a different approach? For SQL/RLS tests, is `supabase test db` (pgTAP) the confirmed choice?

3. **package.json role**: After removing Vue, what should `package.json` contain? Options:
   - (A) Minimal: only `supabase` CLI devDependency + scripts for `supabase start/reset/test`
   - (B) Include Deno: add Deno tooling for EF development
   - (C) Remove `package.json` entirely and use `deno.json` or `deno.jsonc` as the project manifest

4. **R7/R8 spec update**: Should this change also update `openspec/specs/project-architecture/spec.md` to remove Vue mandates and add Supabase-native test infrastructure? Or should spec updates be a separate change?

5. **EF coverage for catalog**: Per R2, "Critical ops MUST go through Edge Functions." Per D3, "Non-critical reads MAY use SDK+RLS." For catalog-domain:
   - Admin creating/updating products: Is this a "critical op" that REQUIRES an EF, or can it go through SDK+RLS?
   - Product deactivation (logical deletion): Should this be an EF (audit + validation) or SDK+RLS?
   - Product reads: Clearly SDK+RLS per D3.

6. **Product variant pricing**: Should pricing be a column on `product_variants`, or a separate `product_prices` table (to support multi-currency, temporal price changes, etc.)?

7. **Category hierarchy**: Should `categories` support a nested tree (self-referencing `parent_id`) for MVP, or flat list only?

8. **Module testing**: Should each module change include both Deno EF tests AND pgTAP RLS tests in its task breakdown, or should EF tests come first with pgTAP added later?