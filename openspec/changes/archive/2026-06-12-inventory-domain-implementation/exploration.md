# Exploration: inventory-domain-implementation

## Current State

The project has a completed and archived **catalog domain** (RC1–RC20) providing brands, categories, units, products, product_variants, and product_prices with full RLS, RPCs, and Edge Functions. The **project-architecture spec** (R1–R11) establishes foundational constraints: Supabase-only runtime, Edge Functions for critical ops, RLS-first multi-tenancy, inventory movement integrity (R4), traceability with logical deletion (R5), and transactional consistency (R6). The chained delivery roadmap (R10) positions inventory domain as change #4, directly after catalog domain.

No inventory tables, RPCs, or EFs exist yet. The migration sequence is: `00001_companies_branches_profiles.sql` → `00002_rls_helpers.sql` → `00003_rls_policies.sql` → `00004_catalog_domain.sql`. The next migration will be `00005_inventory_domain.sql`.

The **constitution** (Principles §1–2, §18–19) and **spec.md** (§14–19) define the inventory domain requirements:
- Inventory is the source of truth (§1): stock is NEVER edited directly; all changes via movements
- Physical vs. available stock (§2): available = physical − committed
- FEFO strategy (§19): sell lots closest to expiration first
- Lots/Lots (§15): each reception creates a lot with batch number, reception date, expiration date, quantity, cost
- Movements (§18): purchase, sale, adjustment, waste, expiration, return, transfer (V1.5)
- Adjustments (§19): never modify stock directly; require reason, user, date, comment

The **architecture spec** R4 explicitly states: "Stock quantities MUST NEVER be edited directly. All changes via movements (purchases, receipts, sales, returns, adjustments, waste, expirations, transfers)."

### Existing Tables/Resources the Inventory Domain Will Reference

| Table | How Inventory References It |
|-------|------------------------------|
| `companies` | `company_id` on all inventory tables |
| `branches` | `branch_id` on branch-scoped tables (stock, movements) |
| `product_variants` | `variant_id` on stock_lots and stock_movements |
| `units` | `unit_id` on stock_lots (package size) |
| RLS helpers | `get_company_id()`, `is_admin()`, `is_cashier()`, `get_user_branch_id()` |
| Catalog RPCs | Not directly called; inventory is a separate domain |

### Established Patterns to Follow

1. **Migration pattern**: Sequential numbering (`00005_inventory_domain.sql`), with source annotations
2. **RLS pattern**: `company_id = get_company_id()` for SELECT; admin-only for INSERT/UPDATE; service_role ALL bypass; no DELETE policies
3. **RPC pattern**: JSONB `p` parameter, SECURITY DEFINER, `SET search_path = public`, independent company_id+role verification, REVOKE ALL FROM PUBLIC+anon, GRANT EXECUTE TO authenticated
4. **EF pattern**: 8-step (CORS → auth → company → role → input → RPC → audit → return), Zod schemas, `EFResult<T>`, separate EF per critical operation
5. **Composite FK pattern**: `(company_id, fk_id)` references `(company_id, id)` on parent table for cross-tenant integrity
6. **Audit columns**: `created_at`, `updated_at`, `created_by`, `updated_by` + `is_active`, `deleted_at`, `deleted_by`
7. **Test pattern**: pgTAP for SQL/RLS, `Deno.test` for EF schemas/auth

---

## Affected Areas

- `supabase/migrations/00005_inventory_domain.sql` — new migration: tables, triggers, RLS, RPCs
- `supabase/migrations/` — potential RLS helper additions if needed (e.g., inventory-specific helpers)
- `supabase/functions/inventory/` — new Edge Functions (one per critical operation)
- `supabase/functions/_shared/inventory_schemas.ts` — Zod schemas
- `supabase/functions/_shared/inventory_handler.ts` — shared handler (optional, learned from catalog warning)
- `supabase/tests/test_inventory_constraints.sql` — pgTAP constraint tests
- `supabase/tests/test_inventory_rls.sql` — pgTAP RLS tests
- `supabase/tests/test_inventory_rpcs.sql` — pgTAP RPC tests
- `openspec/specs/inventory-domain/spec.md` — inventory domain spec (delta, to be merged later)
- `openspec/specs/project-architecture/spec.md` — may need R4 elaboration updates

