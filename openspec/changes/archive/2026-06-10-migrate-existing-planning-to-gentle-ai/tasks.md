# Tasks: Migrate Existing Planning to Gentle AI

## Review Workload Forecast

| Field | Value |
|-------|-------|
| Estimated changed lines | 320–480 |
| 400-line budget risk | Medium |
| Chained PRs recommended | Yes |
| Suggested split | PR 1 → PR 2 → PR 3 |
| Delivery strategy | force-chained |
| Chain strategy | feature-branch-chain |

Decision needed before apply: Resolved
Chained PRs recommended: Yes
Chain strategy: feature-branch-chain
400-line budget risk: Medium

### Suggested Work Units

| Unit | Goal | Likely PR | Notes |
|------|------|-----------|-------|
| 1 | SDD governance + project init | PR 1 | state.yaml, package.json, .gitignore, config guardrails; base: feature/migrate-existing-planning-to-gentle-ai |
| 2 | Supabase local foundation | PR 2 | supabase init, initial migration, RLS helpers, EF scaffold; base: PR 1 branch; depends on PR 1 |
| 3 | Frontend + test infrastructure | PR 3 | Vue 3 static SPA scaffold, vitest.config.ts, tests/ dir, frontend runtime guardrail verification; base: PR 2 branch; depends on PR 2 |

## Phase 1: SDD Governance & Project Init

- [x] 1.1 Create `openspec/changes/migrate-existing-planning-to-gentle-ai/state.yaml` with DAG status `tasks` and dependency list for changes 2–11 per R10
- [x] 1.2 Create `package.json` with Vue 3, TypeScript, Supabase JS SDK, Vitest, Vue Test Utils, and Supabase CLI as devDependency (D6, D7)
- [x] 1.3 Create `.gitignore` (node_modules, dist, .supabase, .env.local) — verify Supabase-only constraint: no express/next/nest allowed per D1
- [x] 1.4 Verify `openspec/config.yaml` has `strict_tdd: false`, `test_command: "vitest run"`, `build_command: "npm run build"`; update if stale (R8)

**Verification 1**: `npm install` succeeds; no express/next/nest in dependencies; config.yaml reflects current project state.

## Phase 2: Supabase Local Foundation

- [x] 2.1 Run `npx supabase init` to create `supabase/` directory with `config.toml` and seed placeholder (D6)
- [x] 2.2 Create `supabase/migrations/00001_companies_branches_profiles.sql` with companies, branches, company_users, branch_users, profiles tables plus UUID PKs, audit columns (created_at, updated_at, created_by, updated_by), and `is_active` logical deletion per R5, R3, constitution principles 1–12 (source: constitution.md §1–12, plan_2da §14)
- [x] 2.3 Create `supabase/migrations/00002_rls_helpers.sql` with `get_company_id()`, `get_user_role()`, `get_user_branch_id()` SQL helper functions reading from JWT claims per D5 (source: plan_2da §15)
- [x] 2.4 Create `supabase/migrations/00003_rls_policies.sql` with RLS policies on companies, branches, company_users, branch_users per D5, R3 — admin sees own-company only, cashier sees assigned-branch only
- [x] 2.5 Create `supabase/functions/` directory with `supabase/functions/_shared/cors.ts` (CORS headers helper) and a placeholder `supabase/functions/health/index.ts` verifying Edge Function pattern per D3
- [x] 2.6 Run `npx supabase start` — verify local stack starts (Postgres, Auth, Studio) per D6. Fixed Windows Hyper-V port exclusion conflict by moving API (54321→55101), Studio (54323→55103), Inbucket (54324→55104), Pooler (54629→55109), Analytics (54327→54670) ports above the 53564–54663 excluded range. All migrations applied; 5 tables, 18 RLS policies, 6 helper functions verified; health EF responds successfully.

**Verification 2**: `npx supabase start` succeeds (ports moved above Windows Hyper-V excluded range); all 3 migrations applied; 5 tables created; 18 RLS policies verified; 6 helper functions present; health Edge Function responds with `{"success":true}`.

## Phase 3: Frontend & Test Infrastructure

- [x] 3.1 Create `src/` scaffold: `src/main.ts`, `src/App.vue`, `src/router/index.ts`, `src/views/HomeView.vue` — Vue 3 + TypeScript static SPA app with Supabase client initialized per D6, R7
- [x] 3.2 Create `vitest.config.ts` with Vue plugin, `jsdom` environment, and coverage config; create `tests/setup.ts` for Vue Test Utils per D7, R8
- [x] 3.3 Create `tests/` directory with `tests/supabase-rls.test.ts` placeholder (RLS policy test stub) and `tests/ef-auth.test.ts` placeholder (EF auth validation stub) per D7
- [x] 3.4 Create `src/lib/supabase.ts` exporting a Supabase client singleton with URL and anon key from env per D6
- [x] 3.5 Verify PR3 package/scripts/config preserve static frontend output only: no SSR mode, app server, Node runtime server, Next/Nuxt server, or frontend server runtime dependency; `npm run build` MUST produce static build artifacts only

**Verification 3**: `npx vitest run` succeeds with zero tests passing (no failures); `npm run build` compiles Vue static SPA without errors; package/scripts/config review confirms no SSR/server frontend runtime dependency.

## Phase 4: Guardrails & Source Traceability

- [x] 4.1 Add `(source: constitution.md §N)` traceability annotations to `openspec/changes/migrate-existing-planning-to-gentle-ai/specs/project-architecture/spec.md` for each requirement mapping per R9
- [x] 4.2 Verify all Phase 2–3 files enforce D1 (Supabase-only): no Express/Next/Nest imports; Edge Functions are sole backend logic entry for critical ops per D1, R1, R2
- [x] 4.3 Verify frontend runtime guardrail: package dependencies, scripts, build config, and scaffold files do not introduce SSR/server frameworks, Next/Nuxt server mode, a separate app server, Node runtime server, or external non-Supabase frontend runtime
- [x] 4.4 Verify all Phase 2–3 SQL files enforce R3 (RLS on all operational tables), R5 (logical deletion via `is_active`), and R6 (transactional via SECURITY DEFINER RPC pattern) per spec R1–R11

**Verification 4**: Traceability annotations present in spec.md; grep audit shows no express/next/nest in any created file; frontend package/scripts/config are static-SPA-only with no SSR/server runtime; RLS policies exist on all operational tables.

## Phase 5: Final Validation

- [x] 5.1 Run `npx supabase db reset` then `npx supabase db push` — verify fresh migration from scratch succeeds per D6
- [x] 5.2 Run `npx vitest run` — verify test runner operational per R8 (strict TDD still disabled)
- [x] 5.3 Update `state.yaml` status to `ready-for-verify`; verify chained roadmap references changes 2–11 per R10
- [x] 5.4 Manual review: all 11 spec requirements (R1–R11) have corresponding implementation or traceability in the bootstrap scaffold

**Verification 5**: All verifications pass; artifacts are internally consistent; original planning docs untouched in repo root.
