# Customers Demand Domain Exploration

## Executive Summary

The customers-demand domain captures customer identity and demand signals for the POS. It should add customer master data, customer requests, preorders, and preorder items, without activating inventory reservations in V1. The domain is primarily CRUD via SDK + RLS; it does not directly mutate money or inventory in V1.

## Entities

| Table | Purpose |
|-------|---------|
| `customers` | Customer master data required for future credit, preorders, and layaway flows. |
| `customer_requests` | Informational purchase requests that do not commit inventory and later feed purchase suggestions. |
| `preorders` | Preorder header representing demand from a customer at a branch. |
| `preorder_items` | Preorder line items referencing catalog variants. |

Budgets, quotes, and quotations are not part of this domain; the existing planning documents do not define them.

## Meaning of Demand

Demand includes both:

- Customer requests: non-committing demand signals.
- Preorders: customer intent to buy items, but without stock commitment in V1.

Layaway and stock reservations remain out of V1.

## Suggested Fields

### `customers`

- `id UUID PRIMARY KEY DEFAULT gen_random_uuid()`
- `company_id UUID NOT NULL REFERENCES companies(id)`
- `name TEXT NOT NULL`
- `slug TEXT NOT NULL`
- `tax_id TEXT`
- `phone TEXT`
- `email TEXT`
- `address TEXT`
- `notes TEXT`
- `is_active BOOLEAN DEFAULT TRUE`
- Audit and logical deletion columns: `created_at`, `updated_at`, `deleted_at`, `created_by`, `updated_by`, `deleted_by`

### `customer_requests`

- `id`, `company_id`, `customer_id`
- Optional `variant_id` because requests may refer to a product not yet in catalog
- `requested_qty`
- `status` such as `pending`, `resolved`, `cancelled`
- `notes`
- Standard audit/logical deletion columns

### `preorders`

- `id`, `company_id`, `branch_id`, `customer_id`
- `status` such as `draft`, `confirmed`, `fulfilled`, `cancelled`
- `notes`
- Standard audit/logical deletion columns

### `preorder_items`

- `id`, `company_id`, `preorder_id`, `variant_id`
- `qty`
- `unit_price`
- Standard audit columns

## Integration Points

### Catalog

- `customer_requests.variant_id` may reference `product_variants(company_id, id)` and should be nullable.
- `preorder_items.variant_id` should reference `product_variants(company_id, id)`.

### Inventory

- Inventory reservations remain deferred. Existing `reserve_stock()` and `release_reservation()` are V1 rejection stubs in the inventory domain.
- V1 preorders do not modify inventory quantities and do not alter `v_stock_available`.

### Purchasing

- Customer requests are later inputs to purchase suggestions, but the suggestion engine belongs to a later reports/dashboard domain.

### Credit Payments

- `customers` is a prerequisite for future customer balances and credit payments.

## V1 Scope

In scope:

- `customers`
- `customer_requests`
- `preorders`
- `preorder_items`
- RLS on all four tables
- Composite foreign keys using `(company_id, id)` patterns
- pgTAP tests for constraints and RLS isolation
- CRUD via SDK + RLS

Out of scope:

- Stock reservation activation
- Stock commitment for preorders
- Layaway/apartados
- Budgets/quotes/cotizaciones
- Purchase suggestion engine
- Customer credit balances
- Edge Functions/RPCs unless later design discovers a critical mutation boundary requirement

## Migration

Next migration should be:

```text
00007_customers_demand_domain.sql
```

## Risks

| Risk | Severity | Mitigation |
|------|----------|------------|
| Reservation expectations | Medium | Explicitly document that V1 preorders do not commit inventory. |
| Cross-tenant variant/customer references | Medium | Use composite FKs with `(company_id, id)`. |
| Review budget | Medium | Plan chained slices if migration + tests exceed 400 changed lines. |

## Recommendation

Proceed to proposal for `customers-demand-domain` as a schema/RLS/test-focused change. Keep stock reservations and purchase suggestions deferred to later domains.