---

## Approaches

### Approach A: Unified Stock Lots + Movements (Recommended)

**Description**: Two core tables: `stock_lots` (batch/lot tracking with expiration) and `stock_movements` (immutable audit log of all stock changes). A computed view or materialized calculation derives current physical and available quantities. Branch-scoped, company-isolated. All mutations atomic via RPC.

**Tables**:
- `stock_lots` — one row per received batch: variant, branch, lot_code, expiration_date, received_qty, remaining_qty, cost_per_unit, supplier reference, status
- `stock_movements` — one row per stock change: movement_type enum, lot_id (nullable), variant_id, branch_id, delta_qty, reference_type, reference_id, reason, notes, created_by
- `stock_reservations` — committed but not yet fulfilled quantities (preorders, layaways)
- Computed view: `v_stock_available` = SUM(lot.remaining_qty) − SUM(reservation.reserved_qty) per (variant, branch)

**Movement types**: `purchase_receipt`, `sale`, `sale_return`, `adjustment_increase`, `adjustment_decrease`, `waste`, `expiration`, `transfer_in`, `transfer_out` (transfer_* for V1.5 stub)

**Pros**:
- Strict R4 compliance: stock changes ONLY through movements
- FEFO-queryable: `stock_lots` ordered by `expiration_date ASC` directly supports FEFO
- Immutable audit trail: `stock_movements` is append-only, never updated or deleted
- Mimics existing `product_prices` temporal pattern (lot has lifecycle)
- Clean separation: lots = "what we have", movements = "what happened", reservations = "what's promised"
- Supports constitution §1 (inventory = source of truth) and §2 (physical vs available)
- Natural `branch_id` scoping aligns with spec §6 (each branch has own inventory)

**Cons**:
- More complex: 3–4 tables vs. 2
- `remaining_qty` on `stock_lots` must be kept in sync with movements (denormalization risk)
- Transfer stubs need careful design even if not V1-functional

**Effort**: Medium-High

### Approach B: Movement-Only with Derived Stock

**Description**: Single `stock_movements` table with running balance. No `stock_lots` table — lot info is inferred from movements. Current stock is `SUM(delta_qty)` per (variant, branch).

**Pros**:
- Maximum simplicity: one mutation table
- No denormalization
- Purely additive

**Cons**:
- Hard to implement FEFO: no dedicated lot/batch tracking means you can't determine WHICH lot to sell from without complex window functions
- No expiration date tracking per batch — unconstitutional (spec §15, §16, §19 all require per-lot expiration)
- Gets unwieldy for "products near expiration" queries
- Doesn't support cost-per-unit per lot (needed for weighted average cost)
- Fails constitution §15 (lots) and §19 (FEFO) requirements

**Effort**: Low (but misses core requirements)

### Approach C: Stock Quantities Table + Movements

**Description**: `stock_quantities` (variant, branch, physical_qty, committed_qty) + `stock_movements` for audit. No lot tracking.

**Pros**:
- Simpler queries for "how many in stock?"
- Easy available = physical − committed

**Cons**:
- Fails R4: if `physical_qty` is directly editable (even through RPC), it's a direct quantity update, not a movement-driven change. Would need to be derived.
- No FEFO support without lots
- No per-lot cost tracking
- Constitution §1 (inventory = source of truth) requires movements to EXPLAIN quantities, not just adjust counters

**Effort**: Low (but misses core requirements)

---

## Recommendation

