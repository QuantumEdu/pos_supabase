# Design: Inventory Domain Implementation

## Technical Approach

Two-table core (`stock_lots` + `stock_movements`, no `stock_reservations` in V1) backed by SECURITY DEFINER RPCs invoked exclusively by Edge Functions following the catalog 8-step pattern. All mutations are atomic within RPC transactions; `remaining_qty` on `stock_lots` is a denormalized cache updated in the same transaction as movement insertion. Adjustments target total inventory per (variant, branch) — the RPC auto-resolves lots via FEFO for decreases and creates adjustment lots for increases. A `reconcile_inventory` RPC drift-checks `remaining_qty` against movement sums.

## Architecture Decisions

| Decision | Choice | Alternatives | Rationale |
|----------|--------|-------------|-----------|
| `stock_reservations` in V1 | Defer to V1.5 (customers domain) | Include now | Reservations depend on layaway/preorder (downstream domain). V1 `v_stock_available` returns `physical_qty` only; committed split added later. Spec RI10 confirms exclusion. |
| Movement type enforcement | TEXT CHECK constraint | PostgreSQL ENUM | Matches catalog pattern (TEXT CHECK). Consistent with codebase; adding types is ALTER TABLE vs. ALTER TYPE. |
| Transfer types | Enum stubs only, RPC rejects | Remove entirely | Stubs document the planned type space. RPC validation explicitly rejects `transfer_in`/`transfer_out` in V1. |
| Adjustment lot strategy | Auto-create `ADJ-{branch_short}-{YYYYMMDD}-{seq}` lot | NULL `lot_id` on adjustment movements | Guarantees every movement links to a lot (full FEFO traceability). Adjustment decreases resolve lots via FEFO as usual. |
| `remaining_qty` consistency | Atomic cache + reconciliation RPC | Trigger-computed from movements | Avoids per-INSERT trigger overhead on high-frequency sales. Reconciliation RPC compares SUM(movements) to `remaining_qty` and reports drift. |
| FEFO concurrency | `SELECT FOR UPDATE` per lot in `record_sale_deduction` | Advisory locks | Row-level locks are simpler, match `set_variant_price` pattern, and prevent `remaining_qty` from going negative. |
| `lot_code` auto-generation | Nullable; RPC generates `LOT-{branch_short}-{YYYYMMDD}-{seq}` when null | Always required | Matches SKU auto-gen pattern. User can supply supplier lot code; system fills in when absent. |
| `v_stock_available` in V1 | `physical_qty` only (no committed column) | Include `committed_qty` | No reservation table in V1, so committed is always 0. View simplified; `committed_qty` column added in V1.5. |

## Data Flow

```
Client (admin) ──POST──→ EF (8-step auth) ──→ RPC(JSONB) ──→ BEGIN
  │                                                    │
  │  receive-purchase                                  ├─ INSERT stock_lots
  │                                                    ├─ INSERT stock_movements
  │                                                    ├─ SET remaining_qty
  │                                                    └─ COMMIT → EFResult<T>
  │
  │  record-sale-deduction                            ├─ SELECT FOR UPDATE … ORDER BY expiration_date
  │                                                    ├─ LOOP: deduct lots, INSERT movements
  │                                                    └─ COMMIT
  │
  │  adjust-stock (increase)                           ├─ INSERT stock_lots (ADJ-…)
  │                                                    ├─ INSERT stock_movements
  │                                                    └─ COMMIT
  │
  │  adjust-stock (decrease)                           ├─ SELECT FOR UPDATE … FEFO
  │                                                    ├─ LOOP: deduct lots, INSERT movements
  │                                                    └─ COMMIT
  │
  SDK+RLS ──→ v_stock_available (read) ──→ physical_qty per (variant, branch)
  SDK+RLS ──→ v_stock_expiring  (read) ──→ lots ordered by expiration_date ASC
```

## File Changes

