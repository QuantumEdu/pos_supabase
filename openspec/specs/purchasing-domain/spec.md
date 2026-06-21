# Purchasing Domain Specification

## Purpose

Multi-tenant purchasing workflow for SaaS POS: supplier master data, purchase orders with lifecycle state machine, partial and full purchase receipts, and atomic receipt-to-inventory integration via a master RPC that calls the existing inventory `receive_purchase_lot` without modifying it.

## Requirements

### RP1: Supplier Master Data

<!-- source: proposal.md §suppliers, §Security/RLS Approach; exploration.md §suppliers -->
Supplier master data MUST be company-scoped with logical deletion. The `suppliers` table MUST include `id` (UUID PK, `gen_random_uuid()`), `company_id` (FK → `companies(id)`), `name` (TEXT NOT NULL), `slug` (TEXT NOT NULL, unique per company via `(company_id, slug)`), optional `tax_id`, `contact_name`, `phone`, `email`, `address`, `notes`, `is_active` (BOOLEAN DEFAULT TRUE), and audit columns (`created_at`, `updated_at`, `created_by`, `updated_by`, `deleted_at`, `deleted_by`). Physical deletion PROHIBITED.

- **GIVEN** admin for company A → **WHEN** creating supplier "ACME Corp" with slug "acme-corp" → **THEN** supplier created with `company_id = A`, `is_active = true`, and audit columns populated
- **GIVEN** supplier "ACME Corp" with slug "acme-corp" exists for company A → **WHEN** creating duplicate slug "acme-corp" for same company → **THEN** rejected with unique constraint violation
- **GIVEN** supplier "ACME Corp" exists → **WHEN** admin deactivates → **THEN** `is_active = false`, `deleted_at` and `deleted_by` set; row preserved (no physical deletion)
- **GIVEN** supplier "ACME Corp" deactivated → **WHEN** creating new supplier with same slug → **THEN** allowed (unique constraint on active-only rows deferred — deactivated row does not block new)
- **GIVEN** supplier created with OPTIONAL `tax_id`, `contact_name`, `phone`, `email`, `address`, `notes` NULL → **THEN** record created successfully with NULL optional fields

Composite unique constraints: `(company_id, id)`, `(company_id, slug)`. Composite FK: `(company_id, id)` self-referential for cross-tenant safety. Supplier CRUD reads MAY use SDK + RLS; mutations SHOULD go through EF → RPC for audit trail consistency with catalog/inventory patterns.

### RP2: Purchase Order Lifecycle

<!-- source: proposal.md §purchase_orders, §PO Status Lifecycle, §Acceptance Criteria; exploration.md §Workflow -->
Purchase orders MUST follow a state machine: `draft` → `sent` → `partial` → `received`. Cancellation MAY transition `draft`, `sent`, or `partial` to `cancelled`. `received` → `cancelled` is PROHIBITED. The `purchase_orders` table MUST include `id` (UUID PK), `company_id`, `branch_id`, `supplier_id`, `order_number` (TEXT NOT NULL, unique per company), `status` (TEXT NOT NULL DEFAULT 'draft'), `order_date` (DATE NOT NULL DEFAULT CURRENT_DATE), optional `expected_date`, `payment_method` (TEXT), `subtotal`, `tax_total`, `total` (all NUMERIC(12,2) NOT NULL DEFAULT 0), `notes` (TEXT), `is_active` (BOOLEAN DEFAULT TRUE), and audit columns. Physical deletion PROHIBITED. Composite unique: `(company_id, id)`, `(company_id, order_number)`. Composite FKs: `(company_id, branch_id)` → `branches(company_id, id)`, `(company_id, supplier_id)` → `suppliers(company_id, id)`.

