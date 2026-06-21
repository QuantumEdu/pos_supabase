# Proposal: Catalog Domain Implementation

## Intent

Establish the catalog foundation — brands, categories, units, products, variants, and prices — as change #2 in the chained delivery roadmap (R10). The bootstrap architecture is archived and verified; this change implements the six catalog tables, RPCs, Edge Functions, RLS policies, and tests per RC1–RC7 and D10–D13.

## Scope

### In Scope

- Migration `00004_catalog_domain.sql`: 6 tables (brands, categories, units, products, product_variants, product_prices), indexes, unique constraints, FKs, audit triggers, cycle-prevention trigger, RLS policies
- 3 critical RPCs: `create_product_with_variant`, `deactivate_product`, `set_variant_price` + simple CRUD RPCs for brands, categories, units
- Catalog Edge Functions: `catalog/create-product`, `catalog/update-product`, `catalog/deactivate-product` + CRUD EFs for brands, categories, units
- pgTAP tests for RLS isolation, unique constraints, cycle detection, RPC behavior
- Deno.test integration tests for catalog EFs (auth validation, RPC invocation, EFResult shapes)
- Seed data for base units, default currency (MXN)

### Out of Scope

- Purchases, inventory movements, sales/POS, cash sessions
- Frontend / UI / npm-driven app
- Reporting / dashboard
- Subscription management, customer balances

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `catalog-domain`: Adding implementation-level requirements — DDL column definitions and constraints (case-insensitive SKU unique, nullable barcode partial index, category depth ≤ 5, temporal prices, `product_variants.name` as human-readable label, default currency MXN), RPC function signatures, EF endpoint contracts, and test scenario specifications. Existing RC1–RC7 requirements remain unchanged.

## Approach

Single change with 4 feature-branch-chain PR slices:

| PR | Slice | Content | Est. Lines |
|----|-------|---------|------------|
| 1 | Schema + RLS | Migration: all 6 tables, indexes, unique constraints, cycle-prevention trigger, audit triggers, RLS policies + pgTAP tests | ~350–400 |
| 2 | RPC Functions | SQL functions: `create_product_with_variant`, `deactivate_product`, `set_variant_price`, CRUD RPCs for brands/categories/units + pgTAP tests | ~250–300 |
| 3 | Catalog EFs + Tests | `catalog/create-product`, `catalog/update-product`, `catalog/deactivate-product`, CRUD EFs for brands/categories/units + Deno.test integration | ~300–350 |
| 4 | Verify + Spec Alignment | `supabase db reset`, `deno test`, `supabase test db`, verify RC scenarios, update delta spec if needed | ~50–100 |

Chain strategy: feature-branch-chain — PR 1 → `feature/catalog-domain`, PR 2 → PR 1 branch, PR 3 → PR 2 branch, PR 4 → PR 3 branch.

**Approved business rules**: SKU case-insensitive unique, SKU auto-generated if absent, barcode optional (partial unique index), new prices close previous at `new.effective_from`, future prices allowed if non-overlapping, category depth max 5, `variant.name` = human-readable label, separate EFs per critical op, base units seeded + company-editable, default currency MXN.

## Affected Areas

| Area | Impact | Description |
|------|--------|-------------|
| `supabase/migrations/` | New | `00004_catalog_domain.sql` |
| `supabase/functions/catalog/` | New | 3+ critical EFs, 3+ CRUD EFs |
| `supabase/functions/_shared/` | Modified | May add catalog-specific input validators |
| `supabase/functions/_test/` | New | Deno.test files for catalog EFs |
| `supabase/tests/` | New | pgTAP test files |
| `openspec/specs/catalog-domain/` | Modified | Delta spec with implementation details |

## Risks

| Risk | Likelihood | Mitigation |
|------|------------|------------|
| Concurrent price updates create duplicate active prices | Med | `SELECT ... FOR UPDATE` in `set_variant_price` RPC |
| Category cycle detection performance on deep hierarchies | Low | Enforce max depth 5 in trigger |
| Barcode NULL partial unique index edge case | Low | Explicit pgTAP test: NULL barcodes must not conflict |
| `SECURITY DEFINER` RPCs bypass RLS | Med | RPC MUST independently verify `company_id` matches caller's company |
| Migration ordering conflict once deployed remotely | Low | Validate DDL locally with `db reset` before remote push |

## Rollback Plan

Each PR slice can be reverted independently. Full rollback: drop migration `00004`, remove `catalog/` EF directory, remove test files. Since this is a new domain (no existing data), rollback is clean — no data migration to reverse.

## Dependencies

- Bootstrap architecture must remain applied (migrations 00001–00003, health EF, auth helpers)
- Supabase CLI + Deno runtime operational locally

## Success Criteria

- [ ] `supabase db reset` succeeds with all 6 catalog tables created
- [ ] All RLS policies pass tenant isolation tests (company A cannot see company B data)
- [ ] Category cycle detection blocks circular `parent_id` chains; depth > 5 rejected
- [ ] `create_product_with_variant` RPC atomically creates product + variant + initial price
- [ ] `set_variant_price` closes previous active price at `new.effective_from`; concurrent calls serialized
- [ ] `deactivate_product` logically deletes product and all variants
- [ ] All catalog EFs follow 8-step pattern returning `EFResult<T>`
- [ ] SKU uniqueness is case-insensitive; auto-generated when absent
- [ ] `deno test` and `supabase test db` pass with ≥ 0 coverage threshold