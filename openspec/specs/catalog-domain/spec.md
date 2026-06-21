# Catalog Domain Specification

## Purpose

Product catalog for multi-tenant SaaS POS. Brands, hierarchical categories, units, products, variants, product_prices. Reads via SDK+RLS; mutations via EF→RPC.

## Requirements

### RC1: Brand Management

<!-- source: constitution §3, §5, §8, §10 -->
Brands MUST be company-scoped, logically deleted. Name MUST be unique per company. Physical deletion PROHIBITED. RLS: `company_id = get_company_id()`.

- GIVEN admin for company A → WHEN creating brand → THEN brand created with `company_id`, `is_active = true`
- GIVEN brand "X" exists for company A → WHEN creating duplicate → THEN rejected
- GIVEN admin deactivates → THEN `is_active = false`, `deleted_at`/`deleted_by` set; no physical deletion

### RC2: Hierarchical Categories

<!-- source: constitution §3, §5, §8, §10 -->
Categories MUST support nesting via `parent_id` self-reference. `NULL` → root. Cycle detection: MUST NOT be own ancestor. Logical deletion MUST NOT cascade to children. RLS by `company_id`.

- GIVEN admin → WHEN creating category with `parent_id = NULL` → THEN root category created
- GIVEN root exists → WHEN creating child with `parent_id` → THEN child created
- GIVEN A child of B → WHEN setting B.parent_id = A → THEN rejected, cycle detected
- GIVEN admin deactivates parent → THEN parent`is_active = false`; children remain active

### RC3: Unit of Measure

<!-- source: constitution §3, §5, §8 -->
Units MUST be company-scoped, logically deleted. Name MUST be unique per company. RLS by `company_id`.

- GIVEN admin → WHEN creating unit → THEN created under company
- GIVEN unit name exists → WHEN creating duplicate → THEN rejected

### RC4: Products and Variants

<!-- source: constitution §1, §3, §5, §8, §10 -->
Products are containers; variants are sellable items. Variant `sku` unique per company; `barcode` (if set) unique per company. Deactivating product MUST deactivate all variants. Physical deletion PROHIBITED. RLS by `company_id`.

- GIVEN admin → WHEN creating product+variant → THEN both `is_active = true` with FK links
- GIVEN SKU exists for company A → WHEN creating duplicate SKU → THEN rejected
- GIVEN admin deactivates product → THEN product AND all variants `is_active = false`, audit recorded

### RC5: Product Prices (Separate Table)

<!-- source: constitution §3, §5, §8, §10, exploration §6 -->
Prices in `product_prices` table (not variant column). Temporal: `effective_from`/`effective_until`. At most one active price per variant per company (`effective_until IS NULL`). New price closes previous. RLS by `company_id`.

- GIVEN admin, variant exists → WHEN setting price → THEN price row created; previous active price closed
- GIVEN active price exists → WHEN setting new → THEN previous `effective_until = NOW()`; new sole active
- GIVEN temporal ranges → WHEN querying effective date → THEN returns matching range row

### RC6: EF Mutation Boundary

<!-- source: constitution §3, §9, §11, plan_2da §16.2 -->

| Operation | Path | Auth |
|-----------|------|------|
| Create/update/deactivate | EF → RPC | Admin (8-step) |
| Read/browse | SDK + RLS | Authenticated |

Mutations MUST follow D3 8-step. Reads MAY bypass EF.

- GIVEN admin → WHEN calling create-product EF → THEN 8-step validated, RPC invoked, audited, `EFResult` returned
- GIVEN cashier → WHEN calling create-product EF → THEN rejected, `FORBIDDEN`
- GIVEN user → WHEN querying via SDK → THEN own-company rows only; deactivated excluded unless filtered

### RC7: RLS Multi-Tenant Isolation

<!-- source: constitution §8, §9, plan_2da §15 -->
All six catalog tables MUST enforce `company_id = get_company_id()`. Admin: all own-company data. Unassigned: zero rows. EF service role: `SECURITY DEFINER` bypasses RLS.

- GIVEN user for company A → WHEN querying → THEN only company A rows; company B invisible
- GIVEN unauthenticated → WHEN querying → THEN zero rows
- GIVEN EF service role → WHEN invoking RPC → THEN `SECURITY DEFINER` bypasses RLS

### RC8: Catalog Schema DDL

Migration `00004_catalog_domain.sql` creates 6 tables. All share: `company_id UUID NOT NULL`, `is_active BOOLEAN DEFAULT TRUE`, audit columns, `set_updated_at()` trigger, RLS with `company_id = get_company_id()`.

| Table | Constraints | Indexes |
|-------|-------------|---------|
| brands | `(company_id, slug)` UNIQUE; `(company_id, id)` UNIQUE | company_id |
| categories | `(company_id, slug)` UNIQUE; `(company_id, id)` UNIQUE; cycle trigger; depth ≤ 5 | company_id, parent_id |
| units | `(company_id, name)` UNIQUE; `(company_id, id)` UNIQUE | company_id |
| products | `(company_id, slug)` UNIQUE; `(company_id, id)` UNIQUE | company_id, brand_id, category_id |
| product_variants | `(company_id, LOWER(sku))` UNIQUE; `(company_id, barcode) WHERE barcode IS NOT NULL` UNIQUE; `(company_id, id)` UNIQUE | company_id, product_id |
| product_prices | `(variant_id) WHERE effective_until IS NULL` UNIQUE | company_id, variant_id, effective_from |