- **GIVEN** admin → **WHEN** calling `create_purchase_order` RPC with supplier, branch, and items → **THEN** PO header created with `status = 'draft'`, `order_number` auto-generated and unique per company, and all items inserted atomically
- **GIVEN** PO in `draft` → **WHEN** admin submits/calls a dedicated transition (or implicit via first receipt) → **THEN** status MAY transition to `sent`
- **GIVEN** PO in `sent` → **WHEN** first receipt processed via `receive_purchase_transaction` → **THEN** status transitions to `partial` (if not all items fully received)
- **GIVEN** PO in `partial` → **WHEN** `receive_purchase_transaction` receives remaining quantities and all items reach `received_qty = ordered_qty` → **THEN** status transitions to `received`
- **GIVEN** PO in `received` → **WHEN** `cancel_purchase_order` called → **THEN** rejected (all merchandise already received; cannot cancel)
- **GIVEN** PO in `draft`, `sent`, or `partial` → **WHEN** `cancel_purchase_order` called → **THEN** status transitions to `cancelled`
- **GIVEN** PO in `cancelled` → **WHEN** `receive_purchase_transaction` called → **THEN** rejected (cancelled POs cannot receive merchandise)

PO totals (`subtotal`, `tax_total`, `total`) MUST be computed server-side inside the creation RPC from item data; client-supplied final values MUST be ignored or rejected.

### RP3: Purchase Order Items

<!-- source: proposal.md §purchase_order_items; exploration.md §purchase_order_items -->
Each purchase order item MUST reference a product variant via composite FK `(company_id, variant_id)` → `product_variants(company_id, id)` and its parent PO via composite FK `(company_id, purchase_order_id)` → `purchase_orders(company_id, id)`. Columns: `id` (UUID PK), `company_id`, `purchase_order_id`, `variant_id`, `ordered_qty` (NUMERIC(14,3) NOT NULL), `received_qty` (NUMERIC(14,3) NOT NULL DEFAULT 0), `unit_cost` (NUMERIC(12,2) NOT NULL), `tax_rate` (NUMERIC(6,4) NOT NULL DEFAULT 0), `tax_amount` (NUMERIC(12,2) NOT NULL DEFAULT 0), `subtotal` (NUMERIC(12,2) NOT NULL DEFAULT 0), `is_active` (BOOLEAN DEFAULT TRUE), and audit columns. A CHECK constraint MUST enforce `received_qty <= ordered_qty`.

`received_qty` is a denormalized cache updated atomically inside the master receipt RPC. Direct authenticated mutation of `received_qty` is PROHIBITED (see RP8).

- **GIVEN** admin creating PO with 3 items → **WHEN** each item has `ordered_qty`, `unit_cost`, and optional `tax_rate` → **THEN** 3 `purchase_order_items` rows created atomically with the PO header; `received_qty = 0` for all
- **GIVEN** PO item with `ordered_qty = 10` → **WHEN** attempting to set `received_qty = 15` via RPC → **THEN** CHECK constraint rejects the operation
- **GIVEN** PO item → **WHEN** `received_qty = ordered_qty` → **THEN** item is fully received; no further receipts allowed via RPC validation

`unit_cost`, `tax_rate`, `tax_amount`, and `subtotal` capture per-item financial data as specified at order time. The `unit_cost` on the purchase receipt item MAY differ from the PO item `unit_cost` when the actual received cost is communicated at receipt time (passed to inventory RPC).

### RP4: Purchase Receipts

<!-- source: proposal.md §purchase_receipts -->
Purchase receipts MUST be linked to a purchase order via composite FK `(company_id, purchase_order_id)` → `purchase_orders(company_id, id)` and to a branch via composite FK `(company_id, branch_id)` → `branches(company_id, id)`. Columns: `id` (UUID PK), `company_id`, `branch_id`, `purchase_order_id`, `receipt_number` (TEXT NOT NULL, unique per company), `receipt_date` (DATE NOT NULL DEFAULT CURRENT_DATE), `status` (TEXT NOT NULL DEFAULT 'completed'), `notes` (TEXT), `is_active` (BOOLEAN DEFAULT TRUE), and audit columns. Composite unique: `(company_id, id)`, `(company_id, receipt_number)`.

