# Exploration: Catalog Domain Implementation

## Current State

The project has a verified Edge Functions-only architecture scaffold (archived change `edge-functions-only-modules`):

### Foundation (preserved, must not modify)

| Component | Location | Status |
|-----------|----------|--------|
| Companies/Branches/Profiles/Company_Users/Branch_Users | `supabase/migrations/00001_*.sql` | ✅ Applied |
| RLS Helpers (get_company_id, get_user_role, is_admin, etc.) | `supabase/migrations/00002_*.sql` | ✅ Applied |
| RLS Policies on 5 foundation tables | `supabase/migrations/00003_*.sql` | ✅ Applied |
| Health Edge Function | `supabase/functions/health/index.ts` | ✅ Running |
| Auth validation helper (8-step steps 2-4) | `supabase/functions/_shared/auth.ts` | ✅ Ready |
| EFResult<T> type + ok()/fail() constructors | `supabase/functions/_shared/types.ts` | ✅ Ready |
| CORS headers helper | `supabase/functions/_shared/cors.ts` | ✅ Ready |
| Deno test runner (1 smoke test) | `supabase/functions/_test/smoke_test.ts` | ✅ Operational |
| pgTAP placeholder | `supabase/tests/.gitkeep` | ✅ Runner operational (0 tests) |
| package.json / deno.json / tsconfig.json / config.toml | Project root | ✅ Configured |

### Architecture Constraints (from project-architecture/spec.md R1–R11, D6–D13)

1. **R2**: Critical mutations MUST go EF → RPC. Frontend MUST NOT call RPC or modify operational tables directly.
2. **R3**: All operational tables enforce RLS. `company_id` is the primary tenant key.
3. **R5**: Logical deletion (`is_active`, `deleted_at`, `deleted_by`). Physical deletion PROHIBITED.
4. **R6**: Multi-table ops execute atomically. No partial states.
5. **R10**: Changes follow chained delivery roadmap. Catalog-domain is #2 (after bootstrap).
6. **D10**: Catalog schema blueprint exists: 6 tables (brands, categories, units, products, product_variants, product_prices).
7. **D11**: RPC boundary: `create_product_with_variant`, `deactivate_product`, `set_variant_price`.
8. **D12**: EF layout: `catalog/create-product`, `catalog/update-product`, `catalog/deactivate-product`.
9. **D13**: Testing: Deno.test for EFs, pgTAP for SQL/RLS.

### What Does NOT Exist Yet (this change must create)

| Need | Source Requirement | Estimated Lines |
|------|-------------------|-----------------|
| Migration `00004_catalog_domain.sql` (6 tables, constraints, indexes, triggers, RLS policies) | RC1–RC7, D10 | ~300-400 |
| 3 RPC functions (create, deactivate, set_price) | D11, RC6 | ~150-200 |
| 3+ catalog Edge Functions | D12, RC6 | ~200-300 |
| Catalog-specific Deno.test (EF auth validation, RPC invocation) | RC6, D13 | ~100-150 |
| Catalog-specific pgTAP tests (RLS isolation, unique constraints, cycle detection) | RC7, D13 | ~200-300 |
| Simple CRUD EFs for brands, categories, units | RC1–RC3 | ~150-200 |
| `set_updated_at` trigger applied to 6 new tables | R5 | ~10 (reuse existing function) |

---

## Affected Areas

- `supabase/migrations/` — New migration file `00004_catalog_domain.sql` (tables, indexes, triggers, RLS)
- `supabase/functions/_shared/auth.ts` — Consumption by new catalog EFs (no changes needed, just usage)
- `supabase/functions/_shared/types.ts` — Consumption by new catalog EFs (no changes needed)
- `supabase/functions/catalog/` — New EF directory with 3+ Edge Functions
- `supabase/functions/_test/` — New EF integration tests
- `supabase/tests/` — New pgTAP test files (RLS, constraints, RPCs)
- `openspec/specs/catalog-domain/spec.md` — Main spec (read-only during this change, possibly needs delta for implementation details)
- `openspec/changes/catalog-domain-implementation/` — SDD artifacts for this change

---

## Approaches

### 1. Full Catalog in One Change — Monolithic

Implement all 6 tables, all RPCs, all EFs, all tests in a single change with multiple chained PRs.

- **Pros**: Single design doc, single spec delta, atomic delivery
- **Cons**: Large review surface (4 PRs × ~300 lines = ~1200 total lines to review); any blocker in one PR pauses all; high coordination cost
- **Effort**: High (but well-structured via feature-branch-chain)

### 2. Two-Phase Catalog — Schema First, then EF+RPC

Phase A: Tables + RLS + tests (migration-only, no logic). Phase B: RPCs + EFs + EF tests.

