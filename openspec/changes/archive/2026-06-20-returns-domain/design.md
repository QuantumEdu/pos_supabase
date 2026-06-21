# Design: Returns Domain

## Technical Approach

Three-table header/line/batch schema with a single SECURITY DEFINER RPC that atomically orchestrates: return header creation, per-item inventory reversal (delegating to `adjust_inventory_stock` for inventario or direct `stock_movements` inserts for non-inventario destinations), and cash refund insertion. An admin-only Edge Function fronts the RPC via the standard 8-step handler pattern. CHECK constraints on `stock_movements` and `cash_movements` are extended additively. Mirrors the established migration, RPC, RLS, and EF patterns from 00005/00008/00009.

## Architecture Decisions

### Decision: D1 — Return tables (header/line/batch)

**Choice**: `returns` (header) → `return_items` (line items with destination) → `return_item_batches` (lot traceability)
**Alternatives**: Single denormalized returns table with JSONB items; flat return table with no batch tracking
**Rationale**: Mirrors `sales`/`sale_items`/`sale_item_batches` pattern exactly. Composite FKs enforce company-scoping consistency. Destination on `return_items` (not header) because a single return can route different items to different destinations.

### Decision: D2 — Inventory reversal by destination

**Choice**: `inventario` calls `adjust_inventory_stock()` (positive delta, per lot); `merma`/`garantia`/`desecho` insert direct `stock_movements` rows with negative `delta_qty` and new types, bypassing lot restock
**Alternatives**: Route all through `adjust_inventory_stock()` with negative qty for non-inventario; create separate RPC per destination
**Rationale**: `adjust_inventory_stock` always updates `stock_lots.remaining_qty` — correct for restocking, wrong for waste/warranty/disposal where the item leaves inventory permanently (no lot to restock). Direct INSERT into `stock_movements` is the established pattern for destination-specific movements (see `record_waste` in 00005). Sign constraint: waste_return/warranty_return/disposal_return are negative (item leaves stock).

### Decision: D3 — Cash reversal

**Choice**: Derive cash refund from `payments` where `payment_method='cash'`. Insert single `cash_movements` row: `movement_type='sale_return_refund'`, negative amount, linked to open cash session.
**Alternatives**: Create separate refund entries per payment method; store refund as positive amount
**Rationale**: V1 spec limits refunds to cash-only. Deriving from existing `payments` table is authoritative — no client-supplied amounts needed. `cash_movements.amount` stores the absolute refund value; the RPC computes expected_cash_amount adjustment. Must validate open session before any writes.

### Decision: D4 — RPC transaction composition

**Choice**: `return_sale_item_transaction(p JSONB)` — single SECURITY DEFINER function wrapping all sub-operations
**Alternatives**: Chained RPCs from EF; separate RPC per destination
**Rationale**: Full atomicity requires a single DB transaction. The RPC validates first (sale not cancelled, qty available, lots match, cash session open), then inserts header → items → batches → inventory reversals → cash refund. Any failure RAISEs EXCEPTION → full rollback. Follows `create_sale_transaction` pattern from 00009.

### Decision: D5 — CHECK constraint extensions

**Choice**: `ALTER TABLE ... DROP CONSTRAINT ... ADD CONSTRAINT ...` in idempotent DO blocks with `IF NOT EXISTS` guard on constraint name
**Alternatives**: ALTER TYPE (enum); raw ALTER without guard
**Rationale**: Postgres CHECK constraints cannot be ALTERed in-place — must drop and re-add. The DO block pattern ensures idempotency. New values: `stock_movements.movement_type` adds `waste_return`, `warranty_return`, `disposal_return` (all require `delta_qty < 0`); `cash_movements.movement_type` adds `sale_return_refund`. Additive only — no existing values removed.

### Decision: D6 — Edge Function

**Choice**: `return-sale-item` EF with shared handler pattern (`_shared/return_handler.ts` + `_shared/return_schemas.ts`), admin-only per 8-step pattern
**Alternatives**: Inline handler in index.ts; REST endpoint via PostgREST
**Rationale**: Follows established `_shared` handler + schema separation. Admin-only matches RR5/RR6 specs. EF derives `actor_user_id` and `company_id` from auth context — never trusts client copies.

