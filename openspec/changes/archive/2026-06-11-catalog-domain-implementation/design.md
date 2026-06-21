# Design: Catalog Domain Implementation

## Technical Approach

Single change delivering 6 catalog tables, RPCs, Edge Functions, and tests via 4 feature-branch-chain PRs. Schema-first, following existing foundation patterns (00001–00003 migrations, `set_updated_at()`, `_shared/auth.ts`, `EFResult<T>`). Multi-table mutations go through `SECURITY DEFINER` RPCs invoked by EFs; reads use SDK+RLS.

## Architecture Decisions

### Decision: Case-insensitive SKU via `LOWER()` expression index

| Option | Tradeoff | Decision |
|--------|----------|----------|
| `LOWER(sku)` in UNIQUE constraint | Computed, no extra column | ✅ Chosen |
| CITEXT extension | Requires extension install | ❌ Rejected |
| Uppercase-enforcing trigger | Hides transformation | ❌ Rejected |

**Rationale**: Expression unique index `(company_id, LOWER(sku) WHERE sku IS NOT NULL)` avoids extensions and matches the approved business rule.

### Decision: SKU auto-generation in RPC

| Option | Tradeoff | Decision |
|--------|----------|----------|
| Generate in `create_product_with_variant` RPC | Centralized, single source of truth | ✅ Chosen |
| Generate in EF | Splits logic across layers | ❌ Rejected |
| `DEFAULT` + trigger | Hard to retry on collision | ❌ Rejected |

**Rationale**: RPC generates `{product_slug}-{random4}` on null SKU, retries on collision with new suffix. Business rule stays in SQL where atomicity is guaranteed.

### Decision: Price closing at `new.effective_from`, not `NOW()`

| Option | Tradeoff | Decision |
|--------|----------|----------|
| Close at `effective_from` | Gap-free temporal continuity | ✅ Chosen |
| Close at `NOW()` | Creates gaps for future-dated prices | ❌ Rejected |

**Rationale**: Approved business rule: previous price's `effective_until` = new price's `effective_from`. Future prices allowed if non-overlapping. `SELECT FOR UPDATE` serializes concurrent calls.

### Decision: Separate EFs per critical operation

| Option | Tradeoff | Decision |
|--------|----------|----------|
| One EF per operation | Clear tracing, single-responsibility | ✅ Chosen |
| Generic multiplexed EF | Fewer files, harder to trace | ❌ Rejected |

**Rationale**: Constitution §3 (traceability) and approved business rule prohibit multiplexed EFs. Smaller EFs are deployable independently.

### Decision: JSON params for `create_product_with_variant`

| Option | Tradeoff | Decision |
|--------|----------|----------|
| JSONB parameter | Extensible, single arg, self-documenting | ✅ Chosen |
| 9+ positional params | Fragile, hard to extend | ❌ Rejected |

**Rationale**: The RPC takes a single `JSONB` parameter parsed internally. Adding fields later requires no signature change.

## Data Flow

```
Client (Admin)
   │
   ▼ POST /catalog/create-product
catalog/create-product (EF: steps 1–5)
   │ Step 6: invoke RPC
   ▼ service_role
create_product_with_variant(JSONB)
   ├─→ INSERT products
   ├─→ INSERT product_variants  (SKU auto-gen if null)
   └─→ INSERT product_prices   (initial price)
   │
   ▼ EFResult<ProductResult>
Client
```

Simple CRUD (brands, categories, units):

```
Client (Admin)
   │
   ▼ POST /catalog/create-brand
catalog/create-brand (EF: steps 1–5)
   │ Step 6: invoke RPC
   ▼ service_role
create_brand(JSONB)
   └─→ INSERT brands
   │
   ▼ EFResult<BrandResult>
Client
```

## Schema: 6 Catalog Tables

All tables share: `company_id UUID NOT NULL`, `is_active BOOLEAN DEFAULT TRUE`, `created_at/updat_ed_at TIMESTAMPTZ DEFAULT now()`, `created_by/updated_by UUID`, `deleted_at TIMESTAMPTZ`, `deleted_by UUID`. Trigger: `set_updated_at()`.

