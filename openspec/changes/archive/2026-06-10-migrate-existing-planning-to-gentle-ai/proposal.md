# Proposal: Migrate Existing Planning Docs into Gentle AI / OpenSpec SDD Artifacts

## Intent

Four existing planning documents (`constitution.md`, `spec.md`, `plan_1ra_parte.md`, `plan_2da_parte.md`) define the entire POS SaaS system but are not in SDD form. This change extracts their cross-cutting architectural invariants and project scaffold requirements into rigorous SDD artifacts, creating the constitutional foundation that all downstream domain changes will reference. Without this bootstrap, downstream specs would duplicate constitutional rules and risk drift.

## Scope

### In Scope

- Extract 12 constitution principles into architectural guardrails and design invariants
- Define project scaffold expectations (Supabase init, Vue 3 static SPA app, test runner setup)
- Capture Supabase-only + Edge-Functions-exclusive backend runtime and static-frontend-only deployment constraints formally
- Create minimal `project-architecture` spec covering cross-cutting rules
- Build a chained delivery roadmap mapping plan phases 0–12 to 10 downstream SDD changes
- Document open decisions (subscription tables, customer balances, Excel export)
- Preserve original docs as reference (no deletion)

### Out of Scope

- Per-domain specs (catalog, purchasing, inventory, etc.) — each gets its own change
- Source code implementation — this is a documentation/scaffold change only
- Edge Function or RPC implementations — downstream changes
- UI/screen specifications — downstream changes
- Resolving open decisions — documenting them as decision points only

## Capabilities

### New Capabilities

- `project-architecture`: Cross-cutting architectural invariants from constitution (inventory truth, traceability, consistency, audit, multi-tenancy, transactional integrity, security-by-default), Supabase-only runtime constraint, static frontend deployment guardrail, project scaffold conventions

### Modified Capabilities

None — no existing specs in `openspec/specs/` yet.

## Approach

**Constitution-First Bootstrap**: Extract the 12 principles from `constitution.md` as architectural guardrails in the design doc. Map `plan_1ra_parte.md` §0–3 and `plan_2da_parte.md` §14–17 into project scaffold tasks. Define the chained roadmap for 10 downstream domain changes (changes 2–11). Document open gaps as explicit decision points. Original planning docs remain in repo root as reference, deprecated once all content migrates to OpenSpec main specs.

## Affected Areas

| Area | Impact | Description |
|------|--------|-------------|
| `constitution.md` | Referenced | Source of invariants; preserved as-is |
| `spec.md` | Referenced | Source of domain rules; not extracted this change |
| `plan_1ra_parte.md` | Referenced | Source of phases 0–3 and architecture; not extracted this change |
| `plan_2da_parte.md` | Referenced | Source of DB/RLS/FEFO strategies; not extracted this change |
| `openspec/specs/` | New | Will receive `project-architecture/spec.md` after archive |
| `openspec/changes/migrate-existing-planning-to-gentle-ai/` | New | Proposal, specs, design, tasks |

## Risks

| Risk | Likelihood | Mitigation |
|------|------------|------------|
| Scope creep — trying to spec all 12 domains in one change | High | Strict scope: architecture constraints + roadmap only; explicit out-of-scope list |
| Drift between original docs and SDD artifacts after migration | Medium | Add "migrated from" notes; mark originals as deprecated once all changes archived |
| Missing test runner blocks downstream quality | High | Include Vitest + Vue Test Utils setup as a bootstrap task |
| Frontend framework drift introduces SSR/server runtime | Medium | Require Vue 3 only as static client-side build output; PR3 verification rejects SSR/server scripts, framework modes, and runtime dependencies |
| Subscription tables orphan — no business rules defined | Medium | Document as explicit out-of-scope decision point; exclude from MVP |
| `customer_balances` materialized-vs-computed decision unresolved | Medium | Document as decision point; resolve before `credit-payments-domain` change |
| Excel export library decision unresolved | Low | Document as decision point; resolve before `dashboard-reports-domain` change |

## Rollback Plan

This change produces only documentation and scaffold — no runtime code. If the SDD artifacts are wrong or incomplete:
1. Delete the change directory: `openspec/changes/migrate-existing-planning-to-gentle-ai/`
2. Original planning docs (`constitution.md`, etc.) are untouched in repo root
3. Re-create the proposal with corrected scope

No database migrations, no deployed code, no data loss risk.

## Dependencies

- Supabase CLI must be installable (for scaffold tasks)
- All four planning documents must remain available as source reference
- `openspec/config.yaml` already configured with correct rules

## Success Criteria

- [ ] Proposal captures all 12 constitution principles as architectural guardrails
- [ ] `project-architecture` capability spec defined with cross-cutting rules
- [ ] Chained roadmap lists all 10 downstream domain changes with source doc references
- [ ] Open decisions documented (subscription tables, customer balances, Excel export)
- [ ] Original planning docs untouched and referenced
- [ ] No per-domain business logic specs in this change (scope boundary held)
- [ ] Every spec uses English identifiers + RFC 2119 keywords per config.yaml rules
- [ ] Frontend deployment remains static SPA/build artifact only, with no separate app server, SSR server, Node runtime server, Next/Nuxt server, or external non-Supabase runtime
