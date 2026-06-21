# Proposal: Purchasing Domain Implementation

## Problem Statement

The POS system currently has catalog and inventory domains but no purchasing capability. Suppliers cannot be registered, purchase orders cannot be created, and merchandise receipt has no purchasing audit trail. The `receive_purchase_lot` inventory RPC exists but is called in isolation — there is no purchase-order validation, no received-quantity tracking, and no PO status lifecycle. This blocks all procurement workflows.

## Goals

1. Add supplier master data with logical deletion and company scoping.
2. Add purchase orders with draft → sent → partial → received lifecycle and cancellation support.
3. Add purchase receipts linked to purchase orders, with item-level lot metadata.
4. Atomically bridge receipts into inventory via a purchasing master RPC that calls `receive_purchase_lot`, updates `purchase_order_items.received_qty`, and transitions PO status — all in one database transaction.
5. Enforce composite FK patterns, RLS multi-tenant isolation, and the 8-step EF mutation boundary per constitution.

## Non-Goals

- Receipt cancellation with inventory reversal (deferred: complex lot/movement reversal workflow).
- Supplier performance analytics, automatic purchase suggestions.
- Supplier catalogs, supplier-specific price lists.
- CFDI / electronic invoicing.
- Multi-currency purchasing.
- Purchase returns to supplier.
- Frontend / UI.

## Scope

### In Scope

- Migration `00006_purchasing_domain.sql`: tables `suppliers`, `purchase_orders`, `purchase_order_items`, `purchase_receipts`, `purchase_receipt_items`
- Master RPC `receive_purchase_transaction(p JSONB)` — SECURITY DEFINER, single transaction that inserts receipt + receipt items, calls `receive_purchase_lot` per item, updates `received_qty`, and transitions PO status
- RPCs: `create_purchase_order(p JSONB)`, `cancel_purchase_order(p JSONB)`
- Edge Functions: `purchasing/create-purchase-order`, `purchasing/receive-purchase-order`, `purchasing/cancel-purchase-order`
- RLS policies: admin mutation, cashier read-only, service_role bypass, zero rows for unauthenticated
- pgTAP tests (constraints, RLS, RPCs) + Deno.test EF tests
- Supplier CRUD via SDK + RLS (read) and optional EF→RPC path for create/update/deactivate

### Out of Scope

- Receipt cancellation / inventory reversal
- Automatic lot code generation for receipts (passed through to `receive_purchase_lot`)
- Supplier performance analytics
- Multi-currency purchasing
- Purchase returns to supplier

## Capabilities

### New Capabilities

- `purchasing-domain`: supplier management, purchase orders, partial/full receipts, atomic inventory integration, PO lifecycle

### Modified Capabilities

- None. Existing catalog and inventory schemas, RPCs, and EFs are not modified. The `product_variants.last_cost` column addition is an open decision (see §Open Decisions) and would be the only potential modification to an existing table.

## Approach

Single change with 4 chained PR slices:

| PR | Slice | Content | Est. Lines |
|----|-------|---------|------------|
| 1 | Schema + RLS | Migration: 5 tables, indexes, composite FKs, RLS policies + pgTAP tests | ~350–400 |
| 2 | RPC Functions | `create_purchase_order`, `receive_purchase_transaction`, `cancel_purchase_order` + supplier CRUD RPCs + pgTAP tests | ~300–350 |
| 3 | Edge Functions + Tests | `purchasing/create-purchase-order`, `purchasing/receive-purchase-order`, `purchasing/cancel-purchase-order` + Deno.test | ~250–300 |
| 4 | Verify + Spec Alignment | `supabase db reset`, `deno test`, `supabase test db`, audit trail validation, delta spec | ~50–100 |

Chain strategy: `feature/purchasing-domain` base → each PR targets the previous PR's branch.

Core architectural decision: the master RPC `receive_purchase_transaction(p JSONB)` is the sole path for receiving merchandise against a purchase order. It validates the PO exists and is in a receivable state, validates all items belong to the PO, inserts `purchase_receipts` + `purchase_receipt_items`, calls `public.receive_purchase_lot` for each received item, updates `purchase_order_items.received_qty`, and transitions PO status. The Edge Function `purchasing/receive-purchase-order` delegates the entire workflow to this RPC in a single call — no looping from the Edge Function.