| Table | Key Columns | Unique Constraints |
|-------|-------------|-------------------|
| `brands` | `name TEXT NOT NULL`, `slug TEXT NOT NULL` | `(company_id, slug)` |
| `categories` | `name TEXT NOT NULL`, `slug TEXT NOT NULL`, `parent_id UUID → categories(id) NULL` | `(company_id, slug)` |
| `units` | `name TEXT NOT NULL`, `abbreviation TEXT` | `(company_id, name)` |
| `products` | `name TEXT NOT NULL`, `slug TEXT NOT NULL`, `brand_id UUID → brands(id) NULL`, `category_id UUID → categories(id) NULL`, `description TEXT` | `(company_id, slug)` |
| `product_variants` | `product_id UUID NOT NULL → products(id)`, `sku TEXT`, `barcode TEXT`, `name TEXT NOT NULL`, `unit_id UUID → units(id) NULL` | `(company_id, LOWER(sku)) WHERE sku IS NOT NULL`; `(company_id, barcode) WHERE barcode IS NOT NULL` |
| `product_prices` | `variant_id UUID NOT NULL → product_variants(id)`, `price NUMERIC(12,2) NOT NULL`, `currency TEXT DEFAULT 'MXN'`, `effective_from TIMESTAMPTZ NOT NULL DEFAULT now()`, `effective_until TIMESTAMPTZ` | `(variant_id) WHERE effective_until IS NULL` |

Indexes: `company_id` on all 6 tables; `parent_id` on categories; `product_id` on product_variants; `brand_id`, `category_id` on products; `variant_id`, `effective_from` on product_prices.

### Triggers

- `prevent_category_cycle()` — BEFORE INSERT/UPDATE on categories: walks parent chain, rejects cycles and depth > 5.
- `set_updated_at` — Applied to all 6 tables (reuses existing function from 00001).

### Seed Data

```sql
INSERT INTO public.units (company_id, name, abbreviation) VALUES
  ('00000000-0000-0000-0000-000000000000', 'Unidad', 'Ud'),
  ('00000000-0000-0000-0000-000000000000', 'Cápsulas', 'Cáp'),
  ('00000000-0000-0000-0000-000000000000', 'Tabletas', 'Tab'),
  ('00000000-0000-0000-0000-000000000000', 'Mililitros', 'ml'),
  ('00000000-0000-0000-0000-000000000000', 'Gramos', 'g'),
  ('00000000-0000-0000-0000-000000000000', 'Kilogramos', 'kg'),
  ('00000000-0000-0000-0000-000000000000', 'Litros', 'L'),
  ('00000000-0000-0000-0000-000000000000', 'Miligramos', 'mg');
```

Companies copy/update these rows; never physically delete. Company-editable means `UPDATE` allowed; `DELETE` blocked via RLS + application logic.

## RLS Policy Pattern

All 6 catalog tables follow the foundation pattern from 00003:

```sql
-- Per table (example:brands):
ALTER TABLE public.brands ENABLE ROW LEVEL SECURITY;

CREATE POLICY "brands_select_own" ON public.brands FOR SELECT
  TO authenticated USING (company_id = get_company_id());

CREATE POLICY "brands_insert_admin" ON public.brands FOR INSERT
  TO authenticated WITH CHECK (company_id = get_company_id() AND is_admin());

CREATE POLICY "brands_update_admin" ON public.brands FOR UPDATE
  TO authenticated USING (company_id = get_company_id() AND is_admin());

-- Service role full bypass
CREATE POLICY "brands_service_all" ON public.brands FOR ALL
  TO service_role USING (TRUE) WITH CHECK (TRUE);
```

Same pattern for all 6 tables (replace table name in policy names). No DELETE policies — logical deletion only.

## RPC Signatures

