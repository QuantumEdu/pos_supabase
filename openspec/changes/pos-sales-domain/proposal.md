# Proposal: POS Sales Domain

## Problem

POS sales is the core transactional domain of the POS system. It handles sale creation, cancellation, discount authorization, payment recording, and inventory deduction at point of sale. Without this domain, the system cannot process customer transactions. The cash session dependency has been resolved (migration `00008_cash_session_domain.sql`), enabling POS sales to reference open cash sessions directly.

## Goals

V1 MUST support:

1. **Create a sale** with items, payments, and FEFO inventory deduction — linked to an open cash session
2. **Cancel a sale** with inventory reversal
3. **Authorize discounts** (manager/admin override) with audit trail
4. **Record multiple payment methods** per sale (cash, card, transfer, credit)
5. **Track exact inventory lots** consumed per sale item for traceability and returns

## Non-goals (deferred from V1)

The following are explicitly deferred:

- Invoices / CFDI / electronic billing
- Thermal ticket or PDF receipt generation
- Advanced promotions engine
- External payment gateway integrations
- Partial returns or item-level returns
- Customer balance ledger and payment plans (abonos)
- Preorder-to-sale fulfillment workflow (`preorder_id` column reserved but not required in V1)

## Data Model Overview

### `sales`

Branch-scoped sale header. Every sale belongs to an open cash session.

| Column | Type | Notes |
|--------|------|-------|
| `id` | UUID PK | `gen_random_uuid()` |
| `company_id` | UUID NOT NULL | Composite FK `(company_id, branch_id) -> branches` |
| `branch_id` | UUID NOT NULL | |
| `cashier_user_id` | UUID NOT NULL | The user who created the sale |
| `customer_id` | UUID NULL | Nullable for cash/walk-in; REQUIRED if any payment method is `credit` |
| `cash_session_id` | UUID NOT NULL | FK to `cash_sessions(company_id, id)` — validates session is open |
| `preorder_id` | UUID NULL | Reserved for future preorder fulfillment |
| `status` | TEXT NOT NULL | `CHECK IN ('active', 'cancelled')` |
| `subtotal` | NUMERIC(12,2) NOT NULL | |
| `discount_amount` | NUMERIC(12,2) NOT NULL DEFAULT 0 | |
| `tax_amount` | NUMERIC(12,2) NOT NULL DEFAULT 0 | |
| `total` | NUMERIC(12,2) NOT NULL | |
| `sale_number` | BIGINT NOT NULL | Branch-scoped sequential number |
| `notes` | TEXT | |
| Audit columns | | `created_at`, `updated_at`, `created_by`, `updated_by` |
| Logical-delete columns | | `is_active`, `deleted_at`, `deleted_by` |

### `sale_items`

Line items for each sale. Links to `inventory.product_variants` but does not FK directly (prices are captured at sale time).

| Column | Type | Notes |
|--------|------|-------|
| `id` | UUID PK | |
| `company_id` | UUID NOT NULL | Composite FK `(company_id, sale_id) -> sales` |
| `sale_id` | UUID NOT NULL | |
| `variant_id` | UUID NOT NULL | Reference to `product_variants.id` |
| `quantity` | NUMERIC(12,3) NOT NULL | |
| `unit_price` | NUMERIC(12,2) NOT NULL | Price at time of sale |
| `discount_percent` | NUMERIC(5,2) NOT NULL DEFAULT 0 | |
| `discount_amount` | NUMERIC(12,2) NOT NULL DEFAULT 0 | |
| `tax_percent` | NUMERIC(5,2) NOT NULL DEFAULT 0 | |
| `tax_amount` | NUMERIC(12,2) NOT NULL DEFAULT 0 | |
| `line_total` | NUMERIC(12,2) NOT NULL | Computed total after discounts and taxes |
| `is_manual_price` | BOOLEAN NOT NULL DEFAULT false | True if cashier overrode the price |
| Audit columns | | Standard |

### `sale_item_batches`

Tracks exact inventory lots consumed per sale item. Required for FEFO traceability and future returns.

| Column | Type | Notes |
|--------|------|-------|
| `id` | UUID PK | |
| `company_id` | UUID NOT NULL | |
| `sale_item_id` | UUID NOT NULL | FK to `sale_items` |
| `lot_id` | UUID NOT NULL | FK to `inventory.lots` |
| `quantity` | NUMERIC(12,3) NOT NULL | |
| `cost_price` | NUMERIC(12,2) NULL | Cost at time of deduction |

### `payments`

One or more payment rows per sale. Supports mixed payments.

| Column | Type | Notes |
|--------|------|-------|
| `id` | UUID PK | |
| `company_id` | UUID NOT NULL | Composite FK `(company_id, sale_id) -> sales` |
| `sale_id` | UUID NOT NULL | |
| `payment_method` | TEXT NOT NULL | `CHECK IN ('cash', 'card', 'transfer', 'credit')` |
| `amount` | NUMERIC(12,2) NOT NULL | |
| `reference` | TEXT NULL | External reference (card transaction ID, check number, etc.) |
| Audit columns | | Standard |

