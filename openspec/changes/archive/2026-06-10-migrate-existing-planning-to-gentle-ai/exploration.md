## Exploration: Migrate Existing Planning Docs into Gentle AI / OpenSpec SDD Artifacts

### Current State

The project `Pos_supabase` is in **pre-development** — no source code, no `package.json`, no test infrastructure. Four planning documents exist in the workspace root:

| Document | Lines | Content | SDD Artifact Mapping |
|----------|-------|---------|---------------------|
| `constitution.md` | 229 | 12 business principles (inventory truth, traceability, consistency, audit) | **Proposal** (intent + constraints) + **Design** (architectural invariants) |
| `spec.md` | 675 | 34-section functional spec (entities, flows, rules, users, reports) | **Specs** (delta → main specs per domain) |
| `plan_1ra_parte.md` | 1006 | Phases 0–12, table models, Edge Functions, RPC SQL, screens | **Tasks** (implementation phases) + **Design** (architecture diagram, Edge Function strategy, RPC strategy) |
| `plan_2da_parte.md` | 755 | DB conventions, RLS strategy, FEFO, demand, credit, returns, audit, dashboard | **Design** (technical design document) + **Specs** (domain rules) |

OpenSpec scaffolding already exists (`config.yaml`, empty `specs/`, empty `changes/archive/`). Engram has `sdd-init/Pos_supabase` and `sdd/Pos_supabase/testing-capabilities` cached.

### Affected Areas

- `constitution.md` — Source document; will be preserved as-is but its content must be extracted into SDD artifacts
- `spec.md` — Source document; primary material for delta specs across multiple domains
- `plan_1ra_parte.md` — Source document; maps to design doc and task breakdown
- `plan_2da_parte.md` — Source document; deep design strategy material
- `openspec/config.yaml` — Already configured; rules align with existing docs (no changes needed)
- `openspec/specs/` — Currently empty; will receive main specs after first archive
- `openspec/changes/migrate-existing-planning-to-gentle-ai/` — Change directory for this migration

### Approaches

1. **Single Mega-Change** — One SDD change `migrate-existing-planning-to-gentle-ai` containing all proposal + specs + design + tasks
   - Pros: Simple to manage, one coherent artifact set, all content migrates together
   - Cons: Enormous scope — 12+ business domains in one change; violates the "one business domain at a time" rule from config.yaml; review budget of 400 lines would be blown on any single PR
   - Effort: **Rejected** — violates project rules

2. **Constitution-First Bootstrap** — One initial change to capture constitution as architectural constraints and project-level design, then per-domain chained changes for each business module
   - Pros: Respects "scope changes to one business domain at a time" rule; constitution principles become reusable constraints in every subsequent change; natural ordering aligns with plan phases; chained PR strategy maps perfectly
   - Cons: More changes to manage; requires careful dependency tracking between changes
   - Effort: Medium (coordination overhead, but clean separation)

3. **Domain-Only Changes (No Bootstrap)** — Skip the constitution change, embed constraints directly into each domain spec
   - Pros: Fewer changes; each change is self-contained
   - Cons: Duplicates constitutional rules across 8+ domain specs; drift risk if rules evolve; no single source of truth for architectural invariants
   - Effort: Medium-High (drift management becomes a burden)

### Recommendation

**Approach 2: Constitution-First Bootstrap with Chained Domain Changes**

Rationale:
- The constitution contains **cross-cutting invariants** (inventory truth, traceability, consistency, audit) that every domain must respect. These belong in the **design document**, not duplicated per-domain.
- The existing plan already defines a clear phase ordering (0→12) that maps naturally to chained SDD changes.
- The forced chained-PR delivery strategy (400-line review budget) makes large monolithic changes impractical anyway.
- This change (`migrate-existing-planning-to-gentle-ai`) should produce: proposal, specs for the **constitution/architecture domain**, design doc, and a master task list that spawns subsequent per-domain changes.

**Recommended change breakdown:**

| Change # | Name | Scope | Source |
|----------|------|-------|--------|
| 1 | `bootstrap-architecture` | Constitution principles → design constraints, project scaffold, Supabase setup | constitution.md + plan §0–3 + plan_2da §14–17 |
| 2 | `catalog-domain` | Brands, categories, units, products, variants | spec §8–11, plan §2 |
| 3 | `purchasing-domain` | Suppliers, purchase orders, receipts | spec §12, plan §3 |
| 4 | `inventory-domain` | Inventory, lots, FEFO, movements, adjustments | spec §14–19, plan §4 |
| 5 | `customers-demand-domain` | Customers, requests, preorders, reservations | spec §13,22, plan §5 |
| 6 | `pos-sales-domain` | POS, sales, payments, discounts | spec §20–21, plan §6 |
| 7 | `cash-session-domain` | Cash open/close, movements | spec §25, plan §7 |
| 8 | `credit-payments-domain` | Credit, payments, balances | spec §23–24, plan §8 |
| 9 | `returns-domain` | Returns, cancellations | spec §26, plan §9 |
| 10 | `dashboard-reports-domain` | Dashboard, reports, exports | spec §28–30, plan §10–12 |
| 11 | `audit-domain` | Audit logs, trail | spec §27, plan §11 |