### Decision: D7 — RLS

**Choice**: Company-scoped SELECT for authenticated (admin sees all branches, others see own branch). Admin-only INSERT via SECURITY DEFINER RPC. No DELETE policy (logical deletion only). service_role full bypass.
**Rationale**: Mirrors cash_sessions/sales RLS pattern exactly. Tables are write-once via RPC — no UPDATE policy needed on `return_items`/`return_item_batches`. `returns` header allows UPDATE for status transitions (pending→approved→completed/rejected).

## Data Flow

```
EF (return-sale-item)
  │
  │ 8-step: auth → company → admin → Zod → RPC → result
  ▼
return_sale_item_transaction(p)
  │
  ├─ Validate: sale exists, not cancelled, qty ≤ remaining, lots match
  │
  ├─ INSERT returns (header: type, status='pending', total, reason)
  │
  ├─ FOR EACH return_item:
  │   ├─ INSERT return_items (variant_id, qty, destination, unit_price, subtotal)
  │   │
  │   └─ FOR EACH return_item_batch:
  │       ├─ INSERT return_item_batches (original_batch_id, variant_id, qty)
  │       │
  │       └─ IF destination='inventario':
  │           └─ adjust_inventory_stock(+qty, 'sale_return')
  │           ELSE:
  │           └─ INSERT stock_movements (-qty, type=waste_return|warranty_return|disposal_return)
  │
  ├─ IF cash payments exist AND refund > 0:
  │   └─ INSERT cash_movements (sale_return_refund, -amount)
  │
  └─ RETURN {success, data: {return_id, ...}}
```

## File Changes

| File | Action | Description |
|------|--------|-------------|
| `supabase/migrations/00011_returns_domain.sql` | Create | Tables, composite FKs, triggers, RLS, grants, RPC, CHECK extensions |
| `supabase/functions/_shared/return_handler.ts` | Create | Shared handler: `handleReturnSaleItem` via `handleCashSessionRpc` pattern, admin-only |
| `supabase/functions/_shared/return_schemas.ts` | Create | Zod schemas: `ReturnSaleItemRequest`, `ReturnSaleItemResult` |
| `supabase/functions/return-sale-item/index.ts` | Create | Thin entry point delegating to shared handler |
| `supabase/functions/_test/return_sale_item.test.ts` | Create | pgTAP + Deno tests for EF 8-step flow |

## Interfaces / Contracts

### RPC: `return_sale_item_transaction(p JSONB) → JSONB`

```sql
-- Input (via EF from Zod-validated body + auth context)
{
  "company_id":      UUID,   -- from auth
  "branch_id":       UUID,   -- from client
  "actor_user_id":   UUID,   -- from auth
  "sale_id":         UUID,
  "type":            "total" | "partial",
  "reason":          TEXT,        -- optional
  "items": [{
    "sale_item_id":  UUID,
    "variant_id":    UUID,
    "qty":           NUMERIC(12,3),
    "destination":   "inventario" | "merma" | "garantia" | "desecho",
    "unit_price":    NUMERIC(12,2),
    "batches": [{
      "original_batch_id": UUID,
      "qty":                NUMERIC(12,3)
    }]
  }]
}

-- Output
{ "success": true, "data": { "return_id": UUID, ... } }
{ "success": false, "code": "VALIDATION_ERROR"|"FORBIDDEN"|"NOT_FOUND", "message": "..." }
```

### Zod: `ReturnSaleItemRequest`

```typescript
const ReturnSaleItemRequest = z.object({
  branch_id: z.string().uuid(),
  sale_id: z.string().uuid(),
  type: z.enum(["total", "partial"]),
  reason: z.string().trim().min(1).optional(),
  items: z.array(z.object({
    sale_item_id: z.string().uuid(),
    variant_id: z.string().uuid(),
    qty: z.number().positive(),
    destination: z.enum(["inventario", "merma", "garantia", "desecho"]),
    unit_price: z.number().nonnegative(),
    batches: z.array(z.object({
      original_batch_id: z.string().uuid(),
      qty: z.number().positive(),
    })).min(1),
  })).min(1),
});
```

### CHECK Extension Pattern (idempotent DO block)