`status` values: `completed`, `cancelled`. The `cancelled` status is a placeholder for V1; receipt cancellation with inventory reversal is OUT of V1 scope (see RP12).

- **GIVEN** admin receiving against a PO → **WHEN** `receive_purchase_transaction` RPC processes receipt items → **THEN** `purchase_receipts` row inserted with auto-generated `receipt_number`, `status = 'completed'`, and `receipt_date = CURRENT_DATE`
- **GIVEN** company A has receipt "RCV-001" → **WHEN** creating duplicate "RCV-001" → **THEN** unique constraint rejects
- **GIVEN** receipt `status = 'completed'` → **WHEN** V1 → **THEN** no cancellation/reversal path exists (deferred V1)

### RP5: Purchase Receipt Items and Lot Metadata

<!-- source: proposal.md §purchase_receipt_items; exploration.md §Workflow -->
Each receipt item MUST reference its parent receipt via composite FK `(company_id, purchase_receipt_id)`, the corresponding PO item via composite FK `(company_id, purchase_order_item_id)`, and the variant via composite FK `(company_id, variant_id)`. Columns: `id` (UUID PK), `company_id`, `purchase_receipt_id`, `purchase_order_item_id`, `variant_id`, `received_qty` (NUMERIC(14,3) NOT NULL), `unit_cost` (NUMERIC(12,2) NOT NULL), `tax_rate` (NUMERIC(6,4) NOT NULL DEFAULT 0), `tax_amount` (NUMERIC(12,2) NOT NULL DEFAULT 0), `subtotal` (NUMERIC(12,2) NOT NULL DEFAULT 0), `lot_code` (TEXT), `expiration_date` (DATE), `is_active` (BOOLEAN DEFAULT TRUE), and audit columns.

`lot_code` and `expiration_date` MUST be passed through to `receive_purchase_lot` when the master receipt RPC invokes the inventory RPC. `lot_code` MAY be NULL on the receipt item; if NULL, the inventory RPC auto-generates a lot code internally.

- **GIVEN** receipt for PO item "Milk 2L" with 5 units → **WHEN** receipt item has `lot_code = "LOT-2026-001"` and `expiration_date = "2026-07-01"` → **THEN** `purchase_receipt_items` row saved AND `receive_purchase_lot` receives same `lot_code` and `expiration_date`
- **GIVEN** receipt item with `lot_code = NULL` → **WHEN** `receive_purchase_lot` called → **THEN** inventory RPC auto-generates lot code; purchasing receipt item retains NULL (inventory-generated code lives in `stock_lots`)
- **GIVEN** receipt item → **WHEN** `unit_cost`, `tax_rate`, `tax_amount`, `subtotal` populated → **THEN** stored as financial records for audit; `unit_cost` passed to `receive_purchase_lot` as `cost_per_unit`

### RP6: Atomic Receipt-to-Inventory Integration

<!-- source: proposal.md §Integration Points, §Risks, §Acceptance Criteria; exploration.md §Integration With Inventory, §Workflow -->
The master RPC `receive_purchase_transaction(p JSONB)` MUST execute the entire receipt workflow in a single PL/pgSQL transaction: validate PO exists in receivable state (`sent` or `partial`), validate all receipt items belong to the PO, INSERT `purchase_receipts`, INSERT all `purchase_receipt_items`, call `public.receive_purchase_lot(p JSONB)` for each receipt item, UPDATE `purchase_order_items.received_qty`, and transition PO status. If ANY step fails, the entire transaction MUST roll back — no partial persistence.