**Approach A: Unified Stock Lots + Movements** is the only approach that satisfies all constitutional requirements (§1, §2, §15, §16, §18, §19) and architecture spec R4. The `stock_lots` table is essential for FEFO, expiration alerts, per-lot costing, and lot traceability. The `stock_movements` table ensures no stock changes without audit trail. `stock_reservations` supports available-vs-physical distinction (§2).

For `remaining_qty` consistency, the recommended pattern is:
- `stock_movements` is the source of truth for all changes
- `stock_lots.remaining_qty` is a denormalized cache updated atomically within the same RPC transaction as the movement insertion
- An integrity check trigger or periodic reconciliation can verify `remaining_qty = SUM(movements where lot_id = X and type IN ('purchase_receipt')) − SUM(movements where lot_id = X and type IN ('sale', 'waste', 'expiration'))`

Transfer stubs (`transfer_in`, `transfer_out`) should be defined as movement types in the enum but NOT have RPC/EF implementations in V1 — only the type enum value exists, with a clear V1.5 migration path.

---

## Entity Design

### stock_lots

| Column | Type | Constraints | Notes |
|--------|------|------------|-------|
| `id` | UUID PK | DEFAULT gen_random_uuid() | |
| `company_id` | UUID NOT NULL | FK (company_id, id) → companies | Tenant isolation |
| `branch_id` | UUID NOT NULL | FK (company_id, id) → branches | Branch-scoped |
| `variant_id` | UUID NOT NULL | FK (company_id, id) → product_variants | Product reference |
| `lot_code` | TEXT | | Supplier batch/lot code |
| `expiration_date` | DATE | NULLABLE | NULL for non-expiring products |
| `received_qty` | INTEGER NOT NULL | DEFAULT 0 | Total quantity received into this lot |
| `remaining_qty` | INTEGER NOT NULL | DEFAULT 0 | Current available from this lot (denormalized cache) |
| `cost_per_unit` | NUMERIC(12,2) | NULLABLE | Purchase cost per unit in this lot |
| `status` | TEXT NOT NULL | CHECK IN ('active','expired','depleted') | Lot lifecycle |
| `received_at` | TIMESTAMPTZ | DEFAULT now() | When the lot was received |
| `is_active` | BOOLEAN | DEFAULT TRUE | Logical deletion |
| `created_at` | TIMESTAMPTZ | DEFAULT now() | Audit |
| `updated_at` | TIMESTAMPTZ | DEFAULT now() | Audit |
| `created_by` | UUID | | Audit |
| `updated_by` | UUID | | Audit |
| `deleted_at` | TIMESTAMPTZ | | Logical deletion |
| `deleted_by` | UUID | | Logical deletion |

Indexes: `(company_id, branch_id)`, `(company_id, variant_id)`, `(variant_id, expiration_date)` for FEFO, `(company_id, status)`.

Unique constraint: `(company_id, branch_id, variant_id, lot_code)` — same lot code can't exist twice for same variant+branch within a company.

### stock_movements

| Column | Type | Constraints | Notes |
|--------|------|------------|-------|
| `id` | UUID PK | DEFAULT gen_random_uuid() | |
| `company_id` | UUID NOT NULL | FK → companies | Tenant isolation |
| `branch_id` | UUID NOT NULL | FK (company_id, id) → branches | Branch-scoped |
| `variant_id` | UUID NOT NULL | FK (company_id, id) → product_variants | Product reference |
| `lot_id` | UUID | NULLABLE FK (company_id, id) → stock_lots | NULL for adjustments without lot |
| `movement_type` | TEXT NOT NULL | CHECK IN ('purchase_receipt','sale','sale_return','adjustment_increase','adjustment_decrease','waste','expiration','transfer_in','transfer_out') | |
| `delta_qty` | INTEGER NOT NULL | | Positive = stock increase, Negative = stock decrease |
| `reference_type` | TEXT | NULLABLE | 'purchase_order','sale','adjustment','waste_report','expiration_report' |
| `reference_id` | UUID | NULLABLE | FK to the source document (purchase order, sale, etc.) |
| `reason` | TEXT | NULLABLE | Required for adjustments |
| `notes` | TEXT | NULLABLE | Free-text |
| `is_active` | BOOLEAN | DEFAULT TRUE | Logical deletion (for reversal records) |
| `created_at` | TIMESTAMPTZ | DEFAULT now() | Audit |
| `created_by` | UUID | NOT NULL | Who made this movement |

