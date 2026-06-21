# Tasks: Catalog Domain Implementation

## Review Workload Forecast

| Field | Value |
|-------|-------|
| Estimated changed lines | ~1050–1150 |
| 400-line budget risk | High |
| Chained PRs recommended | Yes |
| Suggested split | PR 1 → PR 2 → PR 3 → PR 4 |
| Delivery strategy | force-chained |
| Chain strategy | feature-branch-chain |

Decision needed before apply: No
Chained PRs recommended: Yes
Chain strategy: feature-branch-chain
400-line budget risk: High

### Suggested Work Units

| Unit | Goal | Likely PR | Notes |
|------|------|-----------|-------|
| 1 | Schema + RLS + pgTAP constraint/RLS tests | PR 1 | Base: `feature/catalog-domain`; ~380 lines |
| 2 | RPC functions + pgTAP RPC tests | PR 2 | Base: PR 1 branch; ~280 lines |
| 3 | Edge Functions + shared validation + Deno tests | PR 3 | Base: PR 2 branch; ~350 lines |
| 4 | Final verification + spec alignment | PR 4 | Base: PR 3 branch; ~80 lines |

## Phase 1: Schema + RLS (PR 1)

- [x] 1.1 Create `supabase/migrations/00004_catalog_domain.sql`: tables `brands`, `categories`, `units`, `products`, `product_variants`, `product_prices` with all columns, constraints, indexes per design spec
- [x] 1.2 Add `prevent_category_cycle()` BEFORE INSERT/UPDATE trigger on `categories` — walk parent chain, reject cycles and depth > 5
- [x] 1.3 Add `set_updated_at` trigger on all 6 catalog tables (reuse function from 00001)
- [x] 1.4 Add seed data: 8 base units with `company_id = '00000000-0000-0000-000000000000'`
- [x] 1.5 Add RLS policies: `SELECT … USING (company_id = get_company_id())`, `INSERT/UPDATE … WITH CHECK (company_id = get_company_id() AND is_admin())`, `service_role ALL` — for all 6 tables, no DELETE policies
- [x] 1.6 Create `supabase/tests/test_catalog_rls.sql`: pgTAP — company A cannot see company B rows for all 6 tables; unauthenticated gets zero rows; admin sees own-company rows
- [x] 1.7 Create `supabase/tests/test_catalog_constraints.sql`: pgTAP — SKU case-insensitive unique rejects `abc-123` after `ABC-123`; NULL barcodes do not conflict; active price uniqueness (only one `effective_until IS NULL` per `variant_id`); category cycle detection; depth > 5 rejection
- [x] 1.8 Run `supabase db reset` and `supabase test db`; verify all tests green

## Phase 2: RPC Functions (PR 2)

- [x] 2.1 Add `create_product_with_variant(p JSONB)` in migration: atomic insert product + variant (auto-generate SKU if null, retry on collision) + initial price; `SECURITY DEFINER`; verify `p->>'company_id' = get_company_id()`
- [x] 2.2 Add `deactivate_product(p JSONB)`: set `is_active=false, deleted_at=now(), deleted_by=auth.uid()` on product and all its variants; verify company ownership
- [x] 2.3 Add `set_variant_price(p JSONB)`: `SELECT FOR UPDATE` on current active price; close at `p->>'effective_from'`; insert new row; verify company ownership; defaults `effective_from=now()`, `currency='MXN'`
- [x] 2.4 Add CRUD RPCs in migration: `create_brand`, `update_brand`, `deactivate_brand`, `create_category`, `update_category`, `deactivate_category`, `create_unit`, `update_unit`, `deactivate_unit` — all `SECURITY DEFINER`, JSONB param, verify `company_id`
- [x] 2.5 Create `supabase/tests/test_catalog_rpcs.sql`: pgTAP — `create_product_with_variant` atomicity (product+variant+price created together, rollback on sub-insert failure); `deactivate_product` cascading; `set_variant_price` closing + concurrency; CRUD RPC company isolation
- [x] 2.6 Run `supabase db reset` and `supabase test db`; verify all pgTAP tests green

### PR2 Hardening (corrective review findings)

- [x] 2.H1 Add `SET search_path = public` to all 12 SECURITY DEFINER RPCs (proconfig hardening against search_path injection)
- [x] 2.H2 Revoke PUBLIC and anon EXECUTE on all mutation RPCs; grant only to authenticated (defense in depth)
- [x] 2.H3 Harden `set_variant_price` to reject overlapping future-dated temporal price intervals and prevent effective_from < active effective_from
- [x] 2.H4 Explicitly validate referenced brand/category/unit/parent active ownership in `create_product_with_variant` and `create_category` RPCs; reject global base units as variant unit_id
- [x] 2.H5 Add pgTAP tests: rollback-on-failure atomicity, global unit rejection, cross-tenant ref rejection (brand/category/unit/parent), anon EXECUTE restriction, fixed search_path verification, future price non-overlap rejection

### PR2 Hardening 2 (fresh review blocker fix)

- [x] 2.H6 Harden `update_category` to explicitly validate `parent_id` when supplied: same company, active, not self-referencing
- [x] 2.H7 Add pgTAP tests: `update_category` rejects inactive same-company parent_id; `update_category` rejects cross-company parent_id

## Phase 3: Edge Functions + Shared Validation (PR 3)