| RPC | Security | Behavior |
|-----|----------|----------|
| `create_product_with_variant(p JSONB)` | SECURITY DEFINER | Atomic: inserts product + variant + price. Auto-generates SKU if null. Verifies `p->>'company_id'` matches caller. Returns product+variant+price IDs. |
| `deactivate_product(p JSONB)` | SECURITY DEFINER | Sets `is_active=false, deleted_at=now(), deleted_by=auth.uid()` on product and all its variants. Verifies company ownership. |
| `set_variant_price(p JSONB)` | SECURITY DEFINER | `SELECT FOR UPDATE` on current active price; closes at `p->>'effective_from'`; inserts new row. Verifies company ownership. |
| `create_brand(p JSONB)` | SECURITY DEFINER | Simple insert. Verifies company_id. |
| `create_category(p JSONB)` | SECURITY DEFINER | Simple insert. Verifies company_id. Trigger enforces cycle/depth. |
| `create_unit(p JSONB)` | SECURITY DEFINER | Simple insert. Verifies company_id. |
| `update_brand(p JSONB)` | SECURITY DEFINER | Update name/slug. Verifies company ownership. |
| `update_category(p JSONB)` | SECURITY DEFINER | Update name/slug/parent_id. Verifies company ownership. Trigger enforces cycle/depth. |
| `update_unit(p JSONB)` | SECURITY DEFINER | Update name/abbreviation. Verifies company ownership. |
| `deactivate_brand(p JSONB)` | SECURITY DEFINER | Logical delete. Verifies company ownership. |
| `deactivate_category(p JSONB)` | SECURITY DEFINER | Logical delete. Verifies company ownership. Children remain active. |
| `deactivate_unit(p JSONB)` | SECURITY DEFINER | Logical delete. Verifies company ownership. |

All RPCs verify `p->>'company_id' = get_company_id()` independently (defense in depth).

## Edge Function Layout

```
supabase/functions/
  _shared/auth.ts, types.ts, cors.ts  (existing, unchanged)
  catalog/
    create-product/index.ts     ← 8-step, POST, admin
    update-product/index.ts     ← 8-step, POST, admin
    deactivate-product/index.ts ← 8-step, POST, admin
    create-brand/index.ts       ← 8-step, POST, admin
    update-brand/index.ts       ← 8-step, POST, admin
    deactivate-brand/index.ts   ← 8-step, POST, admin
    create-category/index.ts    ← 8-step, POST, admin
    update-category/index.ts   ← 8-step, POST, admin
    deactivate-category/index.ts← 8-step, POST, admin
    create-unit/index.ts        ← 8-step, POST, admin
    update-unit/index.ts       ← 8-step, POST, admin
    deactivate-unit/index.ts    ← 8-step, POST, admin
```

### EF Request/Response Contracts

```typescript
// Request body for create-product
interface CreateProductRequest {
  name: string;
  brand_id?: string;       // optional, UUID
  category_id?: string;    // optional, UUID
  description?: string;
  variant: {
    name: string;           // human-readable label
    sku?: string;           // auto-generated if null
    barcode?: string;       // optional
    unit_id?: string;
    price: number;
    currency?: string;      // defaults to 'MXN'
    effective_from?: string; // ISO datetime, defaults to now()
  };
}

// Response follows existing EFResult<T>
type ProductResult = {
  product_id: string;
  variant_id: string;
  price_id: string;
  sku: string;               // returned even if auto-generated
};
```

All EFs: validate `auth.requiredRole === "admin"`, invoke RPC via service_role client, return `EFResult<T>`.

## Testing Strategy

| Layer | What | Approach |
|-------|------|----------|
| pgTAP — RLS | Company A cannot see company B data (6 tables) | Create two companies, insert data as both, test `current_setting` isolation |
| pgTAP — Constraints | SKU case-insensitive unique, NULL barcode non-conflict, active price uniqueness, category depth > 5 rejection, cycle detection | Direct INSERT tests asserting expected failures |
| pgTAP — RPCs | `create_product_with_variant` atomicity, `deactivate_product` cascading, `set_variant_price` closing + concurrency serialization | Function call tests with `SELECT FOR UPDATE` verification |
| Deno.test — EF Auth | Unauthenticated → 401, cashier → 403, admin → success | Mock Supabase client with JWT roles |
| Deno.test — EF RPC | Request validation, RPC invocation, response shape (`EFResult<T>`) | Integration tests against local Supabase |

### Test File Layout