`stock_movements` is **append-only**: no UPDATE, no DELETE. Use reversal movements for corrections.

Indexes: `(company_id, branch_id)`, `(company_id, variant_id)`, `(company_id, lot_id)`, `(variant_id, created_at)` for history.

### stock_reservations

| Column | Type | Constraints | Notes |
|--------|------|------------|-------|
| `id` | UUID PK | DEFAULT gen_random_uuid() | |
| `company_id` | UUID NOT NULL | FK → companies | Tenant isolation |
| `branch_id` | UUID NOT NULL | FK (company_id, id) → branches | Branch-scoped |
| `variant_id` | UUID NOT NULL | FK (company_id, id) → product_variants | Product reference |
| `lot_id` | UUID | NULLABLE FK (company_id, id) → stock_lots | Specific lot reservation (FEFO) |
| `reserved_qty` | INTEGER NOT NULL | CHECK > 0 | |
| `reservation_type` | TEXT NOT NULL | CHECK IN ('layaway','preorder','backorder') | |
| `status` | TEXT NOT NULL | CHECK IN ('active','fulfilled','cancelled') | |
| `reference_type` | TEXT | NULLABLE | 'sale','preorder','layaway' |
| `reference_id` | UUID | NULLABLE | Reference to source document |
| `expires_at` | TIMESTAMPTZ | NULLABLE | Auto-release reservation after this time |
| `is_active` | BOOLEAN | DEFAULT TRUE | Logical deletion |
| `created_at` | TIMESTAMPTZ | DEFAULT now() | Audit |
| `updated_at` | TIMESTAMPTZ | DEFAULT now() | Audit |
| `created_by` | UUID | | Audit |
| `updated_by` | UUID | | Audit |
| `deleted_at` | TIMESTAMPTZ | | Logical deletion |
| `deleted_by` | UUID | | Logical deletion |

Unique constraint: None (multiple reservations per variant is normal).

Indexes: `(company_id, branch_id)`, `(company_id, variant_id)`, `(variant_id, status)`.

### v_stock_available (View)

Computed view aggregating physical stock and available quantities per (variant, branch):

```sql
SELECT
  sl.company_id,
  sl.branch_id,
  sl.variant_id,
  SUM(sl.remaining_qty) AS physical_qty,
  COALESCE(SUM(sr.reserved_qty) FILTER (WHERE sr.status = 'active'), 0) AS committed_qty,
  SUM(sl.remaining_qty) - COALESCE(SUM(sr.reserved_qty) FILTER (WHERE sr.status = 'active'), 0) AS available_qty
FROM stock_lots sl
LEFT JOIN stock_reservations sr ON sr.lot_id = sl.id AND sr.status = 'active'
WHERE sl.is_active = TRUE AND sl.status = 'active'
GROUP BY sl.company_id, sl.branch_id, sl.variant_id;
```

This satisfies constitution §2: `available = physical − committed`.

### v_stock_expiring (View)

FEFO query: lots ordered by expiration date for a given variant+branch:

```sql
SELECT *
FROM stock_lots
WHERE company_id = :company_id
  AND branch_id = :branch_id
  AND variant_id = :variant_id
  AND status = 'active'
  AND expiration_date IS NOT NULL
ORDER BY expiration_date ASC;
```

### Movement Type Semantics