- **GIVEN** valid PO in `sent` with 3 items → **WHEN** `receive_purchase_transaction` called with 3 receipt items → **THEN** one `purchase_receipts` row, 3 `purchase_receipt_items` rows, 3 `stock_lots` rows, 3 `stock_movements` rows created atomically within one transaction; `received_qty` updated on all 3 PO items; PO status → `partial` or `received`
- **GIVEN** receipt with 3 items, but `receive_purchase_lot` fails on item 3 (e.g., variant missing) → **WHEN** exception thrown in PL/pgSQL → **THEN** ALL changes rolled back: no receipt header, no receipt items, no inventory lots, no `received_qty` updates, PO status unchanged
- **GIVEN** Edge Function `purchasing/receive-purchase-order` → **WHEN** calling `receive_purchase_transaction` → **THEN** Edge Function delegates entire workflow to the RPC in a single invocation; Edge Function MUST NOT loop over items
- **GIVEN** concurrent receipts on same PO → **WHEN** `receive_purchase_transaction` executes → **THEN** `SELECT FOR UPDATE` on `purchase_order_items` rows prevents `received_qty` race conditions

The inventory RPC `receive_purchase_lot` is NOT modified by the purchasing domain. The purchasing RPC passes: `company_id`, `branch_id`, `variant_id`, `qty` (from `received_qty`), `lot_code`, `expiration_date`, `cost_per_unit` (from `unit_cost`), `reference_type = 'purchase_receipt'`, `reference_id` (the `purchase_receipts.id`), and `notes`.

### RP7: Partial Receipts and PO Status Transition

<!-- source: proposal.md §PO Status Lifecycle, §Acceptance Criteria; exploration.md §Workflow -->
Partial receipts MUST be supported: a purchase order MAY receive merchandise in multiple shipments. Each receipt MUST increment `purchase_order_items.received_qty` by the quantity received. The PO status MUST transition from `sent` to `partial` on the first receipt (when any item is partially received and not all items are fully received). The PO status MUST transition from `partial` to `received` only when ALL items satisfy `received_qty = ordered_qty`. Overshoot of `received_qty` beyond `ordered_qty` MUST be rejected.

- **GIVEN** PO in `sent` with items [A: ordered 10, B: ordered 5] → **WHEN** receiving 5 units of A → **THEN** A.`received_qty = 5`, PO status → `partial`
- **GIVEN** PO in `partial` with items [A: received 5/10, B: received 0/5] → **WHEN** receiving remaining 5 of A and 5 of B → **THEN** A.`received_qty = 10`, B.`received_qty = 5`, PO status → `received`
- **GIVEN** PO item with `received_qty = 8`, `ordered_qty = 10` → **WHEN** attempting to receive QTY = 3 → **THEN** rejected (would overshoot `ordered_qty`; CHECK constraint or RPC validation prevents it)
- **GIVEN** PO in `received` → **WHEN** attempting any further receipt → **THEN** rejected (PO is fully received; no receivable state)

### RP8: Received Quantity and Status Column Protection

<!-- source: proposal.md §Security/RLS Approach, §Risks; exploration.md §Risks -->
Direct authenticated mutation of `purchase_order_items.received_qty` and `purchase_orders.status` MUST be denied by RLS. Only SECURITY DEFINER RPCs (with `service_role` or elevated privileges) MAY write these columns. Authenticated users (including admin) attempting direct UPDATE on these columns MUST be blocked.

- **GIVEN** authenticated admin → **WHEN** attempting `UPDATE purchase_order_items SET received_qty = 5 WHERE id = '<id>'` via SDK → **THEN** blocked by RLS (0 rows affected or policy violation)
- **GIVEN** authenticated admin → **WHEN** attempting `UPDATE purchase_orders SET status = 'received' WHERE id = '<id>'` via SDK → **THEN** blocked by RLS
- **GIVEN** `receive_purchase_transaction` RPC (SECURITY DEFINER) → **WHEN** updating `received_qty` and `status` → **THEN** allowed — RPC bypasses RLS and is the sole mutation path

No DELETE policies on any purchasing table — logical deletion only via `is_active = false`, `deleted_at`, `deleted_by`.

### RP9: Purchase Order Cancellation