Key columns: categories has `parent_id→categories(id) NULL`; product_variants has `sku, barcode NULL, name NOT NULL`; product_prices has `price NUMERIC(12,2), currency TEXT DEFAULT 'MXN', effective_from, effective_until`.

- GIVEN migration applied → WHEN db reset → THEN all tables, constraints, indexes exist idempotently

### RC9: Global Unit Deletion Prevention

A BEFORE DELETE trigger `prevent_global_unit_deletion()` on `units` prevents physical deletion of global template units (`company_id = '00000000-0000-0000-0000-000000000000'`). Company-owned units may be logically deleted (is_active=false, deleted_at).

- GIVEN global base unit → WHEN DELETE attempted → THEN rejected
- GIVEN company-owned unit → WHEN deleted_at set → THEN logical deletion only

### RC10: SKU Case-Insensitive and Auto-Generated

SKU uniqueness MUST be case-insensitive (`LOWER(sku)` constraint). Null SKU on creation MUST auto-generate as `{product_slug}-{random4}`; collision retries with new suffix.

- GIVEN "ABC-123" exists → WHEN creating "abc-123" → THEN rejected
- GIVEN null SKU → WHEN created → THEN auto-generated
- GIVEN collision → WHEN retry → THEN new suffix until unique

### RC11: Barcode Nullable

Barcode MUST be nullable. Partial unique index permits unlimited NULLs; non-NULL values unique per company. Cross-company same barcode allowed.

### RC12: Temporal Price Closing

New price MUST close previous at `new.effective_from` (not NOW()). Future-dated prices allowed if no overlap of multiple active prices. `set_variant_price` MUST use `SELECT FOR UPDATE`.

- GIVEN active price → WHEN new price at T → THEN previous effective_until = T
- GIVEN concurrent requests → WHEN serialized → THEN second sees first's closed price

### RC13: Category Depth Limit

Nesting MUST NOT exceed depth 5. BEFORE trigger counts ancestors, rejects depth > 5. Cycle detection precedes depth check. Roots = depth 1.

- GIVEN depth 5 → WHEN adding depth 6 → THEN rejected
- GIVEN cycle → WHEN trigger fires → THEN rejected

### RC14: Variant Human-Readable Name

`product_variants.name` MUST be NOT NULL. Stores human-readable label (e.g., "Chocolate 2kg").

### RC15: Separate Edge Functions Per Critical Operation

Generic multiplexed EF is PROHIBITED. Required: `catalog/create-product`, `catalog/update-product`, `catalog/deactivate-product`, `catalog/set-variant-price`, plus `catalog/{create|update|deactivate}-{brand|category|unit}`.

- GIVEN `set_variant_price` RPC → WHEN EF client calls → THEN `catalog/set-variant-price` EF invokes it

### RC16: Base Unit Seeding and Default Currency

Migration seeds 8 units: Unidad, Cápsulas, Tabletas, Mililitros, Gramos, Kilogramos, Litros, Miligramos. Companies MAY edit but MUST NOT physically delete. `product_prices.currency` defaults to 'MXN'.

- GIVEN fresh DB → WHEN migration applied → THEN 8 base units seeded
- GIVEN admin → WHEN deactivating seeded unit → THEN logical deletion only

### RC17: Catalog RPC Contracts

| RPC | Behavior |
|-----|----------|
| `create_product_with_variant` | Atomic: product + variant + price. SECURITY DEFINER, verifies company_id independently. |
| `update_product` | Update allowed fields (name, slug, brand_id, category_id, description). Nullable FK clearing. SECURITY DEFINER, verifies company_id independently, validates brand_id/category_id references (same company, active). |
| `deactivate_product` | Sets is_active=false on product + all variants; sets deleted_at/deleted_by. |
| `set_variant_price` | Closes previous at effective_from, creates new. SELECT FOR UPDATE. Rejects overlapping future-dated intervals. Params: variant_id, company_id, price, currency DEFAULT 'MXN', effective_from DEFAULT NOW(). |

All mutation RPCs: `SET search_path = public` (proconfig), REVOKE ALL FROM PUBLIC and anon, GRANT EXECUTE TO authenticated only.

- GIVEN any sub-insert fails → THEN entire transaction rolled back

### RC18: RLS Policy Pattern

All 6 catalog tables follow the foundation pattern from 00003, plus an additional `SELECT` policy on `units` for global template rows:

- Per table: `SELECT … USING (company_id = get_company_id())`, `INSERT/UPDATE … WITH CHECK (company_id = get_company_id() AND is_admin())`, `service_role ALL` bypass.
- `units` adds: `units_select_global_templates` allowing SELECT on rows where `company_id = '00000000-0000-0000-0000-000000000000'`.
- No DELETE policies — logical deletion only.

### RC19: Catalog EF Contracts

All catalog EFs: POST, admin auth, 8-step pattern, return `EFResult<T>`. Unauthenticated or non-admin → EFResult{FORBIDDEN}.

### RC20: Catalog Test Specifications

pgTAP: RLS isolation (6 tables), unique constraints (SKU case-insensitive, NULL barcode, active price), cycle detection, depth limit, global unit deletion prevention, RPC hardening (search_path, REVOKE/GRANT). Deno.test: EF auth (unauthenticated, cashier, admin), RPC invocation, EFResult shape.

- GIVEN `supabase test db` → THEN all pgTAP pass
- GIVEN `deno test` → THEN all EF tests pass