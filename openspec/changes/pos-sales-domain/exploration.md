# POS Sales Domain Exploration

## Executive Summary

The POS sales domain should add the transactional sales core: sale headers, sale items, exact lot consumption, payments, and discount authorizations. Sales are critical operations because they touch money and inventory, so V1 mutations must use Edge Functions -> SECURITY DEFINER RPCs. The main architectural risk is that the roadmap places POS sales before cash sessions, while the planning documents require an open cash session before selling.

## Recommended V1 Entities

| Table | Purpose |
|-------|---------|
| `sales` | Sale header: company, branch, cashier/user, optional customer, optional preorder, totals, status, receipt/sale number, optional future cash session link. |
| `sale_items` | Sold product variants with quantity, unit price, discounts, taxes, and line totals. |
| `sale_item_batches` | Exact inventory lots consumed per sale item; required for FEFO traceability and future returns. |
| `payments` | One or more payment rows per sale: cash, card, transfer, credit, mixed payments. |
| `discount_authorizations` | Records manager/admin authorization for discounts. |

Out of V1:

- Separate `invoices` table / CFDI.
- Separate `tickets` table or PDF/thermal ticket generation.
- Advanced promotions.
- External payment gateway integrations.
- Partial returns and item returns.
- Customer balance ledger and abonos.

## Inventory Integration

POS sales should integrate with inventory through FEFO deduction and lot traceability.

Existing candidate RPC:

```sql
public.record_sale_deduction(p JSONB)
```

It already performs FEFO lot deduction, locks lots, writes `stock_movements`, and rejects insufficient stock atomically. POS must persist affected lots into `sale_item_batches` so cancellation/returns can trace exact lot consumption.

Important risk: current inventory sale deduction authorization appears admin-oriented, while POS is cashier-driven. The proposal must resolve whether to adapt inventory authorization, create an internal helper, or let a sales SECURITY DEFINER RPC call the existing inventory function safely.

## Customer and Preorder Integration

- `sales.customer_id` should be nullable for cash/walk-in sales.
- `customer_id` must be required if any payment method is `credit`.
- `sales.preorder_id` should be optional.
- If a sale fulfills a preorder, the sale transaction should update preorder status in the same critical flow to prevent drift.

## Critical Mutation Boundary

The following operations must be Edge Function -> SECURITY DEFINER RPC:

- `create-sale`
- `cancel-sale`
- `authorize-discount`
- Future preorder-to-sale conversion if separate
- Future void/reverse payment operation

Direct SDK writes to `sales`, `sale_items`, `payments`, or `sale_item_batches` should not be allowed for authenticated users.

## Cash Session Dependency

Planning documents state that cashiers must open cash before selling and sales must be linked to a cash session. But the roadmap places `pos-sales-domain` before `cash-session-domain`.

Options:

1. Pull `cash-session-domain` forward and implement it before POS sales.
2. Coordinate POS sales and cash sessions as a tightly coupled combined change.
3. Build POS sales V1 with a nullable/deferred `cash_session_id`, accepting an incomplete workflow.

Recommendation: Pull `cash-session-domain` forward before POS sales. This avoids implementing a sales flow that violates the operating rule "cash must be open before selling".

## Credit Dependency

Sales should allow a `payments.method = 'credit'` row, with `customer_id` required, but defer customer balances, abonos, and account statements to `credit-payments-domain`. Future balances should be derivable from `sales` + `payments`.

## Migration

If POS sales proceeds next, use:

```text
00008_pos_sales_domain.sql
```

If cash-session is pulled forward first, then cash-session likely becomes `00008_cash_session_domain.sql` and POS sales becomes `00009_pos_sales_domain.sql`.

## Recommendation

Before writing the POS sales proposal, decide the cash-session dependency strategy. The safest architecture is to pull cash sessions forward, then implement POS sales on top of an existing `cash_sessions` table and active-session invariant.