<!-- source: proposal.md §PO Status Lifecycle, §Open Decisions §4, §Acceptance Criteria; exploration.md §Workflow -->
`cancel_purchase_order(p JSONB)` MUST allow cancellation for POs in `draft`, `sent`, or `partial` status. POs in `received` status MUST be rejected for cancellation. Partially received POs cancelled via this RPC MUST close the PO without reversing existing receipts or inventory — `cancel_purchase_order` only sets `status = 'cancelled'` and does NOT touch `received_qty` or inventory. Receipt cancellation with inventory reversal is deferred from V1 (see RP12).

- **GIVEN** PO in `draft` → **WHEN** `cancel_purchase_order` called → **THEN** `status = 'cancelled'`
- **GIVEN** PO in `sent` → **WHEN** `cancel_purchase_order` called → **THEN** `status = 'cancelled'`
- **GIVEN** PO in `partial` with some items partially received → **WHEN** `cancel_purchase_order` called → **THEN** `status = 'cancelled'`; existing receipts and `received_qty` values preserved; inventory unaffected
- **GIVEN** PO in `received` → **WHEN** `cancel_purchase_order` called → **THEN** rejected with error "cannot cancel received purchase order"
- **GIVEN** PO in `cancelled` → **WHEN** `cancel_purchase_order` called again → **THEN** rejected (already cancelled) or no-op (idempotent)

### RP10: RPC Security Hardening

<!-- source: proposal.md §RPCs; catalog-domain spec RC17; inventory-domain spec RI8 -->
All purchasing RPCs MUST follow the security pattern established by catalog and inventory domains:

| RPC | Behavior | Auth |
|-----|----------|------|
| `create_purchase_order(p JSONB)` | Validates supplier, branch, variants exist and belong to same company. Inserts PO header + items atomically with server-computed totals. Sets `status = 'draft'`. SECURITY DEFINER. | Admin via EF |
| `receive_purchase_transaction(p JSONB)` | Master receipt RPC (see RP6). Validates PO receivable state, validates items, inserts receipt + items, calls `receive_purchase_lot` per item, updates `received_qty`, transitions PO status. SECURITY DEFINER. | Admin via EF |
| `cancel_purchase_order(p JSONB)` | Validates PO in cancellable state (see RP9). Sets `status = 'cancelled'`. SECURITY DEFINER. | Admin via EF |

Every RPC MUST:
- `SET search_path = public` (via proconfig)
- `REVOKE ALL FROM PUBLIC, anon`
- `GRANT EXECUTE TO authenticated`
- Independently verify `company_id` matches authenticated user's `company_id`, rejecting cross-tenant spoofing
- Use `SECURITY DEFINER` to bypass RLS for protected columns (`received_qty`, `status`)

- **GIVEN** authenticated admin for company A → **WHEN** calling `create_purchase_order` with supplier from company B → **THEN** RPC rejects (cross-tenant validation)
- **GIVEN** authenticated admin for company A → **WHEN** calling `receive_purchase_transaction` with PO belonging to company B → **THEN** RPC rejects
- **GIVEN** authenticated admin for company A → **WHEN** calling `cancel_purchase_order` with PO belonging to company B → **THEN** RPC rejects

### RP11: RLS Multi-Tenant Isolation

<!-- source: proposal.md §Security/RLS Approach; project-architecture spec R3; catalog-domain spec RC7, RC18; inventory-domain spec RI9 -->
All five purchasing tables MUST enforce RLS with `company_id = get_company_id()` patterns matching catalog and inventory domains.

| Role | suppliers | purchase_orders | purchase_order_items | purchase_receipts | purchase_receipt_items |
|------|-----------|-----------------|----------------------|-------------------|------------------------|
| Admin | Read | Read | Read | Read | Read |
| Cashier | Read | Read | Read | Read | Read |
| Unauthenticated | Zero rows | Zero rows | Zero rows | Zero rows | Zero rows |
| Service role | ALL bypass | ALL bypass | ALL bypass | ALL bypass | ALL bypass |

