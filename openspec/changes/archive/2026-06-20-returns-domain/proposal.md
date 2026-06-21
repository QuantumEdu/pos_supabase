# Proposal: Returns Domain

## Intent

Returns are a distinct domain from cancellation. Cancellation (via `cancel_sale_transaction`) voids an entire sale; returns handle **partial item-level reversals** with destination routing — inventory restock, waste, warranty, or disposal. Without this domain, partial returns require ad-hoc workarounds that break inventory traceability and cash audit Trails.

## Scope

### In Scope
- `returns`, `return_items`, `return_item_batches` tables (migration 00011)
- `return_sale_item_transaction()` RPC — orchestrates inventory reversal + cash movement
- `return-sale-item` Edge Function (admin-only, 8-step pattern)
- Return types: total, partial
- Destinations: inventario (restock via `adjust_inventory_stock`), merma, garantía, desecho (single negative `stock_movements` with new movement types)
- Cash reversal via `cash_movements.movement_type = 'sale_return_refund'`
- CHECK constraint extensions on `stock_movements` (00005) and `cash_movements` (00008)
- pgTAP + Deno tests

### Out of Scope
- Credit balance reduction on partial credit returns (V1.5)
- Mixed-payment proportional refund logic
- Multi-step approval workflow
- Customer-facing return API (admin-only in V1)

## Capabilities

### New Capabilities
- `returns-domain`: tables, RPC, EF, and RLS for sale item returns with destination routing

### Modified Capabilities
- `inventory-domain`: extending `stock_movements.movement_type` CHECK with `waste_return`, `warranty_return`, `disposal_return`
- `cash-session-domain`: extending `cash_movements.movement_type` CHECK with `sale_return_refund`

## Approach

Returns domain owns its tables end-to-end. Inventory reversal for `inventario` destinations delegates to `adjust_inventory_stock()` (00009) — single positive movement per lot. Non-inventario destinations use single negative `stock_movements` rows via a new internal helper, bypassing the adjustment RPC since no lot restocking occurs. Cash reversal inserts a `sale_return_refund` row into `cash_movements` (append-only, same session audit pattern as sales). The `return_sale_item_transaction()` RPC wraps all sub-operations atomically. The Edge Function follows the standard 8-step validation pattern (admin-only).

## Affected Areas

| Area | Impact | Description |
|------|--------|-------------|
| `supabase/migrations/00011_returns_domain.sql` | New | Tables, RPC, RLS policies, CHECK extensions |
| `supabase/functions/return-sale-item/` | New | Edge Function (8-step, admin-only) |
| `stock_movements` (00005) | Modified | Adding 3 movement types to CHECK constraint |
| `cash_movements` (00008) | Modified | Adding `sale_return_refund` to CHECK constraint |

## Risks

| Risk | Likelihood | Mitigation |
|------|------------|------------|
| CHECK constraint ALTER on existing tables blocks concurrent writes | Low | Additive only; no existing values removed |
| Credit balance not reduced on credit-paid partial returns | Med | Document in V1.5 scope; return creates cash movement only |
| `sale_item_batches` lot lookup fails for old sales | Low | RPC validates lot existence before reversal |

## Rollback Plan

Migration 00011 is reversible: `DROP FUNCTION return_sale_item_transaction; DROP TABLE return_item_batches, return_items, returns;` and revert CHECK extensions. No data loss since returns are new.

## Dependencies

- pos-sales (sale_item_batches, cancel_sale_transaction) ✅
- inventory (adjust_inventory_stock, stock_movements) ✅
- cash-session (cash_movements append-only pattern) ✅

## Success Criteria

- [ ] Admin can create total or partial return with destination routing via EF
- [ ] Inventario destinations restock correct lots via `adjust_inventory_stock`
- [ ] Non-inventario destinations create single negative `stock_movements` row
- [ ] Cash reversal creates `sale_return_refund` movement in open cash session
- [ ] RLS restricts all mutations to admin role; reads scoped to company/branch
- [ ] pgTAP: RLS isolation, CHECK constraints, RPC atomicity, rollback on failure
- [ ] Deno.test: EF auth validation, Zod schema, full 8-step flow