- [x] 3.1 Create `supabase/functions/_shared/catalog_schemas.ts`: Zod schemas for `CreateProductRequest`, `UpdateProductRequest`, `DeactivateProductRequest`, plus brand/category/unit create/update request schemas
- [x] 3.2 Create `supabase/functions/catalog/create-product/index.ts`: 8-step EF — POST, admin auth, validate via Zod, invoke `create_product_with_variant`, return `EFResult<ProductResult>`
- [x] 3.3 Create `supabase/functions/catalog/update-product/index.ts`: 8-step EF — POST, admin auth, validate, invoke RPC for product field updates, return `EFResult<T>` ~~STUB~~ ✅ **PR3 Corrective**: Replaced NOT_IMPLEMENTED stub with real implementation invoking `update_product` RPC.
- [x] 3.4 Create `supabase/functions/catalog/deactivate-product/index.ts`: 8-step EF — POST, admin auth, invoke `deactivate_product`, return `EFResult<T>`
- [x] 3.5 Create `supabase/functions/catalog/create-brand/index.ts`, `update-brand/index.ts`, `deactivate-brand/index.ts`: 8-step EFs each
- [x] 3.6 Create `supabase/functions/catalog/create-category/index.ts`, `update-category/index.ts`, `deactivate-category/index.ts`: 8-step EFs each
- [x] 3.7 Create `supabase/functions/catalog/create-unit/index.ts`, `update-unit/index.ts`, `deactivate-unit/index.ts`: 8-step EFs each
- [x] 3.8 Create `supabase/functions/_test/catalog_create_product.test.ts`: Deno.test — input validation (Zod schemas for CreateProductRequest, DeactivateProductRequest), EFResult ok/fail shape
- [x] 3.9 Create `supabase/functions/_test/catalog_deactivate_product.test.ts`: Deno.test — DeactivateProductRequest validation, invalid UUID, extra key stripping
- [x] 3.10 Create `supabase/functions/_test/catalog_set_price.test.ts`: Deno.test — SetVariantPriceRequest validation, currency defaults, negative/zero price rejection
- [x] 3.11 Create `supabase/functions/_test/catalog_brand_crud.test.ts`: Deno.test — CreateBrand/UpdateBrand/DeactivateBrand request validation
- [x] 3.12 Create `supabase/functions/_test/catalog_category_crud.test.ts`: Deno.test — CreateCategory/UpdateCategory/DeactivateCategory request validation including nullable parent_id
- [x] 3.13 Create `supabase/functions/_test/catalog_unit_crud.test.ts`: Deno.test — CreateUnit/UpdateUnit/DeactivateUnit request validation including optional abbreviation
- [x] 3.14 Run `deno test supabase/functions/_test/`; verify all Deno tests pass — ✅ 55 tests pass (54 new + 1 smoke). **Updated after PR3 corrective: 68 tests pass (54 original + 8 update_product + 5 set_variant_price + 1 smoke)**

### PR3 Corrective Follow-up (before Phase 4)

These tasks fix two PR3 gaps: (1) `update-product` EF returning 501 NOT_IMPLEMENTED due to missing `update_product` RPC, and (2) missing `set-variant-price` EF despite `set_variant_price` RPC and `SetVariantPriceRequest` schema existing.

- [x] C1 Add `update_product(p JSONB)` RPC to `00004_catalog_domain.sql`: SECURITY DEFINER, fixed `search_path`, revoke PUBLIC/anon, grant authenticated, verify `get_company_id()` and `is_admin()`, verify product ownership, validate brand_id/category_id references (same company, active), update allowed fields (name, slug, brand_id, category_id, description), support nullable FK clearing (brand_id=null, category_id=null)
- [x] C2 Add REVOKE ALL FROM PUBLIC/anon and GRANT EXECUTE TO authenticated for `update_product` in migration
- [x] C3 Replace `supabase/functions/catalog/update-product/index.ts` stub with real 8-step EF invoking `update_product` RPC, using `UpdateProductRequest` Zod schema
- [x] C4 Add `UpdateProductRequest` Zod schema and `UpdateProductResult` type to `supabase/functions/_shared/catalog_schemas.ts`
- [x] C5 Create `supabase/functions/catalog/set-variant-price/index.ts`: 8-step EF invoking `set_variant_price` RPC using existing `SetVariantPriceRequest` schema
- [x] C6 Create `supabase/functions/_test/catalog_update_product.test.ts`: Deno.test — UpdateProductRequest validation, nullable brand_id/category_id, invalid UUID rejection, extra key stripping
- [x] C7 Create `supabase/functions/_test/catalog_set_variant_price.test.ts`: Deno.test — additional SetVariantPriceRequest validation, effective_from, string price rejection, empty UUID rejection
- [x] C8 Add pgTAP tests 36–44 to `supabase/tests/test_catalog_rpcs.sql`: update_product basic update, brand_id/category_id update, nullable FK clearing, wrong company rejection, cross-company FK rejection, non-admin rejection, anon EXECUTE restriction, search_path hardening check; update plan count to 82

## Phase 4: Verification + Spec Alignment (PR 4)

- [x] 4.1 Run `supabase db reset` end-to-end — confirm all 6 tables, constraints, triggers, RLS, seed data, and RPCs created cleanly
- [x] 4.2 Run `supabase test db` — confirm all pgTAP tests pass (RLS, constraints, RPCs)
- [x] 4.3 Run `deno test supabase/functions/_test/` — confirm all Deno tests pass
- [x] 4.4 Verify each spec scenario from delta spec: RC1 brand CRUD, RC2 category nesting+cycle, RC3 unit CRUD, RC4 product+variant, RC5 price temporal, RC6 EF mutation boundary, RC7 RLS isolation
- [x] 4.5 Update delta spec if implementation details diverge from documented contracts (column names, RPC signatures, EF paths)