| Type | `delta_qty` | `lot_id` | Triggered By |
|------|------------|----------|--------------|
| `purchase_receipt` | +N | Required | Receiving a purchase order |
| `sale` | −N | Required (FEFO-determined) | POS sale transaction |
| `sale_return` | +N | Required (original lot or new lot) | Return of sold item |
| `adjustment_increase` | +N | Optional | Manual adjustment (requires reason) |
| `adjustment_decrease` | −N | Optional | Manual adjustment (requires reason) |
| `waste` | −N | Required | Waste/spoilage report |
| `expiration` | −N | Required | Automatic expiration write-off |
| `transfer_in` | +N | (V1.5) | Inter-branch transfer receipt |
| `transfer_out` | −N | (V1.5) | Inter-branch transfer shipment |

### RLS Policies

Following catalog pattern + constitution §8, §9:

- **All inventory tables**: `company_id = get_company_id()` for SELECT
- **Admin**: full company access for INSERT/UPDATE
- **Cashier**: branch-scoped SELECT only (reads stock); CANNOT adjust, move, or receive inventory
- **service_role**: ALL bypass

Key difference from catalog: cashier CAN read inventory (needed for POS) but CANNOT mutate it. Only admin can perform inventory mutations.

### Edge Functions (Inventory)

Per R2 (EF as exclusive backend for critical ops) and RC15 precedent (separate EF per critical operation):

| EF | Auth | RPC Invoked |
|----|------|-------------|
| `inventory/receive-purchase` | admin (8-step) | `receive_purchase_lot(JSONB)` |
| `inventory/record-sale-deduction` | admin (8-step) | `record_sale_deduction(JSONB)` |
| `inventory/record-sale-return` | admin (8-step) | `record_sale_return(JSONB)` |
| `inventory/adjust-stock` | admin (8-step) | `adjust_inventory(JSONB)` |
| `inventory/record-waste` | admin (8-step) | `record_waste(JSONB)` |
| `inventory/record-expiration` | admin (8-step) | `record_expiration(JSONB)` |
| `inventory/reserve-stock` | admin (8-step) | `reserve_stock(JSONB)` |
| `inventory/release-reservation` | admin (8-step) | `release_reservation(JSONB)` |

Reads (stock levels, expiring lots, lot details): SDK + RLS (non-critical).

### Key RPCs

| RPC | Purpose |
|-----|---------|
| `receive_purchase_lot(p JSONB)` | Create lot + movement, set remaining_qty, atomically |
| `record_sale_deduction(p JSONB)` | FEFO-deduct from lots + create movement(s), atomically |
| `record_sale_return(p JSONB)` | Return to lot + create movement, atomically |
| `adjust_inventory(p JSONB)` | Adjustment movement, require reason/notes, atomically |
| `record_waste(p JSONB)` | Waste movement + lot remaining update, atomically |
| `record_expiration(p JSONB)` | Auto-expire lots past expiration + create movement |
| `reserve_stock(p JSONB)` | Create reservation for layaway/preorder |
| `release_reservation(p JSONB)` | Cancel or fulfill reservation |
| `deactivate_stock_lot(p JSONB)` | Logical deletion of lot |

---

## Risks

1. **remaining_qty denormalization**: `stock_lots.remaining_qty` is a cache derived from movements. If it drifts from actual `SUM(movements)`, data is inconsistent. Mitigation: atomic updates within RPC transactions, and an optional reconciliation RPC that recomputes from movements.

2. **FEFO atomicity across lots**: A sale may need to deduct from multiple lots to fulfill the requested quantity (e.g., 15 units: 10 from lot A, 5 from lot B). This must be done in a single transaction. The `record_sale_deduction` RPC must loop through lots in FEFO order, deducting from each, creating individual movements, all within one transaction.

3. **Concurrent sales competing for the same lot**: Two cashiers selling the same variant simultaneously could cause `remaining_qty` to go negative. Mitigation: `SELECT ... FOR UPDATE` on affected lots within the transaction, similar to `product_prices` temporal closing pattern in catalog.

4. **Transfer stubs**: Including `transfer_in`/`transfer_out` in the enum but not implementing RPCs could confuse developers. Mitigation: clear documentation in spec and migration comments that transfers are V1.5, and a CHECK constraint or RPC validation rejecting transfer types in V1.

