# Proposal: Edge Functions-Only Module Architecture

## Intent

Pivot the project from a frontend/npm-driven bootstrap to an Edge Functions-only module architecture. The Supabase runtime layer (migrations, RLS, RPC, Edge Functions) is the sole authoritative runtime. The Vue/Vite frontend scaffold is removed entirely. This change realigns the repo structure, specs, and tooling to match the actual architecture: Supabase-first, with catalog-domain as the first real module to plan.

## Scope

### In Scope
- Remove all Vue/Vite/frontend scaffold files (`src/`, `index.html`, `vite.config.ts`, `vitest.config.ts`, `tests/` stubs, Vue-related `tsconfig` files, `env.d.ts`, `dist/`)
- Rewrite `package.json` as Supabase CLI + Deno tooling only (no Vue deps); remove `package-lock.json`
- Rewrite `tsconfig.json` for Deno/EF target instead of Vue/SPA
- Update `.gitignore` for Deno/EF workflow (remove frontend build artifacts)
- Replace Vitest test stubs with Deno test format for EFs and pgTAP for SQL/RLS
- Update `openspec/specs/project-architecture/spec.md`: modify R7 (remove Vue mandate, add Deno/Supabase CLI workflow), modify R8 (replace Vitest with Deno test + pgTAP), modify D6 and D7
- Update `openspec/config.yaml`: update stack description, `test_command`, remove `build_command` or replace with Supabase equivalent
- Update `supabase/config.toml` `auth.site_url` for EF-only architecture
- Plan catalog-domain as first module (migration schema, EF stubs, RLS policies, tests) — planning only, no implementation in this change

### Out of Scope
- Implementing catalog-domain migrations, EFs, or RPCs (separate downstream change)
- Creating a frontend application (explicitly deferred)
- Modifying existing `supabase/migrations/00001–00003` or deployed remote migrations
- Subscription tables (excluded per R11)

## Capabilities

### New Capabilities
- `catalog-domain`: Product catalog with brands, categories (hierarchical via `parent_id`), units, products, product variants, and product prices (separate `product_prices` table). EFs for critical mutations; SDK+RLS for reads.

### Modified Capabilities
- `project-architecture`: R7 removes Vue 3 mandate, replaces with Supabase CLI + Deno EF workflow. R8 replaces Vitest + Vue Test Utils with Deno test + pgTAP. D6 updates scaffold to EF-only. D7 updates test strategy.

## Approach

**Clean break with rollback safety.** Delete all frontend scaffold in one pass. Preserve `supabase/` directory and all deployed migrations untouched. Rewrite `package.json` for Supabase CLI + Deno tooling only. Replace test infrastructure with `Deno.test` for EFs and `supabase test db`/pgTAP for SQL/RLS. Update specs to remove Vue mandates. Create `catalog-domain` spec as delta spec planning the first module's schema, EFs, RLS policies, and test requirements.

## Affected Areas

| Area | Impact | Description |
|------|--------|-------------|
| `src/`, `index.html`, `vite.config.ts`, `vitest.config.ts`, `env.d.ts` | Removed | Frontend scaffold deleted entirely |
| `tests/setup.ts`, `tests/ef-auth.test.ts`, `tests/supabase-rls.test.ts` | Removed | Vitest stubs replaced by Deno/pgTAP |
| `package.json`, `package-lock.json` | Modified | Rewrite: Supabase CLI + Deno only; lock regenerates |
| `tsconfig.json`, `tsconfig.node.json` | Modified/Removed | Replace with Deno-focused config |
| `.gitignore` | Modified | Remove frontend build artifacts, add Deno/EF patterns |
| `openspec/specs/project-architecture/spec.md` | Modified | R7, R8, D6, D7 updated for EF-only architecture |
| `openspec/config.yaml` | Modified | Stack, test_command, build_command updated |
| `supabase/config.toml` | Modified | `auth.site_url` updated for EF-only |
| `supabase/migrations/00001–00003` | Preserved | No changes to deployed migrations |
| `supabase/functions/health/` | Preserved | Existing EF kept as-is |

## Risks

| Risk | Likelihood | Mitigation |
|------|------------|------------|
| CI/workflow breaks (assumes `npm run build`) | High | Update all npm scripts; remove build step; add `supabase test db` to CI |
| Test infrastructure gap (new Deno/pgTAP setup) | Med | Establish test runner before strict TDD re-enable; R8 keeps strict_tdd: false until runner verified |
| Spec drift if R7/R8 not updated before implementation | High | This change updates specs BEFORE any catalog-domain work |
| Future frontend consumer lacks TypeScript types | Low | Each domain module should export `EFResult<T>` types; catalog-domain spec will specify this |

## Rollback Plan

1. All removed frontend files are recoverable from git history (single commit removal)
2. `supabase/` directory and all migrations are untouched — no rollback needed there
3. Spec updates are reversible: revert the proposal/spec/design commits
4. `package.json` before-state is in git — `git revert` restores it
5. If rollback is needed before any catalog-domain implementation: `git revert` the entire change branch

## Dependencies

- Supabase CLI must support `supabase test db` (pgTAP) locally
- Deno runtime available for EF development and testing

## Success Criteria

- [ ] All Vue/Vite/frontend files removed; no Vue deps in `package.json`
- [ ] `package.json` contains only Supabase CLI + Deno tooling + test scripts
- [ ] `supabase start` succeeds with all 3 existing migrations applied
- [ ] `supabase test db` runs (even with 0 tests initially)
- [ ] Health EF still responds correctly after changes
- [ ] R7, R8, D6, D7 in `project-architecture/spec.md` reflect EF-only architecture
- [ ] `openspec/config.yaml` reflects EF-only stack, test_command, and build or lack thereof
- [ ] Catalog-domain delta spec created with schema, EF, RLS, and test requirements