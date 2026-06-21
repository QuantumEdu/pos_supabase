# Proposal: Customers Demand Domain

## Problem Statement

The POS system has catalog, inventory, and purchasing domains but no customer master data and no demand capture capability. Customer identity is a prerequisite for credit-payments (domain #8), and demand signals — customer requests and preorders — are the inputs that will later feed purchase suggestions. Without customers, the system cannot track who is buying or who is requesting products. The roadmap (R10 §5) places customers-demand-domain immediately after inventory, but it must be implemented before pos-sales-domain in the chain.

## Goals

1. Add customer master data (`customers`) as company-scoped, logically deletable entity — prerequisite for credit, preorders, and layaway.
2. Add informational customer requests (`customer_requests`) that capture demand signals without committing inventory.
3. Add preorder headers (`preorders`) and line items (`preorder_items`) for customer intent-to-buy with branch scoping.
4. Enforce composite FK patterns, RLS multi-tenant isolation, and logical deletion per constitution R3, R4, R5.
5. CRUD via SDK + RLS for all four tables — no Edge Functions or RPCs in V1 unless a critical mutation boundary is discovered during design.

## Non-Goals

- Stock reservation activation (inventory `reserve_stock()` / `release_reservation()` remain V1 rejection stubs).
- Stock commitment for preorders — preorders are demand signals only and do not modify `v_stock_available`.
- Layaway / apartados.
- Budgets, quotes, quotations (cotizaciones) — not defined in existing planning documents.
- Purchase suggestion engine (belongs to a later dashboard/reports domain).
- Customer credit balances (credit-payments-domain, domain #8).
- Edge Functions or RPCs for this domain in V1 (see §Open Decisions #1 for rationale).
- Frontend / UI.

## Scope

### In Scope

- Migration `00007_customers_demand_domain.sql`: tables `customers`, `customer_requests`, `preorders`, `preorder_items`
- RLS policies on all four tables: tenant isolation via `company_id`, admin full access, cashier read-only, unauthenticated zero rows
- Composite unique constraints and composite foreign keys following catalog/inventory/purchasing pattern
- Logical deletion: `is_active`, `deleted_at`, `deleted_by` on all mutable entities (`customers`, `customer_requests`, `preorders`)
- pgTAP tests: constraints, RLS isolation, composite FK integrity
- SDK + RLS CRUD contracts (no EF/RPC layer for V1)

### Out of Scope

- Stock reservation activation
- Preorder → inventory commitment
- Layaway workflows
- Budgets/quotes/cotizaciones
- Purchase suggestion engine
- Customer credit balances
- Edge Functions or RPCs for this domain

## Capabilities

### New Capabilities

- `customers-demand-domain`: customer master data, informational product requests, customer preorders with line items

### Modified Capabilities

- None. Existing catalog, inventory, and purchasing schemas are not modified. The domain adds new tables that reference existing `product_variants` via composite FK `(company_id, id)`, which is a read-only reference.

## Approach

Single change with 2 PR slices (SDK+RLS-only domain — no EF/RPC layer reduces total line count):

| PR | Slice | Content | Est. Lines |
|----|-------|---------|------------|
| 1 | Schema + RLS + Tests | Migration: 4 tables, indexes, composite FKs, RLS policies + pgTAP tests for constraints and isolation | ~250–300 |
| 2 | Verify + Spec Alignment | `supabase db reset`, `supabase test db`, audit trail validation, delta spec archive | ~50–100 |

Chain strategy: `feature/customers-demand-domain` base → single chain of 2 PRs. PR 1 targets base; PR 2 targets PR 1.

No Edge Functions, no RPCs in V1. This is a pure SQL/RLS change following the schema patterns established by catalog (00004), inventory (00005), and purchasing (00006).

## V1 Domain Boundaries

```
┌──────────────────────────────────────────────┐
│            Customers Demand Domain V1         │
│                                              │
│  customers ──────────────────────────────┐   │
│  customer_requests ──► product_variants   │   │
│  preorders ── preorder_items ──► variants │   │
│                                          │   │
│  Mutations: SDK + RLS (admin)            │   │
│  Reads: SDK + RLS (authenticated)        │   │
│  No EFs, no RPCs in V1                   │   │
└──────────────────────────────────────────────┘
```

Cross-domain touchpoints:
- **Catalog**: `customer_requests.variant_id` → `product_variants(company_id, id)` — nullable; `preorder_items.variant_id` → `product_variants(company_id, id)` — NOT NULL
- **Inventory**: V1 preorders do NOT modify inventory quantities and do NOT alter `v_stock_available`. Reservation RPCs remain V1 rejection stubs.
- **Purchasing**: customer requests are later inputs to purchase suggestions (future dashboard/reports domain).
- **Companies/Branches**: composite FKs to `companies(id)` and `branches(id)` following the existing pattern.
- **Credit Payments** (future): `customers` table is a prerequisite for customer balances and credit payments (domain #8).

## Data Model Overview

### `customers`

Customer master data — prerequisite for credit, preorders, and future layaway flows.

| Column | Type | Notes |
|--------|------|-------|
| `id` | UUID PK | `gen_random_uuid()` |
| `company_id` | UUID NOT NULL | FK → `companies(id)` |
| `name` | TEXT NOT NULL | Customer name / business name |
| `slug` | TEXT NOT NULL | Unique per company `(company_id, slug)` |
| `tax_id` | TEXT | RFC / tax identifier, optional |
| `phone` | TEXT | |
| `email` | TEXT | |
| `address` | TEXT | |
| `notes` | TEXT | |
| `is_active` | BOOLEAN DEFAULT TRUE | Logical deletion |
| `created_at`, `updated_at` | TIMESTAMPTZ | Audit |
| `created_by`, `updated_by` | UUID | Audit |
| `deleted_at` | TIMESTAMPTZ | Logical deletion audit |
| `deleted_by` | UUID | Logical deletion audit |

Composite unique: `(company_id, id)`, `(company_id, slug)`.

### `customer_requests`

Informational purchase requests that do not commit inventory. Later feed purchase suggestions.

| Column | Type | Notes |
|--------|------|-------|
| `id` | UUID PK | `gen_random_uuid()` |
| `company_id` | UUID NOT NULL | FK → `companies(id)` |
| `customer_id` | UUID NOT NULL | FK → `customers(id)` |
| `variant_id` | UUID | Nullable — requests may reference a product not yet in catalog |
| `requested_qty` | NUMERIC(14,3) NOT NULL | |
| `status` | TEXT NOT NULL DEFAULT 'pending' | `pending`, `resolved`, `cancelled` |
| `notes` | TEXT | |
| `is_active` | BOOLEAN DEFAULT TRUE | Logical deletion |
| `created_at`, `updated_at` | TIMESTAMPTZ | Audit |
| `created_by`, `updated_by` | UUID | Audit |
| `deleted_at` | TIMESTAMPTZ | Logical deletion audit |
| `deleted_by` | UUID | Logical deletion audit |

Composite FK: `(company_id, customer_id)` → `customers(company_id, id)`. `variant_id` FK: `(company_id, variant_id)` → `product_variants(company_id, id)` — nullable. Composite unique: `(company_id, id)`.

### `preorders`

Preorder header representing demand from a customer at a specific branch. No stock commitment in V1.

| Column | Type | Notes |
|--------|------|-------|
| `id` | UUID PK | `gen_random_uuid()` |
| `company_id` | UUID NOT NULL | FK → `companies(id)` |
| `branch_id` | UUID NOT NULL | FK → `branches(id)` |
| `customer_id` | UUID NOT NULL | FK → `customers(id)` |
| `status` | TEXT NOT NULL DEFAULT 'draft' | `draft`, `confirmed`, `fulfilled`, `cancelled` |
| `notes` | TEXT | |
| `is_active` | BOOLEAN DEFAULT TRUE | Logical deletion |
| `created_at`, `updated_at` | TIMESTAMPTZ | Audit |
| `created_by`, `updated_by` | UUID | Audit |
| `deleted_at` | TIMESTAMPTZ | Logical deletion audit |
| `deleted_by` | UUID | Logical deletion audit |

Composite unique: `(company_id, id)`. Composite FK: `(company_id, branch_id)` → `branches(company_id, id)`, `(company_id, customer_id)` → `customers(company_id, id)`.

### `preorder_items`

Preorder line items referencing catalog variants.

| Column | Type | Notes |
|--------|------|-------|
| `id` | UUID PK | `gen_random_uuid()` |
| `company_id` | UUID NOT NULL | |
| `preorder_id` | UUID NOT NULL | FK → `preorders(id)` |
| `variant_id` | UUID NOT NULL | FK → `product_variants(id)` |
| `qty` | NUMERIC(14,3) NOT NULL | |
| `unit_price` | NUMERIC(12,2) | Optional — may be set at preorder time or deferred to sale |
| `created_at`, `updated_at` | TIMESTAMPTZ | Audit |
| `created_by`, `updated_by` | UUID | Audit |

Composite FK: `(company_id, preorder_id)` → `preorders(company_id, id)`, `(company_id, variant_id)` → `product_variants(company_id, id)`. Composite unique: `(company_id, id)`.

### Preorder Status Lifecycle

```
draft ──► confirmed ──► fulfilled
  │           │
  └───────────┴──► cancelled
```

- `draft → confirmed`: customer commits to the preorder.
- `confirmed → fulfilled`: all items delivered (future domain — pos-sales or manual status update in V1).
- `draft|confirmed → cancelled`: preorder cancelled. No inventory reversal (no stock was committed).
- `fulfilled → cancelled`: prohibited.

In V1, status transitions happen via SDK UPDATE (admin). No server-side state machine enforcement — this is a schema-level enum constraint with documentation. Future domains with stock commitment SHOULD add RPC-enforced transitions.

## Integration Points

### With Catalog

- `customer_requests.variant_id` references `product_variants(company_id, id)` via composite FK — nullable because a customer may request a product the business does not yet catalog.
- `preorder_items.variant_id` references `product_variants(company_id, id)` via composite FK — NOT NULL (preorders must reference known variants).
- No catalog schema modifications.

### With Inventory

- V1 preorders do not modify inventory quantities. They do not call `reserve_stock()`, `release_reservation()`, or any inventory RPC.
- V1 preorders do not alter `v_stock_available` (which currently shows `physical_qty` only; the `committed`/`available` split is deferred).
- When stock reservations are activated in a future domain, preorder confirmation MAY trigger reservation. That integration point is documented here for forward compatibility but is explicitly OUT of V1.

### With Purchasing

- Customer requests (`customer_requests`) are later inputs to purchase suggestions. The suggestion engine belongs to a future dashboard/reports domain and is OUT of V1.
- No purchasing schema modifications. No purchasing RPCs are called.

### With Credit Payments (Future Domain #8)

- `customers` table is a prerequisite for customer credit balances and payment tracking.
- Future credit-payments-domain SHOULD add columns/tables referencing `customers(company_id, id)` via composite FK.
- No forward schema changes are added in V1.

## Security / RLS Approach

All four tables follow the foundation RLS pattern from migration 00003 with catalog/inventory/purchasing conventions:

| Role | customers | customer_requests | preorders | preorder_items |
|------|-----------|-------------------|-----------|----------------|
| Admin | Read/Write | Read/Write | Read/Write | Read/Write |
| Cashier | Read | Read | Read | Read |
| Unauthenticated | Zero rows | Zero rows | Zero rows | Zero rows |
| Service role | ALL bypass | ALL bypass | ALL bypass | ALL bypass |

Key RLS decisions:
- **Admin mutations via SDK + RLS**: Admin has INSERT, UPDATE on all four tables via RLS policies ( `company_id = get_company_id() AND is_admin()` ). This differs from catalog/inventory/purchasing which enforce EF→RPC mutation boundaries — customers-demand-domain does not touch money, inventory, or collections, so SDK+RLS is constitutionally appropriate per R2.
- **Cashier read-only**: Cashier has SELECT only, scoped to `company_id = get_company_id()`. Preorders are further scoped to the cashier's branch via `branch_id = get_user_branch_id()` or branch_users lookup.
- **No DELETE policies**: Logical deletion only — `is_active = false`, `deleted_at`, `deleted_by` on customers, customer_requests, preorders, and preorder_items. Preorder items have independent logical deletion columns per the final design decision.
- **`set_updated_at()` trigger**: All four tables use the existing `set_updated_at()` trigger from migration 00002.

## Risks and Mitigations

| Risk | Severity | Mitigation |
|------|----------|------------|
| Reservation expectations | Medium | Explicitly document in spec and migration comments that V1 preorders do not commit inventory. The `reserve_stock()` RPC exists as a V1 rejection stub in the inventory domain and is not called. |
| Cross-tenant variant/customer references | Medium | All FKs use composite `(company_id, id)` pattern matching catalog, inventory, and purchasing conventions. |
| Cashier preorder access scoping | Low | Preorders branch-scoped via `branch_id` in RLS policy. Cashier sees only their assigned branch's preorders. |
| `preorder_items` without logical deletion | Low | `preorder_items` are sub-entities of `preorders` and follow parent lifecycle. No independent `is_active`/`deleted_at` columns — parent deactivation implies child deactivation. This matches `purchase_order_items` pattern from 00006. |
| No server-side state machine enforcement on preorders | Low | V1 preorders have no stock commitment, so incorrect status transitions have no financial/inventory consequence. When stock reservation is activated in a future domain, an RPC-enforced state machine MUST be added. |
| Variant deletion after customer request references it | Low | `variant_id` on `customer_requests` is nullable. If a variant is deactivated, existing requests retain the reference but `variant.is_active = false`. The FK is `ON DELETE RESTRICT` by default — variant physical deletion is already prohibited by catalog domain (RC4). |

## Rollback Plan

Drop migration `00007_customers_demand_domain.sql` and run `supabase db reset`. Since all entities are new (no catalog, inventory, or purchasing schema modifications), rollback is a clean removal. `supabase db reset` restores pre-customers state.

No downstream domains depend on customers-demand-domain yet (pos-sales-domain is domain #6 in the roadmap R10 chain). The `customers` table is a prerequisite for credit-payments (domain #8), but that domain has not been started.

## Dependencies

- Bootstrap architecture (migrations 00001–00003): companies, branches, profiles, RLS helpers, `get_company_id()`, `is_admin()`, `get_user_branch_id()` — archived and verified
- Catalog domain (migration 00004): `product_variants`, composite FK pattern — archived and verified
- Inventory domain (migration 00005): reservation stubs verified; no integration needed for V1 — archived and verified
- Purchasing domain (migration 00006): no integration needed for V1; composite FK pattern confirmed — archived and verified
- Supabase CLI runtime operational locally

## Acceptance Criteria

- [ ] Migration `00007_customers_demand_domain.sql` creates all 4 tables with correct composite FKs, indexes, unique constraints, and `set_updated_at()` triggers
- [ ] RLS policies enforce tenant isolation: admin sees/edits own-company rows; cashier read-only (branch-scoped for preorders); unauthenticated returns zero rows
- [ ] `customers` table enforces `(company_id, slug)` uniqueness and logical deletion via `is_active`, `deleted_at`, `deleted_by`
- [ ] `customer_requests.variant_id` accepts NULL (requests for uncatalogued products) and validates non-NULL values via composite FK
- [ ] `preorder_items.variant_id` is NOT NULL and references `product_variants(company_id, id)` via composite FK
- [ ] Preorder status values constrained to `draft`, `confirmed`, `fulfilled`, `cancelled` via CHECK constraint
- [ ] Customer request status values constrained to `pending`, `resolved`, `cancelled` via CHECK constraint
- [ ] No V1 inventory reservation: preorder creation/confirmation does not call `reserve_stock()` or modify `stock_lots`
- [ ] `supabase test db` passes all pgTAP tests
- [ ] No Edge Functions or RPCs created for this domain in V1
- [ ] `supabase db reset` applies all migrations idempotently in order (00001 → 00007)

## Open Decisions

| # | Decision | Context | Recommendation | Status |
|---|----------|---------|----------------|--------|
| 1 | Edge Functions for customer/preorder mutations | Exploration says no EFs/RPCs expected unless proposal justifies critical mutation boundary. Customer data and preorders do not touch money, inventory, or collections — constitution R2 only mandates EFs for critical ops. | **Recommend SDK + RLS for V1**: customer CRUD is not a critical op per constitution; preorders without stock commitment are demand signals, not inventory mutations. Add EF→RPC when stock reservation is activated (future domain). | Unresolved |
| 2 | `customer_requests.variant_id` nullable vs separate `requested_product_name` TEXT | Exploration suggests nullable `variant_id` for "not yet catalogued" cases. Alternative: free-text field for uncatalogued product names. | **Recommend nullable `variant_id`**: simpler schema; migration 00007 only adds FK. If uncatalogued requests become common, add a `requested_product_description` TEXT column later without breaking existing data. | Unresolved |
| 3 | `preorder_items.unit_price` nullable vs NOT NULL | Preorder prices may not be known at preorder time; they could be set when the sale is made (pos-sales-domain). | **Recommend nullable**: V1 preorders are demand signals only. Price is optional at preorder time and mandatory at sale time (future domain). | Unresolved |
| 4 | Preorder number auto-generation | Should `preorders` have a human-readable `preorder_number` like `purchase_orders.order_number` and `purchase_receipts.receipt_number`? | **Recommend defer to design phase**: adding a `preorder_number TEXT UNIQUE (company_id, preorder_number)` column in 00007 is low-risk, but exploration does not specify it. Can be added in design if the migration is still small enough for single slice. | Unresolved |
| 5 | `preorder_items` logical deletion columns | Should `preorder_items` have `is_active`, `deleted_at`, `deleted_by` or follow parent `preorders` lifecycle only? | **Recommend follow parent lifecycle**: `purchase_order_items` in 00006 has `is_active` and audit columns. Consistency with that pattern suggests adding them. Resolve in design phase. | Unresolved |