Change 1 is this migration change. Changes 2–11 are **downstream** and should be created as separate SDD changes after this one is archived.

### Gaps and Contradictions to Resolve

1. **No source code exists** — The plan references Vue 3 + TypeScript + Supabase but no project has been scaffolded. The first task in `bootstrap-architecture` MUST include `supabase init` + Vue 3 project creation.

2. **Spec uses Spanish section headers, SDD specs should use English** — `spec.md` is in Spanish; SDD delta specs should use English identifiers and RFC 2119 keywords per `config.yaml` rules. Business terms (product, variant, etc.) stay English in code.

3. **plan_1ra and plan_2da overlap on sections 13** — Both files end/start with "Principio Final" §13. This is a split artifact; no real contradiction, just a continuation.

4. **Subscription plans table with no domain coverage** — `subscription_plans` and `company_subscriptions` appear in the table model but have no spec section, no business rules, and no Edge Functions defined. This is **out of scope for MVP** or needs explicit clarification.

5. **No test infrastructure** — Strict TDD is disabled. The bootstrap change should set up Vitest + Vue Test Utils as a task, then re-enable strict TDD.

6. **Edge Function naming inconsistency** — `plan_1ra` lists `cancel-purchase-order` as an Edge Function but it has no corresponding RPC in the RPC list. Either the EF calls an existing RPC or a new `cancel_purchase_transaction()` is needed.

7. **customer_balances vs. computed** — The plan shows `customer_balances` as a table, but the spec implies balances should be computed from sales and payments. Decision needed: materialized view, trigger-maintained table, or always-computed?

8. **Export format ambiguity** — Spec says "Excel" but Supabase Edge Functions don't natively produce XLSX. Need design decision: CSV-only for MVP, or use a library like `xlsx` in Edge Function?

### Artifact Strategy for Hybrid Mode

| Artifact | Engram topic_key | OpenSpec Path |
|----------|-----------------|---------------|
| Exploration | `sdd/migrate-existing-planning-to-gentle-ai/explore` | `openspec/changes/migrate-existing-planning-to-gentle-ai/exploration.md` |
| Proposal | `sdd/migrate-existing-planning-to-gentle-ai/proposal` | `openspec/changes/migrate-existing-planning-to-gentle-ai/proposal.md` |
| Specs | `sdd/migrate-existing-planning-to-gentle-ai/specs/{domain}` | `openspec/changes/migrate-existing-planning-to-gentle-ai/specs/{domain}/spec.md` |
| Design | `sdd/migrate-existing-planning-to-gentle-ai/design` | `openspec/changes/migrate-existing-planning-to-gentle-ai/design.md` |
| Tasks | `sdd/migrate-existing-planning-to-gentle-ai/tasks` | `openspec/changes/migrate-existing-planning-to-gentle-ai/tasks.md` |

**Preserving the Supabase-only constraint**: Every design doc, spec, and task MUST include a constraint check:
- "Runtime: Supabase-only — no external backend frameworks"
- "Backend logic: Edge Functions exclusively"
- Any task that would require Express, Next.js API routes, or similar MUST be rejected at proposal review.

### Risks

- **Scope creep** — The constitution is broad; the bootstrap change could balloon if it tries to spec all 12 domains. Must constrain to architecture-level concerns only.
- **Source doc preservation** — Original docs should remain in repo root as reference (not deleted) until all content is fully migrated and archived into OpenSpec main specs.
- **Drift between original docs and SDD artifacts** — If the user edits constitution.md or spec.md after migration, the SDD artifacts may diverge. Recommend: add a "migrated from" note and deprecate original docs once all changes are archived.
- **Missing test runner blocks downstream quality** — Without Vitest configured, no TDD discipline can be enforced. Bootstrap MUST include test setup as a critical task.
- **Subscription plans orphan** — Tables defined but no business rules. Must be explicitly excluded or given minimal spec.
- **customer_balances design decision** — Materialized vs. computed affects multiple domains. Must resolve before `credit-payments-domain` change.

### Ready for Proposal

**Yes.** The next phase should be **`sdd-propose`** for the `migrate-existing-planning-to-gentle-ai` change.

The proposal should:
1. Define the intent: migrate existing planning documents into Gentle AI / OpenSpec SDD artifacts
2. Scope: constitution principles → architectural design constraints + project scaffold plan (Phase 0 equivalent)
3. Approach: Extract cross-cutting invariants from constitution into design, create minimal bootstrap spec, define the chained change roadmap for domains 2–11
4. NOT attempt to spec all 12 domains in this change — each domain gets its own change after this one is archived

What the orchestrator should tell the user: "Exploration complete. The existing docs map cleanly to SDD artifacts but the scope is too large for one change. I recommend a constitution-first bootstrap change that captures architectural constraints and scaffolds the project, followed by 10 chained domain changes. Ready to proceed with the proposal for the bootstrap change."