## V1 Domain Boundaries

```
┌──────────────────────────────────────────────────────┐
│                  Purchasing Domain V1                 │
│                                                      │
│  suppliers ─────────────────────────────────┐        │
│  purchase_orders ── purchase_order_items    │        │
│  purchase_receipts ── purchase_receipt_items│        │
│                                              │        │
│  RPCs:                                       │        │
│    create_purchase_order                    │        │
│    receive_purchase_transaction ──► inventory│        │
│    cancel_purchase_order                   │        │
│                                              │        │
│  EFs:                                        │        │
│    purchasing/create-purchase-order          │        │
│    purchasing/receive-purchase-order         │        │
│    purchasing/cancel-purchase-order          │        │
└──────────────────────────────────────────────────────┘
```

Cross-domain touchpoints:
- **Catalog**: `purchase_order_items.variant_id` → `product_variants(id)` via composite FK `(company_id, variant_id)`
- **Inventory**: `receive_purchase_transaction` calls `receive_purchase_lot(p JSONB)` — the existing inventory RPC is not modified
- **Companies/Branches**: composite FKs to `companies(id)` and `branches(id)` following the catalog/inventory pattern

## Data Model Overview

### `suppliers`

| Column | Type | Notes |
|--------|------|-------|
| `id` | UUID PK | `gen_random_uuid()` |
| `company_id` | UUID NOT NULL | FK → `companies(id)` |
| `name` | TEXT NOT NULL | |
| `slug` | TEXT NOT NULL | Unique per company `(company_id, slug)` |
| `tax_id` | TEXT | RFC / tax identifier |
| `contact_name` | TEXT | |
| `phone` | TEXT | |
| `email` | TEXT | |
| `address` | TEXT | |
| `notes` | TEXT | |
| `is_active` | BOOLEAN DEFAULT TRUE | Logical deletion |
| `created_at`, `updated_at`, `created_by`, `updated_by` | | Audit |
| `deleted_at`, `deleted_by` | | Logical deletion audit |

Composite unique: `(company_id, id)`, `(company_id, slug)`.

### `purchase_orders`

| Column | Type | Notes |
|--------|------|-------|
| `id` | UUID PK | `gen_random_uuid()` |
| `company_id` | UUID NOT NULL | FK → `companies(id)` |
| `branch_id` | UUID NOT NULL | FK → `branches(id)` |
| `supplier_id` | UUID NOT NULL | FK → `suppliers(id)` |
| `order_number` | TEXT NOT NULL | Unique per company |
| `status` | TEXT NOT NULL DEFAULT 'draft' | `draft`, `sent`, `partial`, `received`, `cancelled` |
| `order_date` | DATE NOT NULL DEFAULT CURRENT_DATE | |
| `expected_date` | DATE | |
| `payment_method` | TEXT | Simple text field for V1 |
| `subtotal` | NUMERIC(12,2) NOT NULL DEFAULT 0 | |
| `tax_total` | NUMERIC(12,2) NOT NULL DEFAULT 0 | |
| `total` | NUMERIC(12,2) NOT NULL DEFAULT 0 | |
| `notes` | TEXT | |
| `is_active` | BOOLEAN DEFAULT TRUE | |
| Audit columns | | Standard |

Composite unique: `(company_id, id)`, `(company_id, order_number)`. Composite FK: `(company_id, branch_id)` → `branches(company_id, id)`, `(company_id, supplier_id)` → `suppliers(company_id, id)`.

### `purchase_order_items`

| Column | Type | Notes |
|--------|------|-------|
| `id` | UUID PK | `gen_random_uuid()` |
| `company_id` | UUID NOT NULL | |
| `purchase_order_id` | UUID NOT NULL | FK → `purchase_orders(id)` |
| `variant_id` | UUID NOT NULL | FK → `product_variants(id)` |
| `ordered_qty` | NUMERIC(14,3) NOT NULL | |
| `received_qty` | NUMERIC(14,3) NOT NULL DEFAULT 0 | Denormalized cache; RPC-only mutation |
| `unit_cost` | NUMERIC(12,2) NOT NULL | |
| `tax_rate` | NUMERIC(6,4) NOT NULL DEFAULT 0 | |
| `tax_amount` | NUMERIC(12,2) NOT NULL DEFAULT 0 | |
| `subtotal` | NUMERIC(12,2) NOT NULL DEFAULT 0 | |
| `is_active` | BOOLEAN DEFAULT TRUE | |
| Audit columns | | Standard |