- Admin and cashier MUST NOT have direct INSERT, UPDATE, or DELETE on any table — mutations MUST flow through SECURITY DEFINER RPCs (via EF)
- `service_role` receives ALL bypass for internal RPC operations
- No DELETE policies — logical deletion only
- `purchase_order_items`: RLS MUST explicitly deny authenticated UPDATE on `received_qty` column (see RP8)
- `purchase_orders`: RLS MUST explicitly deny authenticated UPDATE on `status` column (see RP8)
- Cashier reads MAY be further scoped to `branch_id` for branch-level tables (`purchase_orders`, `purchase_receipts`)

- **GIVEN** user for company A → **WHEN** querying any purchasing table → **THEN** only company A rows; company B rows invisible
- **GIVEN** unauthenticated → **WHEN** querying any purchasing table → **THEN** zero rows returned
- **GIVEN** authenticated admin → **WHEN** attempting direct INSERT/UPDATE/DELETE via SDK → **THEN** blocked by RLS (0 rows affected or policy violation)

### RP12: V1 Scope and Exclusions

<!-- source: proposal.md §Non-Goals, §Scope §Out of Scope, §Risks §Rollback; exploration.md §V1 Scope -->
V1 purchasing domain MUST deliver: supplier master data, purchase order lifecycle (`draft` → `sent` → `partial` → `received`), partial and full purchase receipts, item-level lot metadata, atomic receipt-to-inventory integration via `receive_purchase_transaction`, purchase order cancellation (without inventory reversal), and all mandated RPC hardening and RLS isolation.

The following features are explicitly OUT of V1 scope:
- Receipt cancellation with inventory reversal
- Supplier performance analytics
- Automatic purchase suggestions
- Supplier catalogs and supplier-specific price lists
- CFDI / electronic invoicing
- Multi-currency purchasing
- Purchase returns to supplier
- Frontend / UI

Receipt cancellation is acknowledged as a deferred V2 workflow. The `purchase_receipts.status` column includes `cancelled` enum value as a placeholder only; no RPC or EF SHALL implement cancellation logic in V1.

- **GIVEN** V1 → **WHEN** attempting to cancel a receipt → **THEN** no RPC or EF path exists; `purchase_receipts.status` remains `completed`
- **GIVEN** V1 → **WHEN** supplier deactivation occurs → **THEN** existing POs referencing the supplier remain valid; active POs are not auto-cancelled
- **GIVEN** V1 → **WHEN** `product_variants.last_cost` open decision → **THEN** migration MAY add or defer the column; if added, the master receipt RPC SHOULD update it atomically