### `discount_authorizations`

Audit trail for manager/admin discount overrides.

| Column | Type | Notes |
|--------|------|-------|
| `id` | UUID PK | |
| `company_id` | UUID NOT NULL | |
| `sale_id` | UUID NOT NULL | |
| `authorized_by` | UUID NOT NULL | Admin user who approved |
| `authorized_at` | TIMESTAMPTZ NOT NULL | |
| `discount_percent` | NUMERIC(5,2) NOT NULL | |
| `discount_amount` | NUMERIC(12,2) NOT NULL | |
| `reason` | TEXT NOT NULL | |
| Audit columns | | Standard |

## V1 Domain Boundaries

### In scope

| Operation | Description |
|-----------|-------------|
| `create-sale` | Creates sale header, items, payments; validates open cash session; calls FEFO inventory deduction; persists lot mapping |
| `cancel-sale` | Reverses inventory deduction; marks sale as `cancelled` |
| `authorize-discount` | Records admin authorization for a discount on a sale |
| RLS reads | SDK-based reads for sale history, dashboard, reports |

### Deferred (out of V1)

- Invoices, receipts, tickets
- Partial returns, item returns
- Customer credit management
- Preorder fulfillment
- Promotions engine
- External payment gateway integration

## Critical Mutation Boundary

The following operations MUST be implemented as Edge Functions calling SECURITY DEFINER RPCs:

1. **`create-sale`** — The EF validates auth + cashier role, verifies an open cash session exists for the cashier+branch, validates the request payload, then calls the `create_sale_transaction` RPC. The RPC creates the sale header, items, payments, calls `record_sale_deduction` for FEFO lot deduction, persists `sale_item_batches`, and returns the completed sale. All in a single transaction.

2. **`cancel-sale`** — The EF validates auth + cashier/admin role, then calls the `cancel_sale_transaction` RPC. The RPC reverses inventory deduction, marks the sale as `cancelled`, and returns the cancellation result.

3. **`authorize-discount`** — The EF validates auth + admin role, then calls `authorize_discount` RPC to persist the authorization record.

Direct SDK writes to `sales`, `sale_items`, `sale_item_batches`, `payments`, and `discount_authorizations` MUST be rejected by RLS for all authenticated roles. Only the `service_role` client (via EF) may write.

## Cash Session Integration

- `create-sale` MUST validate that `cash_sessions` has an open session for `(company_id, branch_id, cashier_user_id)` before proceeding. This SHALL be enforced inside the `create_sale_transaction` RPC — not only in the EF layer.
- `sales.cash_session_id` is REQUIRED (NOT NULL). Every sale must belong to an open session.
- The RPC SHALL read `cash_sessions` status = `'open'` and is_active = `true` for the given cashier+branch.
- Future: `close_cash_session` SHALL verify no active sales exist for the session before closing.

## Inventory Integration

- `create_sale_transaction` RPC SHALL call `record_sale_deduction(p JSONB)` within the same transaction to perform FEFO lot deduction.
- The RPC SHALL persist the consumed lots in `sale_item_batches` for traceability.
- `cancel_sale_transaction` RPC SHALL reverse inventory deduction via an inventory reversal RPC.
- All inventory mutations and sale data mutations MUST be atomic within a single PostgreSQL transaction.

## Dependencies

| Domain | Status | Artifact | Dependency Type |
|--------|--------|----------|-----------------|
| cash-session-domain | ✅ Archived | `00008_cash_session_domain.sql` | Direct: sales require open session |
| inventory-domain | ✅ Archived | Migrations `00005_*` | Direct: FEFO deduction |
| customers-demand-domain | ✅ Archived | Migration `00007_*` | Optional: customer reference |

## Open Decisions

1. **Cash session validation layer**: Should `cash_session_id` be validated by the EF (via a helper RPC) or by the `create_sale_transaction` RPC? Decision: RPC — guarantees atomicity and prevents race conditions between auth and mutation.
2. **Sale number sequence**: Use a DB sequence per branch or an application-level counter? Decision: DB sequence `sale_number_seq` per `(company_id, branch_id)` for gapless ordering within a branch.
3. **Discount authorization timing**: Should `authorize-discount` run before sale creation or can it be recorded after the sale? Decision: can be recorded after (audit trail), but the sale SHALL store the approved discount percent.
4. **Cancel-sale authorization**: Should cancel require a separate authorization token or just the original cashier? Decision: the original cashier OR any admin in the same company can cancel. The RPC SHALL verify the caller is authorized via company membership.
5. **Manual price override tracking**: Should manual price overrides be logged separately? Decision: `sale_items.is_manual_price` flag suffices for V1.

## Rollback Plan

1. **Migration revert**: Run `supabase migration squash 00009` to remove the migration, then `supabase db reset` to rebuild.
2. **EF removal**: Delete `supabase/functions/pos-sales/` directories before next deployment.
3. **pgTAP rollback**: Remove or comment out `test_pos_sales_*.sql` files and re-run `supabase test db`.
4. **Data safety**: Since V1 sales are real transactions, if rollback is needed after production data exists, prefer a forward fix over destructive rollback.