Composite FK: `(company_id, purchase_order_id)` → `purchase_orders(company_id, id)`, `(company_id, variant_id)` → `product_variants(company_id, id)`. `received_qty` is protected from direct authenticated writes — only SECURITY DEFINER RPCs mutate it. CHECK: `received_qty <= ordered_qty`.

### `purchase_receipts`

| Column | Type | Notes |
|--------|------|-------|
| `id` | UUID PK | `gen_random_uuid()` |
| `company_id` | UUID NOT NULL | |
| `branch_id` | UUID NOT NULL | |
| `purchase_order_id` | UUID NOT NULL | FK → `purchase_orders(id)` |
| `receipt_number` | TEXT NOT NULL | Unique per company |
| `receipt_date` | DATE NOT NULL DEFAULT CURRENT_DATE | |
| `status` | TEXT NOT NULL DEFAULT 'completed' | `completed`, `cancelled` (cancellation deferred) |
| `notes` | TEXT | |
| `is_active` | BOOLEAN DEFAULT TRUE | |
| Audit columns | | Standard |

Composite unique: `(company_id, id)`, `(company_id, receipt_number)`. Composite FK: `(company_id, purchase_order_id)` → `purchase_orders(company_id, id)`, `(company_id, branch_id)` → `branches(company_id, id)`.

### `purchase_receipt_items`

| Column | Type | Notes |
|--------|------|-------|
| `id` | UUID PK | `gen_random_uuid()` |
| `company_id` | UUID NOT NULL | |
| `purchase_receipt_id` | UUID NOT NULL | FK → `purchase_receipts(id)` |
| `purchase_order_item_id` | UUID NOT NULL | FK → `purchase_order_items(id)` |
| `variant_id` | UUID NOT NULL | FK → `product_variants(id)` |
| `received_qty` | NUMERIC(14,3) NOT NULL | |
| `unit_cost` | NUMERIC(12,2) NOT NULL | |
| `tax_rate` | NUMERIC(6,4) NOT NULL DEFAULT 0 | |
| `tax_amount` | NUMERIC(12,2) NOT NULL DEFAULT 0 | |
| `subtotal` | NUMERIC(12,2) NOT NULL DEFAULT 0 | |
| `lot_code` | TEXT | Passed to `receive_purchase_lot`; auto-generated if null |
| `expiration_date` | DATE | Passed to `receive_purchase_lot` |
| `is_active` | BOOLEAN DEFAULT TRUE | |
| Audit columns | | Standard |

Composite FK: `(company_id, purchase_receipt_id)` → `purchase_receipts(company_id, id)`, `(company_id, purchase_order_item_id)` → `purchase_order_items(company_id, id)`, `(company_id, variant_id)` → `product_variants(company_id, id)`.

### PO Status Lifecycle

```
draft ──► sent ──► partial ──► received
  │         │         │
  └─────────┴─────────┴──► cancelled
```

- `draft → sent`: order submitted to supplier.
- `sent → partial`: first receipt received but not all items fully received.
- `partial → received`: all items have `received_qty = ordered_qty`.
- `draft|sent|partial → cancelled`: order cancelled. Partially received POs close without reversing existing receipts.
- `received → cancelled`: prohibited (all merchandise already received).

## Edge Functions and RPCs

### RPCs

| RPC | Behavior | Auth |
|-----|----------|------|
| `create_purchase_order(p JSONB)` | Validates supplier/branch/variant, inserts PO + items atomically. Sets status `draft`. SECURITY DEFINER. | Admin |
| `receive_purchase_transaction(p JSONB)` | Master receipt RPC. Validates PO receivable state, inserts receipt + receipt items, calls `receive_purchase_lot` per item, updates `received_qty`, transitions PO status (`sent→partial` or `partial→received`). Single transaction. SECURITY DEFINER. | Admin |
| `cancel_purchase_order(p JSONB)` | Validates PO in cancellable state (not `received`), sets status `cancelled`. Partially received: closes without reversing receipts. SECURITY DEFINER. | Admin |