```
supabase/tests/
  test_catalog_rls.sql          ← pgTAP: RLS isolation for all 6 tables
  test_catalog_constraints.sql  ← pgTAP: unique constraints, cycle/depth
  test_catalog_rpcs.sql         ← pgTAP: RPC behavior
supabase/functions/_test/
  catalog_create_product.test.ts ← Deno: create-product EF
  catalog_deactivate_product.test.ts ← Deno: deactivate EF
  catalog_set_price.test.ts     ← Deno: set_variant_price EF
  catalog_brand_crud.test.ts    ← Deno: brand CRUD EFs
  catalog_category_crud.test.ts ← Deno: category CRUD EFs
  catalog_unit_crud.test.ts     ← Deno: unit CRUD EFs
```

## Migration / Rollout

4 PR slices via feature-branch-chain:

| PR | Slice | Content | Est. Lines |
|----|-------|---------|------------|
| 1 | Schema + RLS | `00004_catalog_domain.sql`: tables, indexes, constraints, triggers, RLS, seed + `test_catalog_rls.sql` + `test_catalog_constraints.sql` | ~380 |
| 2 | RPC Functions | SQL RPCs for all catalog operations + `test_catalog_rpcs.sql` | ~280 |
| 3 | Catalog EFs + Tests | 12 EF directories + Deno test files + `_shared/catalog_schemas.ts` (Zod/input validation) | ~350 |
| 4 | Verify + Spec Alignment | `db reset`, `deno test`, `supabase test db`, update delta spec if needed | ~80 |

Rollback: Each PR revertible independently. Full rollback = drop migration `00004`, remove `catalog/` EF directory and test files. No data migration to reverse.

## File Changes

| File | Action | Description |
|------|--------|-------------|
| `supabase/migrations/00004_catalog_domain.sql` | Create | 6 tables, indexes, constraints, triggers, RLS policies, seed data |
| `supabase/tests/test_catalog_rls.sql` | Create | pgTAP: RLS isolation tests for all 6 tables |
| `supabase/tests/test_catalog_constraints.sql` | Create | pgTAP: unique constraints, cycle detection, depth limit |
| `supabase/tests/test_catalog_rpcs.sql` | Create | pgTAP: RPC behavior (atomicity, closing, deactivation) |
| `supabase/functions/catalog/create-product/index.ts` | Create | EF: create product+variant+price |
| `supabase/functions/catalog/update-product/index.ts` | Create | EF: update product fields |
| `supabase/functions/catalog/deactivate-product/index.ts` | Create | EF: logical delete product+variants |
| `supabase/functions/catalog/create-brand/index.ts` | Create | EF: create brand |
| `supabase/functions/catalog/update-brand/index.ts` | Create | EF: update brand |
| `supabase/functions/catalog/deactivate-brand/index.ts` | Create | EF: logical delete brand |
| `supabase/functions/catalog/create-category/index.ts` | Create | EF: create category |
| `supabase/functions/catalog/update-category/index.ts` | Create | EF: update category |
| `supabase/functions/catalog/deactivate-category/index.ts` | Create | EF: logical delete category |
| `supabase/functions/catalog/create-unit/index.ts` | Create | EF: create unit |
| `supabase/functions/catalog/update-unit/index.ts` | Create | EF: update unit |
| `supabase/functions/catalog/deactivate-unit/index.ts` | Create | EF: logical delete unit |
| `supabase/functions/_shared/catalog_schemas.ts` | Create | Zod/JSON schemas for EF input validation |
| `supabase/functions/_test/catalog_create_product.test.ts` | Create | Deno test: create-product EF |
| `supabase/functions/_test/catalog_deactivate_product.test.ts` | Create | Deno test: deactivate EF |
| `supabase/functions/_test/catalog_set_price.test.ts` | Create | Deno test: set_variant_price EF |
| `supabase/functions/_test/catalog_brand_crud.test.ts` | Create | Deno test: brand CRUD EFs |
| `supabase/functions/_test/catalog_category_crud.test.ts` | Create | Deno test: category CRUD EFs |
| `supabase/functions/_test/catalog_unit_crud.test.ts` | Create | Deno test: unit CRUD EFs |

## Open Questions

None — all business rule questions were resolved in the proposal phase.