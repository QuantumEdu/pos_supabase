# Purchasing Domain Exploration

## Executive Summary

The purchasing domain should be implemented as `00006_purchasing_domain.sql`, after catalog and inventory. It will add supplier management, purchase orders, purchase receipts, and a transactional bridge into the existing inventory RPC `receive_purchase_lot(p JSONB)`. The key architectural decision is to use a purchasing master RPC (`receive_purchase_transaction`) so receipt creation, receipt items, inventory lots, inventory movements, and purchase-order status updates happen atomically in one database transaction.

## Entities

### `suppliers`

Company-scoped supplier master data with logical deletion.

Recommended fields: `id`, `company_id`, `name`, `slug`, `tax_id`, `contact_name`, `phone`, `email`, `address`, `notes`, `is_active`, audit columns, and logical deletion columns.

### `purchase_orders`

Purchase order header linked to company, branch, and supplier.

Recommended fields: `id`, `company_id`, `branch_id`, `supplier_id`, `order_number`, `status`, `order_date`, `expected_date`, `payment_method`, `subtotal`, `tax_total`, `total`, `notes`, `is_active`, audit columns, and logical deletion columns.

### `purchase_order_items`

Line items linked to product variants.

Recommended fields: `id`, `company_id`, `purchase_order_id`, `variant_id`, `ordered_qty`, `received_qty`, `unit_cost`, `tax_rate`, `tax_amount`, `subtotal`, `is_active`, and audit columns.

`received_qty` is a denormalized cache and should be protected from direct authenticated updates. Only SECURITY DEFINER RPCs should mutate it.

### `purchase_receipts`

Receipt header linked to a purchase order and branch.

Recommended fields: `id`, `company_id`, `branch_id`, `purchase_order_id`, `receipt_number`, `receipt_date`, `status`, `notes`, `is_active`, audit columns, and logical deletion columns.

### `purchase_receipt_items`

Received quantities and lot metadata.

Recommended fields: `id`, `company_id`, `purchase_receipt_id`, `purchase_order_item_id`, `variant_id`, `received_qty`, `unit_cost`, `tax_rate`, `tax_amount`, `subtotal`, `lot_code`, `expiration_date`, `is_active`, and audit columns.

## Workflow

Purchase order states:

```text
draft -> sent -> partial -> received
```

Cancellation is allowed before receipt and may close partially received orders without undoing existing receipts. Receipt cancellation should be deferred because reversing inventory lots and movements is a separate complex workflow.

Core invariants:

- Creating a purchase order does not increase inventory.
- Receiving merchandise increases inventory.
- `received_qty <= ordered_qty` for every line item.
- A purchase order becomes `received` only when all items are fully received.
- Partial receipts are supported.

## Integration With Inventory

The existing inventory RPC is:

```sql
public.receive_purchase_lot(p JSONB) RETURNS JSONB
```

Expected input includes: `company_id`, `branch_id`, `variant_id`, `qty`, optional `lot_code`, optional `expiration_date`, optional `cost_per_unit`, optional `reference_type`, optional `reference_id`, and optional `notes`.

Purchasing should not modify this RPC. Instead, `receive_purchase_transaction(p JSONB)` should validate the purchase order and receipt items, insert purchasing records, call `receive_purchase_lot` for each received item, update `purchase_order_items.received_qty`, and transition the purchase order status in one transaction.

Recommended receipt flow:

```text
purchasing/receive-purchase-order EF
  -> receive_purchase_transaction(p JSONB)
     -> INSERT purchase_receipts
     -> INSERT purchase_receipt_items
     -> CALL receive_purchase_lot(p JSONB)
     -> UPDATE purchase_order_items.received_qty
     -> UPDATE purchase_orders.status
```

## Edge Functions And RPCs

Recommended V1 Edge Functions:

- `purchasing/create-purchase-order`
- `purchasing/receive-purchase-order`
- `purchasing/cancel-purchase-order`

Recommended V1 RPCs:

- `create_purchase_order(p JSONB)`
- `receive_purchase_transaction(p JSONB)`
- `cancel_purchase_order(p JSONB)`

Supplier CRUD can use SDK + RLS if it remains non-critical CRUD, but any operation that affects money, inventory, or purchase order state should go through Edge Function -> SECURITY DEFINER RPC.

## V1 Scope

In scope:

- Supplier CRUD with logical deletion.
- Purchase order creation.
- Purchase order submission/sending.
- Partial and full receipts.
- Item-level unit cost and tax fields.
- Purchase receipt records.
- Inventory lot creation through existing inventory RPC.
- Purchase order cancellation before receipt, and closure of partially received POs without reversing inventory.

Deferred:

- Receipt cancellation with inventory reversal.
- Supplier performance analytics.
- Automatic purchase suggestions.
- Supplier catalogs and supplier-specific price lists.
- CFDI/electronic invoicing.
- Multi-currency purchasing.
- Purchase returns to supplier.

## Migration

Next migration should be:

```text
00006_purchasing_domain.sql
```

It depends on existing companies, branches, product variants, and inventory RPCs. Existing migrations should not be modified.

## Risks

| Risk | Severity | Mitigation |
|------|----------|------------|
| `received_qty` drift | High | Block direct authenticated updates; mutate only inside SECURITY DEFINER RPCs. |
| Cross-tenant FK mistakes | High | Use composite FKs with `(company_id, id)` patterns from catalog/inventory. |
| Multi-item receipt partial failure | High | Use one master RPC transaction; do not loop from Edge Function. |
| Receipt cancellation complexity | Medium | Defer receipt cancellation/inventory reversal from V1. |
| Missing `last_cost` on variants | Medium | Decide whether to add `product_variants.last_cost` in `00006`. |

## Open Questions For Proposal

1. Should `product_variants.last_cost` be added in `00006` and updated on receipt?
2. Should supplier CRUD be direct SDK + RLS, or should supplier mutations also get Edge Functions for consistency?
3. Should `payment_method` be a simple text field on `purchase_orders` for V1?
4. Should `cancel_purchase_order` support partially received POs by closing the PO only, without reversing receipts?

## Recommendation

Proceed to proposal for `purchasing-domain`. The first slice should define the V1 purchasing boundary: suppliers, purchase orders, partial/full receipts, and transactional inventory integration through `receive_purchase_transaction` calling `receive_purchase_lot`.