All RPCs: `SET search_path = public`, `REVOKE ALL FROM PUBLIC, anon`, `GRANT EXECUTE TO authenticated`. Independently verify `company_id` matches authenticated user.

### Edge Functions

| EF | Method | RPC Called | Auth |
|----|--------|------------|------|
| `purchasing/create-purchase-order` | POST | `create_purchase_order` | Admin (8-step) |
| `purchasing/receive-purchase-order` | POST | `receive_purchase_transaction` | Admin (8-step) |
| `purchasing/cancel-purchase-order` | POST | `cancel_purchase_order` | Admin (8-step) |

All EFs follow catalog/inventory 8-step pattern: validate user → company → branch → role → input → invoke RPC → audit → return `EFResult<T>`.

Supplier CRUD: reads via SDK + RLS. Mutations: Edge Function `purchasing/manage-supplier` → `manage_supplier(p JSONB)` RPC (open decision — see §Open Decisions).

## Integration Points

### With Inventory (`receive_purchase_lot`)

`receive_purchase_transaction` loops over receipt items inside a single PL/pgSQL transaction and calls `public.receive_purchase_lot(p JSONB)` for each item. The inventory RPC is NOT modified. The purchasing RPC passes:

```json
{
  "company_id": "<from receipt>",
  "branch_id": "<from receipt>",
  "variant_id": "<from receipt item>",
  "qty": "<received_qty from item>",
  "lot_code": "<from receipt item, optional>",
  "expiration_date": "<from receipt item, optional>",
  "cost_per_unit": "<unit_cost from item>",
  "reference_type": "purchase_receipt",
  "reference_id": "<purchase_receipts.id>",
  "notes": "<receipt notes>"
}
```

The inventory RPC creates `stock_lots` and `stock_movements` (type `purchase_receipt`). The purchasing RPC handles the purchasing-side audit trail and PO status transition.

### With Catalog (`product_variants`)

`purchase_order_items.variant_id` and `purchase_receipt_items.variant_id` reference `product_variants(id)` via composite FK `(company_id, variant_id)`. The catalog schema is not modified.

**Open decision**: whether to add `product_variants.last_cost NUMERIC(12,2)` in `00006` and update it atomically during receipt. If adopted, `receive_purchase_transaction` would also `UPDATE product_variants SET last_cost = receipt_item.unit_cost, updated_at = now()` after inventory receipt.

## Security / RLS Approach

All 5 tables: `company_id = get_company_id()` RLS policies matching catalog/inventory pattern.

| Role | Suppliers | Purchase Orders | PO Items | Receipts | Receipt Items |
|------|-----------|-----------------|----------|----------|---------------|
| Admin | Read/Write | Read/Write (via RPC) | Read/Write (via RPC) | Read/Write (via RPC) | Read/Write (via RPC) |
| Cashier | Read | Read | Read | Read | Read |
| Unauthenticated | Zero rows | Zero rows | Zero rows | Zero rows | Zero rows |
| Service role | ALL bypass | ALL bypass | ALL bypass | ALL bypass | ALL bypass |

Critical protections:
- `purchase_order_items.received_qty`: RLS denies direct authenticated UPDATE; only SECURITY DEFINER RPCs mutate it
- `purchase_orders.status`: RLS denies direct authenticated UPDATE; only SECURITY DEFINER RPCs transition state
- PO `total`, `subtotal`, `tax_total`: computed/validated server-side in RPC, NOT client-supplied final values (RPC recalculates from items)
- No DELETE policies — logical deletion only (`is_active = false`, `deleted_at`, `deleted_by`)

## Risks and Mitigations