5. **Reservation expiry**: Reservations with `expires_at` need a background process to auto-release. Supabase doesn't have cron natively. Mitigation: defer to V1.5 / pg_cron extension OR handle at read time (check `expires_at` when computing available stock).

6. **lot_code uniqueness scope**: Should uniqueness be per (company, branch, variant) or per company globally? The business case supports per-branch-per-variant (same lot received at Branch A and Branch B are separate inventory records). But a supplier lot applied to multiple variants (different product sizes) would need different lot_codes or a different approach. Mitigation: `(company_id, branch_id, variant_id, lot_code)` unique constraint; for auto-generated lot codes, the RPC generates them.

7. **Costing method**: The constitution and spec don't specify FIFO, LIFO, or weighted average for cost tracking. `cost_per_unit` on `stock_lots` implies specific identification (each lot tracks its own cost). This is consistent with FEFO but should be explicitly documented as a design decision.

8. **Adjustment movements don't always have a lot**: Inventory adjustments (count corrections) may apply to aggregate stock without a specific lot. The `lot_id` on `stock_movements` is NULLABLE for these cases, but this means the v_stock_available view needs to handle lotless movements. Mitigation: adjustment movements MUST reference a lot (force lot creation for count corrections) OR separately track lotless adjustments. Recommendation: require lot_id for adjustments to maintain full traceability — if no lot exists, the adjustment RPC creates a "count adjustment lot" first.

---

## Open Questions for Proposal

1. **Should `stock_lots.lot_code` be auto-generated if not provided?** The catalog pattern auto-generates SKU when null. Should lot codes follow the same pattern?

2. **Reservation expiry strategy**: Should we use pg_cron for auto-release, or handle at read time with a "stale reservation" check?

3. **Should adjustment movements require a `lot_id`?** If yes, what's the lifecycle of an "adjustment lot"? If no, how do we preserve FEFO traceability?

4. **What is the costing method for COGS?** Specific identification (per-lot cost) is assumed. Should this be documented as a design decision?

5. **Should `stock_reservations` be in V1 or deferred to V1.5?** Reservations support the available-vs-physical distinction (constitution §2), but layaway/preorder are downstream features (customers domain). Would a simpler `committed_qty` column on `stock_lots` suffice for V1?

6. **Should FEFO lot selection be done in the RPC or in a helper function?** The `record_sale_deduction` RPC needs to select lots in FEFO order. Should this be a reusable `get_fefo_lots()` function callable from multiple RPCs?

7. **Expiration alerts**: Architecture spec R6 mentions "products near expiration" (spec §16). Should the inventory domain include a `v_stock_expiring_soon` view or is this dashboard domain territory?

8. **Should `stock_movements` use a PostgreSQL ENUM or TEXT CHECK constraint for `movement_type`?** Catalog used TEXT CHECK; consistency suggests TEXT CHECK, but an ENUM is more type-safe and prevents typos at the DB level.

9. **V1 scope confirmation**: Are transfers (inter-branch) truly out of V1 scope? The spec's MVP exclusions (§4) say "Transferencias entre sucursales" is excluded, but the movement_type enum includes `transfer_in`/`transfer_out`. Should these be removed from V1?

10. **Should `cost_per_unit` be `NUMERIC(12,2)` or higher precision?** Some supplement products have very small margins; 4 decimal places may be needed for accurate COGS.

---

## Ready for Proposal

**Yes** — the core entities are clear, the approach is recommended (Approach A), and the open questions above need user input to finalize the spec. The exploration provides sufficient detail for the orchestrator to present to the user and start the proposal phase.

Key decisions needed from user before proposal:
1. `stock_reservations` in V1 or defer?
2. Transfer stubs in V1 enum or remove entirely?
3. Auto-generate lot_code or always require?
4. Reservation expiry strategy (pg_cron vs read-time)?