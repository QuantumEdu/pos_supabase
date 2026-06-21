# Delta for Project Architecture

## MODIFIED Requirements

### R7: Project Scaffold Foundation

<!-- source: plan_1ra §2, plan_2da §14, constitution §10, §12 -->
Reproducible local dev via Supabase CLI + Deno. No frontend app server, SSR runtime, or SPA build required.
- **Clone & setup**: CLI initializes local Supabase, applies migrations, starts backend. (source: plan_1ra §2)
- **Runtime**: Supabase CLI + Deno for Edge Functions. No Vue/Vite/Node frontend required. (source: constitution §10, §12)
- **Frontend consumers**: MAY connect via SDK+RLS for reads or EFs for critical ops. Frontend is NOT part of this project's scaffold. (source: constitution §10)
- **Deploy**: CLI pushes EFs, migrations, RLS to remote. (source: plan_1ra §2)

(Previously: R7 mandated "Vue 3 + TypeScript as a static client-side SPA build" — replaced with Supabase CLI + Deno EF workflow.)

#### Scenario: Setup from scratch

- GIVEN a machine with Supabase CLI and Deno installed
- WHEN the developer runs `supabase init` then `supabase start`
- THEN the local stack runs with all migrations applied and EFs servable

#### Scenario: No frontend build required

- GIVEN the project scaffold
- WHEN reviewing the project structure
- THEN there is NO `src/`, `index.html`, `vite.config.ts`, or Vue-related files
- AND `package.json` contains only Supabase CLI + Deno dev tooling

#### Scenario: Deploy to remote

- GIVEN local EFs and migrations tested
- WHEN running `supabase functions deploy` and `supabase db push --linked`
- THEN changes deploy to remote with no frontend build step

### R8: Test Infrastructure Foundation

<!-- source: constitution §10, §3 -->
Deno.test for EFs and `supabase test db` (pgTAP) for SQL/RLS MUST be configured before critical logic. Strict TDD disabled until runners verified.
- **Deno test**: EF unit/integration tests use `Deno.test()`. (source: constitution §10)
- **pgTAP**: SQL and RLS tests use `supabase test db`. (source: constitution §3, plan_2da §15)
- No runner → manual verification criteria in task specs.
- Runner operational → RED-GREEN-REFACTOR.

(Previously: R8 mandated "Vitest + Vue Test Utils" — replaced with Deno.test + pgTAP.)

#### Scenario: Run EF tests

- GIVEN an EF test file using `Deno.test()`
- WHEN running Deno test command
- THEN EF tests execute against local Supabase with pass/fail output

#### Scenario: Run SQL/RLS tests

- GIVEN a pgTAP test file in `supabase/tests/`
- WHEN running `supabase test db`
- THEN pgTAP tests execute, verifying RLS isolation per tenant

#### Scenario: TDD gate

- GIVEN `strict_tdd: false` in config
- WHEN runners are not yet verified operational
- THEN manual verification criteria MUST be in each task
- AND once both runners verified, `strict_tdd` MUST become `true`

## REMOVED Requirements

### Requirement: Vue 3 Frontend Scaffold

(Reason: Vue/Vite/SPA scaffold removed. Frontend consumers are out of scope — they MAY connect via SDK+RLS or EFs. Removes all npm-driven frontend build and test infrastructure, replaced by Supabase CLI + Deno.)

## MODIFIED Design Decisions

### D6: Supabase CLI Local Development Workflow

```
supabase init / start / migration new / db push / functions serve
supabase test db / deno test / db reset
supabase functions deploy / db push --linked
```

Scaffold: `supabase/` at project root (migrations, functions, config, tests). No frontend directory. `package.json` has Supabase CLI devDependency + scripts only.

(Previously: D6 described "monorepo root with `src/` (Vue 3)" — replaced with Supabase-only scaffold.)

### D7: Test Foundation Strategy

| Phase | Action | Strict TDD |
|-------|--------|------------|
| This change | Remove Vitest/Vue Test Utils. Establish `Deno.test` + pgTAP. Zero app tests. | Disabled |
| Scaffold verified | First EF test (auth validation). First SQL test (RLS isolation). | Re-evaluate |
| Domain changes (2–11) | Each task: Deno test + pgTAP criteria. | Enabled |

Runner verified = `deno test` and `supabase test db` both pass → enable `strict_tdd: true`.

(Previously: D7 specified "Vitest + Vue Test Utils" — replaced with Deno.test + pgTAP phases.)