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