| File | Action | Description |
|------|--------|-------------|
| `supabase/migrations/00005_inventory_domain.sql` | Create | Tables (stock_lots, stock_movements), indexes, composite FKs, CHECK constraints, triggers, views (v_stock_available, v_stock_expiring), RLS policies, GRANTs, RPCs, append-only trigger |
| `supabase/functions/inventory/receive-purchase/index.ts` | Create | EF for receive_purchase_lot |
| `supabase/functions/inventory/record-sale-deduction/index.ts` | Create | EF for record_sale_deduction |
| `supabase/functions/inventory/record-sale-return/index.ts` | Create | EF for record_sale_return |
| `supabase/functions/inventory/adjust-stock/index.ts` | Create | EF for adjust_inventory |
| `supabase/functions/inventory/record-waste/index.ts` | Create | EF for record_waste |
| `supabase/functions/inventory/record-expiration/index.ts` | Create | EF for record_expiration |
| `supabase/functions/inventory/reserve-stock/index.ts` | Create | EF stub — returns V1.5 NOT_SUPPORTED |
| `supabase/functions/inventory/release-reservation/index.ts` | Create | EF stub — returns V1.5 NOT_SUPPORTED |
| `supabase/functions/_shared/inventory_schemas.ts` | Create | Zod schemas for 8 inventory EFs |
| `supabase/functions/_shared/inventory_handler.ts` | Create | Shared handler (catalog_handler pattern) for inventory RPCs |
| `supabase/tests/test_inventory_constraints.sql` | Create | pgTAP: CHECK constraints, unique lot_code, append-only, non-negative remaining_qty |
| `supabase/tests/test_inventory_rls.sql` | Create | pgTAP: company isolation, admin vs cashier, service_role bypass |
| `supabase/tests/test_inventory_rpcs.sql` | Create | pgTAP: all 6 V1 RPCs + reconcile + FEFO multi-lot + concurrency |
| `supabase/functions/_test/inventory_receive_purchase.test.ts` | Create | Deno.test: Zod schema + EFResult shape |
| `supabase/functions/_test/inventory_sale_deduction.test.ts` | Create | Deno.test: Zod schema + EFResult shape |
| `supabase/functions/_test/inventory_adjust_stock.test.ts` | Create | Deno.test: Zod schema + EFResult shape |

## Interfaces / Contracts

### RPC Signatures

```sql
-- V1 RPCs (6 functional + 1 reconciliation)
receive_purchase_lot(p JSONB)     → JSONB  -- lot_id, lot_code, movement_id
record_sale_deduction(p JSONB)   → JSONB  -- movement_ids[], lots affected
record_sale_return(p JSONB)      → JSONB  -- movement_id
adjust_inventory(p JSONB)        → JSONB  -- lot_id (if created), movement_id
record_waste(p JSONB)            → JSONB  -- movement_id
record_expiration(p JSONB)        → JSONB  -- movement_ids[], lots expired
reconcile_inventory(p JSONB)     → JSONB  -- drift report: variant, branch, expected, actual

-- V1.5 stubs (RPC validation rejects)
-- reserve_stock, release_reservation
```

### Key RPC Parameters

```
receive_purchase_lot:  company_id, branch_id, variant_id, qty, lot_code?, expiration_date?, cost_per_unit?, notes?
record_sale_deduction: company_id, branch_id, variant_id, qty, reference_type?, reference_id?, notes?
record_sale_return:    company_id, branch_id, variant_id, lot_id, qty, reference_type?, reference_id?, notes?
adjust_inventory:      company_id, branch_id, variant_id, qty (signed: +increase/-decrease), reason, lot_id?, lot_code?, notes?
record_waste:          company_id, branch_id, variant_id, lot_id, qty, reason, notes?
record_expiration:     company_id, branch_id, variant_id, lot_id?, notes?
```

### v_stock_available (V1)

```sql
CREATE VIEW v_stock_available AS
SELECT company_id, branch_id, variant_id,
       SUM(remaining_qty) AS physical_qty
FROM stock_lots
WHERE is_active = TRUE AND status = 'active'
GROUP BY company_id, branch_id, variant_id;
```

## Testing Strategy

| Layer | What to Test | Approach |
|-------|-------------|----------|
| pgTAP constraints | CHECK on movement_type, non-negative remaining_qty, received_qty ≥ 0, unique lot_code, append-only trigger on stock_movements | `supabase test db` |
| pgTAP RLS | Company isolation, admin INSERT/UPDATE, cashier SELECT-only, service_role bypass, no DELETE policy | `supabase test db` |
| pgTAP RPCs | 6 V1 RPCs: company verification, FEFO multi-lot deduction, adjustment lot creation, concurrency (SELECT FOR UPDATE), transfer type rejection, reconcile_inventory drift detection | `supabase test db` |
| Deno.test | Zod schema validation (required/optional fields), EFResult shape, auth enforcement (admin/cashier/unauthenticated) | `deno test` |

## Migration / Rollout

Single migration `00005_inventory_domain.sql` applied via `supabase db push`. No catalog schema changes — inventory only references existing tables via composite FKs. Rollback: `supabase db reset` to pre-inventory state. No downstream domains depend on inventory yet (R10 ordering).

## Open Questions

- [ ] Should `cost_per_unit` default to `0` or remain NULL for lots received without a cost? (Currently NULL per spec; affects future COGS aggregation)
- [ ] Reconciliation RPC: should it auto-fix drift or only report? (Recommendation: report only in V1)
- [ ] `v_stock_expiring`: filter by days-until-expiration parameter, or return all active lots sorted? (Recommendation: return all, let FE filter)