```sql
DO $$
BEGIN
  -- Extend stock_movements.movement_type CHECK
  IF EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'stock_movements_movement_type_check'
  ) THEN
    ALTER TABLE public.stock_movements
      DROP CONSTRAINT stock_movements_movement_type_check;
  END IF;
  ALTER TABLE public.stock_movements
    ADD CONSTRAINT stock_movements_movement_type_check
    CHECK (movement_type IN (
      'purchase_receipt','sale','sale_return','adjustment_increase',
      'adjustment_decrease','waste','expiration','transfer_in','transfer_out',
      'waste_return','warranty_return','disposal_return'
    ));
  -- Extend delta_qty sign constraint similarly
  IF EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'stock_movements_delta_qty_check'
  ) THEN
    ALTER TABLE public.stock_movements
      DROP CONSTRAINT stock_movements_delta_qty_check;
  END IF;
  ALTER TABLE public.stock_movements
    ADD CONSTRAINT stock_movements_delta_qty_check
    CHECK (delta_qty <> 0 AND (
      (movement_type IN ('purchase_receipt','sale_return','adjustment_increase','waste_return','warranty_return','disposal_return','transfer_in') AND delta_qty > 0)
      OR
      (movement_type IN ('sale','adjustment_decrease','waste','expiration','transfer_out') AND delta_qty < 0)
    ));
  -- Wait — waste_return/warranty_return/disposal_return are NEGATIVE movements
  -- Items leave stock permanently, no lot restock. Fix:
  -- 'waste_return'/'warranty_return'/'disposal_return' → delta_qty < 0
  -- 'sale_return' (inventario restock via adjust) → delta_qty > 0
END;
$$;
```

**Correction**: Non-inventario destinations produce negative `delta_qty` (item exits inventory). The sign constraint must place them in the negative group:

```sql
CHECK (delta_qty <> 0 AND (
  (movement_type IN ('purchase_receipt','sale_return','adjustment_increase','transfer_in') AND delta_qty > 0)
  OR
  (movement_type IN ('sale','adjustment_decrease','waste','expiration','transfer_out','waste_return','warranty_return','disposal_return') AND delta_qty < 0)
))
```

### Cash movements CHECK extension

```sql
-- cash_movements: add 'sale_return_refund'
ALTER TABLE public.cash_movements
  DROP CONSTRAINT cash_movements_movement_type_check;
ALTER TABLE public.cash_movements
  ADD CONSTRAINT cash_movements_movement_type_check
  CHECK (movement_type IN ('opening_float','manual_cash_in','manual_cash_out','sale_return_refund'));
-- Amount constraint: sale_return_refund follows same rules as manual_cash_out (positive amount, interpreted as outflow)
```

## Testing Strategy

| Layer | What to Test | Approach |
|-------|-------------|----------|
| pgTAP — Schema | returns/return_items/return_item_batches columns, CHECKs, composite FKs, unique constraints | `supabase test db` migration tests |
| pgTAP — RPC | Atomicity: rollback on invalid qty, cancelled sale, wrong lot | Multiple `throws_ok` / `lives_ok` scenarios |
| pgTAP — Routing | inventario → adjust_inventory_stock called; merma → single negative stock_movements | Query `stock_movements` after RPC call |
| pgTAP — Cash | Cash refund creates sale_return_refund; credit-only sale → no cash_movement; no open session → rejected | Assert `cash_movements` rows |
| pgTAP — RLS | Admin INSERT OK, non-admin rejected, company-scoped SELECT, no DELETE | `SET ROLE` + `SELECT`/`INSERT` attempts |
| Deno.test — EF | Auth validation, Zod parse, admin-only rejection, RPC invocation, EFResult shape | Mock service client, verify 8-step flow |

## Migration / Rollout

Migration 00011 is reversible: `DROP FUNCTION return_sale_item_transaction; DROP TABLE return_item_batches, return_items, returns;` plus reverting CHECK extensions (re-add original constraints). No data loss since returns are new tables. Apply in single transaction; CHECK extensions are additive and don't block concurrent writes.

## Open Questions

- [ ] Should `returns.status` support `pending→approved→completed` workflow in SQL (trigger-enforced transitions) or leave status updates to application logic in V1?