- **Pros**: Schema can be verified independently; cleaner separation of concerns; if schema changes, RPCs aren't blocked
- **Cons**: Two separate SDD changes required; schema-first means catalog is "read-only" via SDK until EFs exist; more coordination between changes
- **Effort**: Medium per phase, Higher total

### 3. Core Entity First (Products/Variants/Prices), then Metadata (Brands/Categories/Units)

Implement the critical path first (products → variants → prices) as a single change, then brands/categories/units as a second change.

- **Pros**: Delivers the most business-critical entity first; metadata (brands, categories, units) can use SDK+RLS for admin CRUD without EFs per RC6
- **Cons**: Products depend on brands and categories via FK; need nullable FKs or deferred constraints to implement products first; creates schema coupling risk
- **Effort**: Medium

---

## Recommendation

**Approach 1: Full Catalog in One Change** — with feature-branch-chain into 3-4 reviewable PR slices under the 400-line budget each.

**Why**:

1. The 6 tables are strongly interconnected via FKs (products reference brands and categories; variants reference products; prices reference variants). Splitting them across changes creates schema coupling or nullable-FK hacks.
2. The D10 design already specified all 6 tables in one blueprint. The archived change explicitly stated "Catalog-domain schema, RPCs, and catalog EFs are designed here, implemented in the next change."
3. RC6 specifies that brands, categories, and units mutations also go through EF→RPC for admin. Making them SDK+RLS-only would violate RC6.
4. Feature-branch-chain means each PR is reviewable at ~300 lines, staying well under the 400-line budget.

**Recommended Slicing**:

| PR | Slice | Content | Est. Lines |
|----|-------|---------|------------|
| 1 | Schema + RLS | `00004_catalog_domain.sql`: all 6 tables, indexes, unique constraints, cycle-prevention trigger, audit triggers, RLS policies + pgTAP tests for RLS isolation and unique constraints | ~350-400 |
| 2 | RPC Functions | SQL functions: `create_product_with_variant`, `deactivate_product`, `set_variant_price` + simple CRUD RPCs for brands, categories, units + pgTAP tests for RPC behavior | ~250-300 |
| 3 | Catalog EFs + Tests | `catalog/create-product`, `catalog/update-product`, `catalog/deactivate-product` + CRUD EFs for brands, categories, units + Deno.test integration tests | ~300-350 |
| 4 | Verify + Spec Alignment | Run `supabase db reset`, `deno test`, `supabase test db`, update delta spec if needed, verify all RC scenarios | ~50-100 |

**Chain strategy**: feature-branch-chain — PR 1 targets `feature/catalog-domain`, PR 2 targets PR 1 branch, PR 3 targets PR 2 branch, PR 4 targets PR 3 branch.

---

## Risks

1. **Barcode NULL partial unique index** — PostgreSQL correctly excludes NULLs from `UNIQUE WHERE barcode IS NOT NULL`, but this needs explicit pgTAP test coverage. A row with `barcode = NULL` should not conflict with another NULL-barcode row.

2. **Category cycle detection trigger performance** — The BEFORE UPDATE trigger that walks the ancestor chain to prevent cycles (`A → B → A`) can be expensive for deep hierarchies. Mitigation: limit hierarchy depth (e.g., max 5 levels) in the trigger, or document the expected max depth.

3. **Concurrent price updates race condition** — Two admins setting a new price on the same variant simultaneously could create two "active" prices (both with `effective_until IS NULL`). The `set_variant_price` RPC MUST use `SELECT ... FOR UPDATE` or `SERIALIZABLE` isolation to serialize concurrent calls.

4. **Large RPC parameter count** — `create_product_with_variant` has 9 parameters (per D11). This makes the EF→RPC call fragile and hard to extend. Alternative: accept a JSON parameter and parse inside the RPC. This is a design decision for the proposal phase.

5. **Defense in depth on RPC security** — RPCs run as `SECURITY DEFINER` (bypasses RLS). The EF validates auth, but the RPC MUST independently verify `company_id` matches the calling user's company. Never trust EF input alone for tenant isolation.

6. **Migration conflict with future remote DB** — Currently local-only, but once this migration is applied remotely, `00004` cannot be reordered. Ensure DDL is correct before first remote deployment.

---

## Questions Before Proposal

These are product/business questions that MUST be answered before creating the proposal:

1. **SKU format and uniqueness**: Is SKU case-sensitive or case-insensitive? Should the system auto-generate SKU if not provided, or is it always user-supplied? The spec says "unique per company" but doesn't specify case behavior or auto-generation.

2. **Barcode requirement**: Is barcode optional or required for variants? The spec says `(company_id, barcode) UNIQUE WHERE barcode NOT NULL` which implies optional. Confirm: can a variant be created without a barcode?

