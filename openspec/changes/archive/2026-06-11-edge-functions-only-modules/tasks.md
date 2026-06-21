# Tasks: Edge Functions-Only Module Architecture

## Review Workload Forecast

| Field | Value |
|-------|-------|
| Estimated changed lines | 550–700 |
| 400-line budget risk | Medium |
| Chained PRs recommended | Yes |
| Suggested split | PR 1 (scaffold cleanup ~320 lines) → PR 2 (EF infra ~150 lines) → PR 3 (spec/config ~180 lines) |
| Delivery strategy | force-chained |
| Chain strategy | feature-branch-chain |

Decision needed before apply: No
Chained PRs recommended: Yes
Chain strategy: feature-branch-chain
400-line budget risk: Medium

### Suggested Work Units

| Unit | Goal | Likely PR | Notes |
|------|------|-----------|-------|
| 1 | Remove frontend scaffold; rewrite package.json, tsconfig, .gitignore; delete package-lock.json | PR 1 | Base: feature/edge-functions-only-modules; standalone compilable |
| 2 | Add deno.json, _shared/auth.ts, _shared/types.ts, test .gitkeep, update config.toml | PR 2 | Base: PR 1 branch; additive — no broken intermediate state |
| 3 | Update openspec/specs/project-architecture/spec.md and config.yaml; verify stack starts | PR 3 | Base: PR 2 branch; docs/spec alignment, verification |

## Phase 1: Frontend Scaffold Removal

- [x] 1.1 Delete `src/App.vue`, `src/main.ts`, `src/lib/supabase.ts`, `src/router/index.ts`, `src/views/HomeView.vue` — remove entire `src/` directory
- [x] 1.2 Delete `index.html` — SPA entry point no longer needed
- [x] 1.3 Delete `vite.config.ts` — Vite build config replaced by Deno
- [x] 1.4 Delete `vitest.config.ts` — Vitest config replaced by Deno.test
- [x] 1.5 Delete `env.d.ts` — Vue/Vite env types no longer needed
- [x] 1.6 Delete `tsconfig.node.json` — Node/Vite config no longer needed
- [x] 1.7 Delete `tests/setup.ts`, `tests/ef-auth.test.ts`, `tests/supabase-rls.test.ts` — remove entire `tests/` directory (Vitest stubs)
- [x] 1.8 Rewrite `package.json` — remove Vue/Vite/Vitest deps and scripts; keep `supabase` devDependency; add scripts: `test:ef` (`deno test supabase/functions/_test/`), `test:db` (`supabase test db`), `test:all` (run both), `db:reset` (`supabase db reset`)
- [x] 1.9 Delete `package-lock.json` — will regenerate on next `npm install`
- [x] 1.10 Rewrite `tsconfig.json` — retarget Deno/EF: remove DOM/DOM.Iterable libs and Vue paths, add `deno-types` reference, set `"module": "ESNext"`, `"moduleResolution": "bundler"`, `"include": ["supabase/functions/**/*.ts"]`
- [x] 1.11 Update `.gitignore` — remove `dist/`, `coverage/`; add `.deno/`, `supabase/.temp/`

## Phase 2: Deno/EF Infrastructure

- [x] 2.1 Create `deno.json` — tasks: `test`, `test:ef`, `test:db`, `lint`; import-map pointing `supabase/functions/_shared/`; `lint.include`: `["supabase/functions/"]`
- [x] 2.2 Create `supabase/functions/_shared/types.ts` — define `EFResult<T> = { success: boolean; data?: T; error?: { code: string; message: string } }` type (source: D12)
- [x] 2.3 Create `supabase/functions/_shared/auth.ts` — `validateAuth(req, requiredRole)` helper implementing D3 8-step pattern: extract JWT → verify with Supabase Auth → extract company_id → validate role → return `{ user, companyId, role }` or throw `EFResult` error (source: D3, D12)
- [x] 2.4 Create `supabase/tests/.gitkeep` — placeholder for pgTAP test directory
- [x] 2.5 Update `supabase/config.toml` — change `auth.site_url` from `"http://127.0.0.1:3000"` to `"http://127.0.0.1:5173"` per EF-only architecture; also updated `additional_redirect_urls`

## Phase 3: Spec and Config Alignment

- [x] 3.1 Update `openspec/specs/project-architecture/spec.md` — replace R7 (R7: Project Scaffold Foundation) with Supabase CLI + Deno wording from delta spec; replace R8 (R8: Test Infrastructure Foundation) with Deno.test + pgTAP wording; replace D6 (D6: Supabase CLI Local Development Workflow) scaffold description; replace D7 (D7: Test Foundation Strategy) with Deno/pgTAP phases; remove any Vue/Vitest references
- [x] 3.2 Update `openspec/config.yaml` — `context.Stack`: remove Vue 3, replace with "Supabase CLI, Deno, PostgreSQL, RLS, Edge Functions"; `context.Frontend`: remove "Vue 3 + TypeScript"; `rules.apply.test_command`: change to `"deno test supabase/functions/_test/"`; `rules.apply.build_command`: remove or set to `"supabase db reset"`; `rules.verify.test_command`: change to `"deno test supabase/functions/_test/"`; `rules.verify.build_command`: remove or set to `"supabase start"`

## Phase 4: Verification

- [x] 4.1 Verify `supabase start` succeeds — all 3 existing migrations applied, no errors
- [x] 4.2 Verify health EF responds — `supabase functions serve health` returns `{"success":true,"data":{"status":"healthy"}}` via local invocation
- [x] 4.3 Verify `deno test` runs — exits 0 even with zero test files (runner operational)
- [x] 4.4 Verify `supabase test db` runs — exits 0 even with zero pgTAP test files (runner operational)
- [x] 4.5 Verify no Vue/Vite/Vitest references remain — `grep -r "vue\|vite\|vitest" package.json tsconfig.json .gitignore` returns empty