| Risk | Severity | Mitigation |
|------|----------|------------|
| `received_qty` drift from inventory vs purchasing | High | Both updated in single transaction by `receive_purchase_transaction`; block direct writes via RLS |
| Cross-tenant FK mistakes | High | Composite FKs `(company_id, id)` on all FK relationships, following catalog/inventory pattern |
| Multi-item receipt partial failure | High | Single PL/pgSQL transaction in `receive_purchase_transaction`; Edge Function does NOT loop — one call, one transaction |
| Receipt cancellation complexity | Medium | Deferred from V1; receipt `status` field has `cancelled` enum value as placeholder only |
| Concurrent receipts on same PO cause `received_qty` race | Medium | `SELECT FOR UPDATE` on `purchase_order_items` rows inside `receive_purchase_transaction` |
| Supabase Edge Function timeout on large receipts | Low | Single RPC call, not N+1; entirely server-side transaction; timeout only a risk for extremely large POs |
| Missing `last_cost` on variants | Low | Open decision — if deferred, `unit_cost` on `purchase_order_items` and `purchase_receipt_items` still capture cost; `last_cost` is a convenience denormalization |
| `cancel_purchase_order` semantics for partial POs ambiguous | Low | Explicitly designed: partially received POs cancel without reversing inventory; spec must be clear |

## Rollback Plan

Drop migration `00006_purchasing_domain.sql` and remove all `supabase/functions/purchasing/` directories. Since all entities are new (no catalog or inventory modifications), rollback is a clean removal. `supabase db reset` restores pre-purchasing state. No downstream domains depend on purchasing yet (customers-demand is domain #4 per R10).

If the `product_variants.last_cost` open decision is adopted and migration `00006` adds the column: rollback drops the column via a separate migration or manual DDL. This is a narrow, reversible schema change.

## Dependencies

- Bootstrap architecture (migrations 00001–00003): companies, branches, profiles, RLS helpers — archived and verified
- Catalog domain (migration 00004): `product_variants`, composite FK pattern — archived and verified
- Inventory domain (migration 00005): `receive_purchase_lot` RPC, `stock_lots`, `stock_movements` — archived and verified
- Supabase CLI + Deno runtime operational locally

## Acceptance Criteria

- [ ] Migration `00006_purchasing_domain.sql` creates all 5 tables with correct composite FKs, indexes, and constraints
- [ ] RLS policies enforce tenant isolation; cashier cannot mutate; unauthenticated returns zero rows
- [ ] `create_purchase_order` RPC atomically creates PO header + items; validates supplier/branch/variant existence
- [ ] `receive_purchase_transaction` RPC: inserts receipt + items, calls `receive_purchase_lot` per item, updates `received_qty`, transitions PO status — all in one transaction
- [ ] Partial receipts increment `received_qty` without overshooting `ordered_qty`
- [ ] PO transitions to `partial` on first receipt, `received` when all items fully received
- [ ] `cancel_purchase_order` works on `draft`, `sent`, `partial` statuses; rejects `received`; does not reverse inventory
- [ ] No direct authenticated writes to `received_qty` or `purchase_orders.status`
- [ ] All 3 Edge Functions follow 8-step pattern, return `EFResult<T>`, and reject non-admin
- [ ] `deno test` and `supabase test db` pass
- [ ] Supplier CRUD respects logical deletion; slug and name constraints enforced

## Open Decisions

| # | Decision | Context | Recommendation | Status |
|---|----------|---------|----------------|--------|
| 1 | Add `product_variants.last_cost` in `00006` | `last_cost` would be updated atomically on receipt. Catalog spec RC4 does not currently include this column. If deferred, cost data lives only in purchasing tables. | **Recommend adding**: low-risk denormalization, single-column addition to existing table, updated by master RPC within same transaction. | Unresolved |
| 2 | Supplier mutations: EF→RPC or SDK+RLS | Exploration suggests SDK+RLS may suffice for supplier CRUD, but consistency with catalog/inventory EF pattern argues for EF→RPC. | **Recommend EF→RPC**: consistency with catalog CRUD pattern, aligns with constitution R11 (all critical ops through EFs). Supplier data integrity matters for audit. | Unresolved |
| 3 | `payment_method` as simple text or enum | V1 scope suggests simple text field on `purchase_orders`. An enum or separate `payment_methods` table could be added later. | **Recommend TEXT**: simplest V1 approach; migrate to enum/table later with minimal disruption. | Unresolved |
| 4 | `cancel_purchase_order` for partially received POs | Should partially received POs be cancellable? Exploration says yes — close without reversing receipts. | **Recommend yes**: close PO at `cancelled`, preserve receipts and inventory. Receipt cancellation is a separate deferred workflow. | Unresolved |