3. **Price history behavior**: When setting a new price, should `effective_until` of the previous price be set to `NOW()` or to the exact `effective_from` of the new price? If `effective_from` is future-dated, what is the price in the gap between NOW() and effective_from? Can there be multiple future-dated prices?

4. **Price deletion/modification**: Can an active price be edited, or is the temporal model append-only (only close existing + create new)? Should `product_prices` have `is_active` / logical deletion, or are closed prices simply immutable historical records?

5. **Category hierarchy limits**: Should there be a maximum depth limit for category nesting (e.g., max 3 or 5 levels)? Deep hierarchies affect query performance and UX.

6. **Variant naming convention**: The spec mentions `name` on variants, and `spec.md §8` mentions "Presentación" (presentation/size) as part of a variant. Is variant.name the human-readable label like "Chocolate 2kg", or is it a separate field like "2kg presentation"? Should we also store presentation/size as separate columns?

7. **Brand/Category/Unit CRUD via EF**: RC6 says mutations go through EF→RPC for admin. Should brand create/update/deactivate, category create/update/deactivate, and unit create/update/deactivate each have their own EFs, or should we use a generic CRUD approach with a single catalog EF that handles multiple entity types?

8. **Default units**: Should the system provide default units (e.g., "Unidad", "Cápsulas") per company, or does every company create units from scratch? The spec says company-scoped but doesn't clarify seed data.

9. **Currency handling**: D10 shows `currency TEXT DEFAULT 'USD'`. The product is for Spanish-speaking markets (Mexico/LatAm). Should the default currency be 'MXN'? Or is 'USD' correct for multi-tenant SaaS? Should currency be per-company or per-price?

10. **Slug auto-generation**: Should the system auto-generate slugs from names (e.g., "NOW Foods" → "now-foods"), or does the admin always provide the slug explicitly?

---

## Ready for Proposal

**No** — There are 10 open product/business questions (listed above) that must be answered before the proposal can define scope accurately. The orchestrator should present these questions to the user and collect answers.

Once answered, the proposal will:
1. Define exact scope (all 6 tables + EFs + RPCs or a subset)
2. Confirm slicing strategy
3. Specify the main spec's sufficiency (it covers RC1–RC7 at requirements level; a delta spec will add implementation-level DDL, RPC signatures, and EF contracts)
4. Set the rollback plan per PR slice

---

## Main Spec Sufficiency Assessment

The current `openspec/specs/catalog-domain/spec.md` (RC1–RC7) is **sufficient at the requirements level** for this change. It defines:

- RC1–RC5: Business rules for brands, categories, units, products/variants, prices
- RC6: EF mutation boundary (EF→RPC for mutations, SDK+RLS for reads)
- RC7: RLS multi-tenant isolation for all 6 tables

However, it does NOT include:
- Exact column definitions, types, and constraints
- RPC function signatures and parameter types
- EF endpoint paths, request/response shapes
- Test scenario specifications for each requirement

**This change WILL need a delta spec** that ADDs these implementation details, but the main spec requires NO modifications — it already defines the correct requirements. The delta spec will complement, not replace, the main spec.

---

## Architecture Observations

### Reusable Patterns from Foundation

1. **`set_updated_at()` trigger** — Already defined in migration 00001. New catalog tables simply add `CREATE TRIGGER set_updated_at BEFORE UPDATE ON public.<table> FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();` — no new function needed.

2. **RLS policy pattern** — Migration 00003 establishes a clear pattern:
   - SELECT: `company_id = get_company_id()` (possibly with role branching)
   - INSERT/UPDATE: `company_id = get_company_id() AND is_admin()`
   - SERVICE ROLE: Full bypass
   - Catalog tables follow this pattern identically.

3. **EF 8-step pattern** — `_shared/auth.ts` handles steps 2–4. New EFs follow: CORS (step 1) → validateAuth (steps 2–4) → validate input (step 5) → invoke RPC (step 6) → audit (step 7) → return EFResult (step 8).

4. **`EFResult<T>`** pattern — All EF responses use `{ success, data?, error? }` shape.

### New Patterns Needed

1. **Category cycle detection trigger** — New BEFORE UPDATE trigger on `categories.parent_id` that walks ancestor chain to prevent cycles.

2. **Temporal price uniqueness** — Partial unique index `(variant_id) WHERE effective_until IS NULL` — new pattern for this project.

3. **Multi-table RPC atomicity** — `create_product_with_variant` inserts into 3 tables (products, product_variants, product_prices) atomically — first multi-table RPC in the project.

4. **Concurrent price update safety** — `SELECT ... FOR UPDATE` on active price row before closing — new locking pattern.