The open decision on `product_variants.last_cost` (proposal open decision #1) MUST be resolved before implementers write migration `00006_purchasing_domain.sql`. If resolved as ADD: migration includes the column and the master RPC updates it. If resolved as DEFER: column is not added and cost data lives only in purchasing tables.

### RP13: Test Requirements

<!-- source: proposal.md §Acceptance Criteria; project-architecture spec R8; catalog-domain spec RC20; inventory-domain spec RI11 -->
pgTAP tests MUST cover:
- RLS isolation for all 5 tables (admin sees own-company rows, cashier read-only, unauthenticated zero rows, cross-tenant invisibility)
- Unique constraints: `(company_id, slug)` on suppliers, `(company_id, order_number)` on purchase_orders, `(company_id, receipt_number)` on purchase_receipts
- CHECK constraint: `received_qty <= ordered_qty` on purchase_order_items
- Composite FK integrity: all cross-table references validated with `company_id` scope
- RPC hardening: `search_path = public`, REVOKE/GRANT permissions, cross-tenant rejection
- `receive_purchase_transaction` transactionality: verify atomic rollback when one receipt item fails

Deno.test (Edge Function tests) MUST cover:
- `purchasing/create-purchase-order`: unauthenticated → FORBIDDEN, cashier → FORBIDDEN, admin → success with valid input, admin → rejected with cross-tenant supplier
- `purchasing/receive-purchase-order`: unauthenticated → FORBIDDEN, cashier → FORBIDDEN, admin → success with valid PO, admin → rejected on cancelled/received PO
- `purchasing/cancel-purchase-order`: unauthenticated → FORBIDDEN, cashier → FORBIDDEN, admin → success on draft/sent/partial, admin → rejected on received PO
- `EFResult<T>` shape validation for all three EFs
- Partial receipt scenarios: verify `received_qty` increment and PO status transition to `partial` then `received`

- **GIVEN** `supabase test db` → **THEN** all pgTAP tests pass
- **GIVEN** `deno test` → **THEN** all Deno.test EF tests pass

---

## Design Decisions

### DP1: Master Receipt RPC Architecture

The sole receipt path is `receive_purchase_transaction(p JSONB)`. The Edge Function `purchasing/receive-purchase-order` delegates the entire workflow to this RPC in a single call — the EF does NOT loop over receipt items. This guarantees atomicity: either all items are received (receipt + receipt items + inventory lots + status transition) or nothing is persisted. This is a hard architectural constraint designed to prevent the `received_qty` drift risk identified in both proposal §Risks and exploration §Risks.

### DP2: Denormalized `received_qty` with RLS Protection

`purchase_order_items.received_qty` is a denormalized cache updated atomically within `receive_purchase_transaction`. Rather than computing it on-the-fly from receipt items, the denormalized column simplifies PO status transitions and partial receipt validations. The risk of drift is mitigated by: (1) single RPC transaction for all mutations, (2) RLS blocking direct authenticated writes, (3) `SELECT FOR UPDATE` on PO item rows during receipt.

### DP3: Open Decisions from Proposal

| # | Decision | Resolution | Spec Impact |
|---|----------|------------|-------------|
| 1 | `product_variants.last_cost` | Unresolved | If ADD: column goes in `00006`; `receive_purchase_transaction` updates it. If DEFER: no catalog schema modification. Spec supports both paths. |
| 2 | Supplier mutations via EF→RPC | Unresolved | Spec requires EF→RPC for consistency; SDK+RLS for reads only. |
| 3 | `payment_method` as simple TEXT | TEXT | Plain text field on `purchase_orders` for V1; no enum table. |
| 4 | Cancel partially received POs | Yes, without inventory reversal | `cancel_purchase_order` closes PO at `cancelled`; receipts and inventory preserved. Deferred V2: receipt cancellation. |

---

## Cross-Domain Touchpoints

| Source Table | FK Target | Composite FK | Domain |
|-------------|-----------|--------------|--------|
| `suppliers` | `companies(id)` | `(company_id, id)` | Bootstrap |
| `purchase_orders` | `companies(id)`, `branches(id)`, `suppliers(id)` | `(company_id, supplier_id)`, `(company_id, branch_id)` | Bootstrap |
| `purchase_order_items` | `purchase_orders(id)`, `product_variants(id)` | `(company_id, purchase_order_id)`, `(company_id, variant_id)` | Purchasing → Catalog |
| `purchase_receipts` | `purchase_orders(id)`, `branches(id)` | `(company_id, purchase_order_id)`, `(company_id, branch_id)` | Purchasing → Bootstrap |
| `purchase_receipt_items` | `purchase_receipts(id)`, `purchase_order_items(id)`, `product_variants(id)` | `(company_id, purchase_receipt_id)`, `(company_id, purchase_order_item_id)`, `(company_id, variant_id)` | Purchasing → Catalog |

RPC call chain: `receive_purchase_transaction` → `receive_purchase_lot` (inventory — NOT modified).

---

## Non-Goals

- Receipt cancellation with inventory reversal (deferred V2)
- Supplier performance analytics, automatic purchase suggestions
- Supplier catalogs, supplier-specific price lists
- CFDI / electronic invoicing
- Multi-currency purchasing
- Purchase returns to supplier
- Frontend / UI
