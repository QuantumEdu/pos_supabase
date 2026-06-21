# Design: Purchasing Domain Implementation

**Change**: `purchasing-domain`
**Phase**: Design (SDD 3/5)
**Depends on**: `bootstrap-architecture` (00001–00003), `catalog-domain` (00004), `inventory-domain` (00005)
**Status**: Complete

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Data Model and Composite FK Plan](#2-data-model-and-composite-fk-plan)
3. [RLS and Grants Plan](#3-rls-and-grants-plan)
4. [RPC Design](#4-rpc-design)
5. [Edge Function Design and Shared Handler/Schema Files](#5-edge-function-design-and-shared-handlerschema-files)
6. [Sequence Diagram: Receive Purchase Order → Inventory Lot/Movement](#6-sequence-diagram-receive-purchase-order--inventory-lotmovement)
7. [Concurrency and Atomicity Strategy](#7-concurrency-and-atomicity-strategy)
8. [Testing Strategy: pgTAP + Deno](#8-testing-strategy-pgtap--deno)
9. [Rollback Plan](#9-rollback-plan)
10. [Open Decisions and Recommended Choices](#10-open-decisions-and-recommended-choices)

---

## 1. Architecture Overview

### Domain Position

Purchasing is domain #3 in the chained roadmap (R10): catalog → inventory → **purchasing** → customers-demand → POS-sales.

```
┌─────────────┐     ┌──────────────┐     ┌───────────────┐
│   Catalog   │     │  Inventory   │     │  Purchasing   │
│   (00004)   │     │  (00005)     │     │  (00006)      │
│             │     │              │     │               │
│  brands     │     │  stock_lots  │◄────│  suppliers    │
│  categories │     │  movements   │     │  purchase_    │
│  units      │     │  views       │     │    orders     │
│  products   │     │  RPCs:       │     │  purchase_    │
│  variants   │◄────│  receive_    │     │    order_items│
│  prices     │     │  purchase_   │     │  purchase_    │
│             │     │  lot         │     │    receipts   │
│  RPCs:      │     │  sale_deduc  │     │  purchase_    │
│  create_    │     │  adjust_     │     │    receipt_   │
│  product_   │     │  inventory   │     │    items      │
│  with_      │     │  waste       │     │               │
│  variant    │     │  expiration  │     │  RPCs:        │
│  etc.       │     │  etc.        │     │  create_po    │
└─────────────┘     └──────────────┘     │  receive_     │
       │                    │             │  purchase_    │
       │                    │             │  transaction  │
       └────────────────────┴─────────────│  cancel_po    │
            composite FKs                 │  manage_      │
            (company_id, id)              │  supplier     │
                                          └───────────────┘
```

### Request Flow (all mutations)

```
Frontend (admin JWT)
  │
  ▼
Edge Function (Deno)
  │ 8-step: CORS → validateAuth(admin) → Zod parse → RPC via service_role
  ▼
SECURITY DEFINER RPC (PL/pgSQL)
  │ validates company_id independently
  │ validates supplier/branch/variant ownership
  │ atomic DML in single transaction
  │ receives: also calls receive_purchase_lot() for inventory bridge
  ▼
PostgreSQL (RLS bypassed via SECURITY DEFINER)
```

### Read Path

```
Frontend (authenticated JWT)
  │
  ▼
Supabase JS SDK → RLS-enforced SELECT on purchasing tables
```

### Migration Boundary

All schema changes live exclusively in `00006_purchasing_domain.sql`. No existing migration files are modified. The file creates 5 new tables, composite FK indexes, RLS policies, grants, and RPCs. It depends on entities from 00001 (companies, branches, profiles, helpers), 00004 (product_variants composite FK indexes), and 00005 (receive_purchase_lot RPC).

---

## 2. Data Model and Composite FK Plan

### 2.1 `suppliers`

Company-scoped supplier master with logical deletion.

```sql
CREATE TABLE public.suppliers (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id   UUID NOT NULL REFERENCES public.companies(id),
  name         TEXT NOT NULL,
  slug         TEXT NOT NULL,
  tax_id       TEXT,
  contact_name TEXT,
  phone        TEXT,
  email        TEXT,
  address      TEXT,
  notes        TEXT,
  is_active    BOOLEAN NOT NULL DEFAULT TRUE,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_by   UUID,
  updated_by   UUID,
  deleted_at   TIMESTAMPTZ,
  deleted_by   UUID,

  UNIQUE(company_id, slug)
);
```

**Composite unique**: `(company_id, id)` (via `CREATE UNIQUE INDEX idx_suppliers_company_id_id ON public.suppliers(company_id, id)`).

**Indexes**: `idx_suppliers_company_id` on `(company_id)`, `idx_suppliers_tax_id` on `(company_id, tax_id)` for lookups.

### 2.2 `purchase_orders`

Purchase order header. Status lifecycle: `draft → sent → partial → received`, cancellable from `draft|sent|partial`.

```sql
CREATE TABLE public.purchase_orders (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id      UUID NOT NULL REFERENCES public.companies(id),
  branch_id       UUID NOT NULL,
  supplier_id     UUID NOT NULL,
  order_number    TEXT NOT NULL,
  status          TEXT NOT NULL DEFAULT 'draft'
                  CHECK (status IN ('draft', 'sent', 'partial', 'received', 'cancelled')),
  order_date      DATE NOT NULL DEFAULT CURRENT_DATE,
  expected_date   DATE,
  payment_method  TEXT,
  subtotal        NUMERIC(12,2) NOT NULL DEFAULT 0,
  tax_total       NUMERIC(12,2) NOT NULL DEFAULT 0,
  total           NUMERIC(12,2) NOT NULL DEFAULT 0,
  notes           TEXT,
  is_active       BOOLEAN NOT NULL DEFAULT TRUE,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_by      UUID,
  updated_by      UUID,
  deleted_at      TIMESTAMPTZ,
  deleted_by      UUID,

  UNIQUE(company_id, order_number)
);
```

**Composite unique**: `(company_id, id)`. **Composite FKs**:

| Constraint | References |
|---|---|
| `fk_po_branch_same_company` | `branches(company_id, id)` |
| `fk_po_supplier_same_company` | `suppliers(company_id, id)` |

### 2.3 `purchase_order_items`

Line items. `received_qty` is a denormalized cache protected from direct authenticated writes.

```sql
CREATE TABLE public.purchase_order_items (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id        UUID NOT NULL REFERENCES public.companies(id),
  purchase_order_id UUID NOT NULL,
  variant_id        UUID NOT NULL,
  ordered_qty       NUMERIC(14,3) NOT NULL CHECK (ordered_qty > 0),
  received_qty      NUMERIC(14,3) NOT NULL DEFAULT 0 CHECK (received_qty >= 0),
  unit_cost         NUMERIC(12,2) NOT NULL,
  tax_rate          NUMERIC(6,4) NOT NULL DEFAULT 0,
  tax_amount        NUMERIC(12,2) NOT NULL DEFAULT 0,
  subtotal          NUMERIC(12,2) NOT NULL DEFAULT 0,
  is_active         BOOLEAN NOT NULL DEFAULT TRUE,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_by        UUID,
  updated_by        UUID,
  deleted_at        TIMESTAMPTZ,
  deleted_by        UUID,

  CONSTRAINT chk_received_qty_lte_ordered CHECK (received_qty <= ordered_qty)
);
```

**Composite unique**: `(company_id, id)`. **Composite FKs**:

| Constraint | References |
|---|---|
| `fk_poi_po_same_company` | `purchase_orders(company_id, id)` |
| `fk_poi_variant_same_company` | `product_variants(company_id, id)` |

### 2.4 `purchase_receipts`

Receipt header. Points to the purchase order and receiving branch.

```sql
CREATE TABLE public.purchase_receipts (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id        UUID NOT NULL REFERENCES public.companies(id),
  branch_id         UUID NOT NULL,
  purchase_order_id UUID NOT NULL,
  receipt_number    TEXT NOT NULL,
  receipt_date      DATE NOT NULL DEFAULT CURRENT_DATE,
  status            TEXT NOT NULL DEFAULT 'completed'
                    CHECK (status IN ('completed', 'cancelled')),
  notes             TEXT,
  is_active         BOOLEAN NOT NULL DEFAULT TRUE,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_by        UUID,
  updated_by        UUID,
  deleted_at        TIMESTAMPTZ,
  deleted_by        UUID,

  UNIQUE(company_id, receipt_number)
);
```

**Composite unique**: `(company_id, id)`. **Composite FKs**:

| Constraint | References |
|---|---|
| `fk_pr_po_same_company` | `purchase_orders(company_id, id)` |
| `fk_pr_branch_same_company` | `branches(company_id, id)` |

### 2.5 `purchase_receipt_items`

Individual received quantities with lot metadata per line item.

```sql
CREATE TABLE public.purchase_receipt_items (
  id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id            UUID NOT NULL REFERENCES public.companies(id),
  purchase_receipt_id   UUID NOT NULL,
  purchase_order_item_id UUID NOT NULL,
  variant_id            UUID NOT NULL,
  received_qty          NUMERIC(14,3) NOT NULL CHECK (received_qty > 0),
  unit_cost             NUMERIC(12,2) NOT NULL,
  tax_rate              NUMERIC(6,4) NOT NULL DEFAULT 0,
  tax_amount            NUMERIC(12,2) NOT NULL DEFAULT 0,
  subtotal              NUMERIC(12,2) NOT NULL DEFAULT 0,
  lot_code              TEXT,
  expiration_date       DATE,
  is_active             BOOLEAN NOT NULL DEFAULT TRUE,
  created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_by            UUID,
  updated_by            UUID,
  deleted_at            TIMESTAMPTZ,
  deleted_by            UUID
);
```

**Composite unique**: `(company_id, id)`. **Composite FKs**:

| Constraint | References |
|---|---|
| `fk_pri_receipt_same_company` | `purchase_receipts(company_id, id)` |
| `fk_pri_poi_same_company` | `purchase_order_items(company_id, id)` |
| `fk_pri_variant_same_company` | `product_variants(company_id, id)` |

### 2.6 Composite FK Prerequisite Indexes

The purchasing domain needs `(company_id, id)` unique indexes on all 5 new tables (consistent with the catalog and inventory pattern) to enable cross-tenant composite FK enforcement. Additionally, purchasing tables need these pre-existing composite indexes on referenced tables:

| Referenced Table | Required Index | Created In |
|---|---|---|
| `branches` | `(company_id, id)` | 00005 |
| `product_variants` | `(company_id, id)` | 00004 |

Both already exist, so no modification to upstream migrations is needed.

### 2.7 `set_updated_at` Trigger

All 5 tables get the `set_updated_at` BEFORE UPDATE trigger, matching the catalog pattern (00004:265–278).

### 2.8 Column Pattern Summary

Following catalog/inventory conventions:
- All tables: `id UUID PRIMARY KEY DEFAULT gen_random_uuid()`, `company_id UUID NOT NULL`, `is_active BOOLEAN DEFAULT TRUE`, audit columns (`created_at`, `updated_at`, `created_by`, `updated_by`), soft-delete columns (`deleted_at`, `deleted_by`).
- Quantity columns: `NUMERIC(14,3)` (matching inventory `stock_lots.received_qty` and `stock_movements.delta_qty`).
- Monetary columns: `NUMERIC(12,2)` (matching catalog `product_prices.price`).
- Tax rate: `NUMERIC(6,4)` (e.g., `0.1600` for 16% IVA).

---

## 3. RLS and Grants Plan

### 3.1 RLS Policy Matrix

All 5 tables follow the identical 4-policy pattern from catalog (00004:380–526):

| Policy | Role | Operation | Condition |
|---|---|---|---|
| `{table}_select_own` | `authenticated` | SELECT | `company_id = public.get_company_id()` |
| `{table}_insert_admin` | `authenticated` | INSERT | `company_id = public.get_company_id() AND public.is_admin()` |
| `{table}_update_admin` | `authenticated` | UPDATE | `company_id = public.get_company_id() AND public.is_admin()` |
| `{table}_service_all` | `service_role` | ALL | `TRUE` |

**Key differences from catalog**:

1. **`purchase_order_items.received_qty` protection**: No UPDATE policy covering authenticated users on `purchase_order_items.received_qty`. The `_update_admin` policy on `purchase_order_items` explicitly excludes the `received_qty` column from the WITH CHECK, or alternatively, a trigger rejects direct authenticated updates to `received_qty` and `purchase_orders.status`. Design decision: use a trigger `prevent_purchasing_critical_col_direct_edit()` (mirroring inventory's `prevent_inventory_quantity_direct_edit()`) that rejects authenticated writes to `purchase_orders.status` and `purchase_order_items.received_qty` while allowing SECURITY DEFINER functions (run as `postgres` or `service_role`) to bypass.

2. **No DELETE policies** on any table — logical deletion only via `is_active = false`, `deleted_at`, `deleted_by`. The `{table}_update_admin` policy covers soft deletes.

3. **Cashier read-only**: Cashiers get SELECT access through the existing `_select_own` policies (which require `company_id = public.get_company_id()` for all authenticated users). No branch-scoped restriction on purchasing tables in V1 (cashiers need company-wide visibility for PO/receipt lookups, unlike inventory where branch scoping is meaningful).

### 3.2 Critical Column Protection Trigger

```sql
CREATE OR REPLACE FUNCTION public.prevent_purchasing_critical_col_direct_edit()
RETURNS TRIGGER AS $$
BEGIN
  IF current_user NOT IN ('postgres', 'service_role')
     AND (
       (TG_TABLE_NAME = 'purchase_orders' AND NEW.status IS DISTINCT FROM OLD.status)
       OR (TG_TABLE_NAME = 'purchase_order_items' AND NEW.received_qty IS DISTINCT FROM OLD.received_qty)
     ) THEN
    RAISE EXCEPTION 'Direct edits to purchase_orders.status or purchase_order_items.received_qty are prohibited; use purchasing RPCs';
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;
```

This trigger fires BEFORE UPDATE on `purchase_orders` and `purchase_order_items`. SECURITY DEFINER RPCs (running as the function owner) bypass the check because `current_user` is the definer, not `authenticated`.

### 3.3 Grants

```sql
-- All 5 tables: authenticated gets SELECT, INSERT, UPDATE
GRANT SELECT, INSERT, UPDATE ON public.suppliers TO authenticated;
GRANT SELECT, INSERT, UPDATE ON public.purchase_orders TO authenticated;
GRANT SELECT, INSERT, UPDATE ON public.purchase_order_items TO authenticated;
GRANT SELECT, INSERT, UPDATE ON public.purchase_receipts TO authenticated;
GRANT SELECT, INSERT, UPDATE ON public.purchase_receipt_items TO authenticated;

-- anon gets SELECT only (read-only browsing, same as catalog)
GRANT SELECT ON public.suppliers TO anon;
GRANT SELECT ON public.purchase_orders TO anon;
GRANT SELECT ON public.purchase_order_items TO anon;
GRANT SELECT ON public.purchase_receipts TO anon;
GRANT SELECT ON public.purchase_receipt_items TO anon;

-- service_role gets SELECT for pgTAP testing (matching catalog/inventory)
GRANT SELECT ON public.suppliers TO service_role;
GRANT SELECT ON public.purchase_orders TO service_role;
GRANT SELECT ON public.purchase_order_items TO service_role;
GRANT SELECT ON public.purchase_receipts TO service_role;
GRANT SELECT ON public.purchase_receipt_items TO service_role;
```

### 3.4 RPC Execute Hardening

All purchasing RPCs follow the `SET search_path = public` + REVOKE/GRANT pattern from catalog and inventory:

```sql
-- All purchasing RPCs: REVOKE from PUBLIC and anon
REVOKE ALL ON FUNCTION public.create_purchase_order(JSONB) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.receive_purchase_transaction(JSONB) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.cancel_purchase_order(JSONB) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.manage_supplier(JSONB) FROM PUBLIC, anon;

-- GRANT EXECUTE to authenticated only
GRANT EXECUTE ON FUNCTION public.create_purchase_order(JSONB) TO authenticated;
GRANT EXECUTE ON FUNCTION public.receive_purchase_transaction(JSONB) TO authenticated;
GRANT EXECUTE ON FUNCTION public.cancel_purchase_order(JSONB) TO authenticated;
GRANT EXECUTE ON FUNCTION public.manage_supplier(JSONB) TO authenticated;
```

---

## 4. RPC Design

All RPCs are `SECURITY DEFINER`, `SET search_path = public`, accept `p JSONB`, independently verify `company_id` matches `public.get_company_id()`, and check `public.is_admin()`.

### 4.1 `create_purchase_order(p JSONB)`

**Purpose**: Atomically insert PO header + all items. Computes `subtotal`, `tax_total`, `total` server-side from items (no client-supplied totals). Sets status `draft`.

**Input contract**:

```json
{
  "company_id": "UUID",
  "branch_id": "UUID",
  "supplier_id": "UUID",
  "order_number": "string",
  "order_date": "date (optional, default CURRENT_DATE)",
  "expected_date": "date (optional)",
  "payment_method": "text (optional)",
  "notes": "text (optional)",
  "items": [
    {
      "variant_id": "UUID",
      "ordered_qty": "number",
      "unit_cost": "number",
      "tax_rate": "number (optional, default 0)",
      "tax_amount": "number (optional, default 0)",
      "subtotal": "number (optional, server-computed override; if omitted, computed as ordered_qty * unit_cost)"
    }
  ]
}
```

**Algorithm**:

```
1. Extract and validate company_id, branch_id, supplier_id, order_number.
2. Verify company_id == public.get_company_id() AND public.is_admin().
3. Validate branch: EXISTS in branches WHERE id= AND company_id= AND is_active=TRUE.
4. Validate supplier: EXISTS in suppliers WHERE id= AND company_id= AND is_active=TRUE.
5. For each item:
   a. Validate variant_id: EXISTS in product_variants WHERE id= AND company_id= AND is_active=TRUE.
   b. Compute item.subtotal = ordered_qty * unit_cost (if not already supplied).
   c. Compute item.tax_amount = subtotal * tax_rate (if not already supplied).
6. Compute PO totals:
   a. subtotal = SUM(item.subtotal) over all items.
   b. tax_total = SUM(item.tax_amount) over all items.
   c. total = subtotal + tax_total.
7. INSERT INTO purchase_orders (company_id, branch_id, supplier_id, order_number, status='draft',
      order_date, expected_date, payment_method, subtotal, tax_total, total, notes, created_by).
8. FOR each item:
      INSERT INTO purchase_order_items (company_id, purchase_order_id, variant_id,
        ordered_qty, received_qty=0, unit_cost, tax_rate, tax_amount, subtotal, created_by).
9. RETURN jsonb_build_object('purchase_order_id', ..., 'items_count', ...).
```

**Validation errors**: supplier not found/inactive, branch not found/inactive, variant not found/inactive, empty items array, duplicate order_number, ordered_qty <= 0.

### 4.2 `receive_purchase_transaction(p JSONB)`

**Purpose**: Master receipt RPC. In a single PL/pgSQL transaction: validates PO receivable state, inserts receipt + receipt items, calls `receive_purchase_lot()` for each item, updates `received_qty` on PO items, and transitions PO status.

**Input contract**:

```json
{
  "company_id": "UUID",
  "branch_id": "UUID",
  "purchase_order_id": "UUID",
  "receipt_number": "string",
  "receipt_date": "date (optional, default CURRENT_DATE)",
  "notes": "text (optional)",
  "items": [
    {
      "purchase_order_item_id": "UUID",
      "received_qty": "number",
      "lot_code": "string (optional, auto-generated by receive_purchase_lot if null)",
      "expiration_date": "date (optional)",
      "unit_cost": "number (optional, defaults to the PO item's unit_cost)",
      "tax_rate": "number (optional, defaults to the PO item's tax_rate)"
    }
  ]
}
```

**Algorithm**:

```
1. Extract and validate company_id, branch_id, purchase_order_id, receipt_number.
2. Verify company_id == public.get_company_id() AND public.is_admin().
3. Validate branch: EXISTS and active.
4. Lock and validate PO:
   a. SELECT id, status FROM purchase_orders
      WHERE id= AND company_id= AND is_active=TRUE
        AND status IN ('sent', 'partial')
      FOR UPDATE.
   b. RAISE if not found (PO not in receivable state).
5. For each receipt item, lock the corresponding purchase_order_items row:
   a. SELECT id, variant_id, ordered_qty, received_qty, unit_cost, tax_rate
      FROM purchase_order_items
      WHERE id= AND company_id= AND purchase_order_id= AND is_active=TRUE
      FOR UPDATE.
   b. RAISE if not found or already fully received (received_qty >= ordered_qty).
   c. Validate: requested qty + received_qty <= ordered_qty.
6. INSERT INTO purchase_receipts (company_id, branch_id, purchase_order_id,
     receipt_number, receipt_date, status='completed', notes, created_by).
7. FOR each receipt item:
   a. INSERT INTO purchase_receipt_items (company_id, purchase_receipt_id,
        purchase_order_item_id, variant_id, received_qty, unit_cost,
        tax_rate, tax_amount, subtotal, lot_code, expiration_date, created_by).
   b. CALL public.receive_purchase_lot(p) with:
        {
          company_id, branch_id, variant_id,
          qty: item.received_qty,
          lot_code: item.lot_code,
          expiration_date: item.expiration_date,
          cost_per_unit: item.unit_cost,
          reference_type: 'purchase_receipt',
          reference_id: <purchase_receipts.id>,
          notes: <receipt notes>
        }
      (The inventory RPC creates a stock_lot and stock_movement atomically.)
   c. UPDATE purchase_order_items
      SET received_qty = received_qty + item.received_qty,
          updated_by = auth.uid()
      WHERE id = item.purchase_order_item_id.
8. Transition PO status:
   a. IF all PO items have received_qty >= ordered_qty:
        UPDATE purchase_orders SET status = 'received'.
   b. ELSE:
        UPDATE purchase_orders SET status = 'partial'.
9. RETURN jsonb_build_object(
     'receipt_id', ...,
     'purchase_order_id', ...,
     'po_status', ...,
     'lot_results', [ { lot_id, lot_code, movement_id, qty } per item ],
     'items_processed', ...
   ).
```

**Key invariants**:

- `receive_purchase_transaction` NEVER calls `receive_purchase_lot` from a loop in the Edge Function. The loop is inside the PL/pgSQL transaction body. If any item fails (e.g. lot_code collision after retries, variant not found), the entire transaction rolls back — no partial receipt persists.
- `SELECT FOR UPDATE` on both `purchase_orders` and all target `purchase_order_items` rows at the start serializes concurrent receipts on the same PO.
- `received_qty` is only updated via SET `received_qty = received_qty + item.received_qty` — no race with concurrent operations.
- The inventory RPC `receive_purchase_lot` is called with `reference_type = 'purchase_receipt'` and `reference_id = purchase_receipts.id` for full audit traceability back to the purchasing receipt.

**Status transitions enforced**:

| Current PO Status | Receipt Allowed? | New Status After Receipt |
|---|---|---|
| `draft` | No (must be sent first) | — |
| `sent` | Yes | `partial` (first receipt) or `received` (fully received in one shot) |
| `partial` | Yes | `partial` (still items pending) or `received` (all items now fully received) |
| `received` | No (already complete) | — |
| `cancelled` | No | — |

### 4.3 `cancel_purchase_order(p JSONB)`

**Purpose**: Close a purchase order. Works on `draft`, `sent`, `partial` statuses. Rejects `received` and already `cancelled`. Does NOT reverse inventory or receipts.

**Input contract**:

```json
{
  "company_id": "UUID",
  "purchase_order_id": "UUID",
  "reason": "string (optional)"
}
```

**Algorithm**:

```
1. Extract and validate company_id, purchase_order_id.
2. Verify company_id == public.get_company_id() AND public.is_admin().
3. Lock and validate PO:
   SELECT id, status FROM purchase_orders
   WHERE id= AND company_id= AND is_active=TRUE
     AND status IN ('draft', 'sent', 'partial')
   FOR UPDATE.
   RAISE if not found.
4. UPDATE purchase_orders SET status = 'cancelled', updated_by = auth.uid().
5. RETURN jsonb_build_object('purchase_order_id', ..., 'previous_status', ..., 'cancelled', TRUE).
```

**Clarification**: Partially received POs can be cancelled. Existing receipts and inventory lots are preserved. The PO is marked `cancelled` and no further receipts are accepted. Receipt cancellation with inventory reversal is a deferred V2 workflow.

### 4.4 `manage_supplier(p JSONB)` (Unified Supplier CRUD RPC)

**Purpose**: Single RPC for create/update/deactivate supplier mutations. Matches the catalog brand CRUD pattern (three separate RPCs per entity) but consolidated into one to reduce function count.

**Input contract**:

```json
{
  "action": "create|update|deactivate",
  "company_id": "UUID",
  "supplier_id": "UUID (required for update/deactivate)",
  "name": "string (required for create, optional for update)",
  "slug": "string (required for create, optional for update)",
  "tax_id": "string (optional)",
  "contact_name": "string (optional)",
  "phone": "string (optional)",
  "email": "string (optional)",
  "address": "string (optional)",
  "notes": "string (optional)"
}
```

**Algorithm**: Standard create/update/deactivate with company_id verification, admin check, slug uniqueness validation, and logical deletion for deactivate. Follows the pattern from `create_brand`, `update_brand`, `deactivate_brand` (00004:1029–1163).

---

## 5. Edge Function Design and Shared Handler/Schema Files

### 5.1 EF List

| EF Path | Method | RPC Called | Auth |
|---|---|---|---|
| `purchasing/create-purchase-order` | POST | `create_purchase_order` | Admin |
| `purchasing/receive-purchase-order` | POST | `receive_purchase_transaction` | Admin |
| `purchasing/cancel-purchase-order` | POST | `cancel_purchase_order` | Admin |
| `purchasing/manage-supplier` | POST | `manage_supplier` | Admin |

### 5.2 Shared Handler: `purchasing_handler.ts`

Following the `catalog_handler.ts` and `inventory_handler.ts` pattern, a generic handler for the purchasing domain:

```typescript
// supabase/functions/_shared/purchasing_handler.ts
// Generic handler for purchasing Edge Functions.
// Centralizes the 8-step pattern.

import { createClient } from "@supabase/supabase-js";
import { fail } from "./types.ts";
import { corsHeaders } from "./cors.ts";
import { validateAuth } from "./auth.ts";
import type { AuthContext } from "./auth.ts";
import type { ZodSchema, ZodIssue } from "https://esm.sh/zod@3";

export function createServiceClient() {
  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !supabaseServiceKey) return null;
  return createClient(supabaseUrl, supabaseServiceKey);
}

export async function handlePurchasingRpc<T>(
  req: Request,
  rpcName: string,
  schema: ZodSchema,
  companyField: (input: Record<string, unknown>) => string,
): Promise<Response> {
  // Step 1: CORS
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    // Step 2-4: Auth
    const auth: AuthContext = await validateAuth(req, "admin");

    // Step 5: Input validation
    const body = await req.json();
    const parsed = schema.safeParse(body);
    if (!parsed.success) {
      const message = parsed.error.issues.map((i: ZodIssue) => i.message).join("; ");
      return Response.json(fail("VALIDATION_ERROR", message), { status: 400, headers: corsHeaders });
    }
    const input = parsed.data as Record<string, unknown>;

    if (companyField(input) !== auth.companyId) {
      return Response.json(fail("FORBIDDEN", "company_id does not match authenticated user"), { status: 403, headers: corsHeaders });
    }

    // Step 6: RPC
    const client = createServiceClient();
    if (!client) {
      return Response.json(fail("SERVER_ERROR", "Missing Supabase service configuration"), { status: 500, headers: corsHeaders });
    }

    const { data, error } = await client.rpc(rpcName, { p: input });
    if (error) {
      return Response.json(fail(error.code || "RPC_ERROR", error.message), { status: 400, headers: corsHeaders });
    }

    // Step 8: Return
    return Response.json({ success: true, data: data as T }, { headers: corsHeaders });
  } catch (err) {
    if (err instanceof Response) return err;
    return Response.json(fail("SERVER_ERROR", err instanceof Error ? err.message : "Unknown error"), { status: 500, headers: corsHeaders });
  }
}
```

### 5.3 Shared Schema File: `purchasing_schemas.ts`

```typescript
// supabase/functions/_shared/purchasing_schemas.ts
// Zod input-validation schemas for purchasing Edge Functions.

import { z } from "https://esm.sh/zod@3";

const uuidSchema = z.string().uuid("Must be a valid UUID");
const company_id = uuidSchema.describe("Company UUID — must match auth user's company");

// --- Purchase Order ---

const orderItemSchema = z.object({
  variant_id: uuidSchema,
  ordered_qty: z.number().positive("Ordered quantity must be positive"),
  unit_cost: z.number().min(0, "Unit cost must be non-negative"),
  tax_rate: z.number().min(0).max(1).default(0),
  tax_amount: z.number().min(0).default(0),
  subtotal: z.number().min(0).default(0),
});

export const CreatePurchaseOrderRequest = z.object({
  company_id,
  branch_id: uuidSchema,
  supplier_id: uuidSchema,
  order_number: z.string().min(1, "Order number is required"),
  order_date: z.string().optional(),
  expected_date: z.string().optional(),
  payment_method: z.string().optional(),
  notes: z.string().optional(),
  items: z.array(orderItemSchema).min(1, "At least one order item is required"),
});
export type CreatePurchaseOrderRequest = z.infer<typeof CreatePurchaseOrderRequest>;

// --- Receive Purchase ---

const receiptItemSchema = z.object({
  purchase_order_item_id: uuidSchema,
  received_qty: z.number().positive("Received quantity must be positive"),
  lot_code: z.string().optional(),
  expiration_date: z.string().optional(),
  unit_cost: z.number().min(0).optional(),
  tax_rate: z.number().min(0).max(1).optional(),
});

export const ReceivePurchaseOrderRequest = z.object({
  company_id,
  branch_id: uuidSchema,
  purchase_order_id: uuidSchema,
  receipt_number: z.string().min(1, "Receipt number is required"),
  receipt_date: z.string().optional(),
  notes: z.string().optional(),
  items: z.array(receiptItemSchema).min(1, "At least one receipt item is required"),
});
export type ReceivePurchaseOrderRequest = z.infer<typeof ReceivePurchaseOrderRequest>;

// --- Cancel Purchase Order ---

export const CancelPurchaseOrderRequest = z.object({
  company_id,
  purchase_order_id: uuidSchema,
  reason: z.string().optional(),
});
export type CancelPurchaseOrderRequest = z.infer<typeof CancelPurchaseOrderRequest>;

// --- Supplier Management ---

export const ManageSupplierRequest = z.object({
  company_id,
  action: z.enum(["create", "update", "deactivate"]),
  supplier_id: uuidSchema.optional(),
  name: z.string().min(1).optional(),
  slug: z.string().min(1).optional(),
  tax_id: z.string().optional(),
  contact_name: z.string().optional(),
  phone: z.string().optional(),
  email: z.string().email().optional().or(z.literal("")),
  address: z.string().optional(),
  notes: z.string().optional(),
});
export type ManageSupplierRequest = z.infer<typeof ManageSupplierRequest>;

// --- Result types ---

export type PurchaseOrderResult = {
  purchase_order_id: string;
  order_number: string;
  status: string;
  items_count: number;
  total: number;
};

export type ReceivePurchaseResult = {
  receipt_id: string;
  purchase_order_id: string;
  po_status: string;
  lot_results: Array<{
    lot_id: string;
    lot_code: string;
    movement_id: string;
    qty: number;
  }>;
  items_processed: number;
};

export type CancelPurchaseOrderResult = {
  purchase_order_id: string;
  previous_status: string;
  cancelled: boolean;
};

export type SupplierResult = {
  supplier_id: string;
  company_id: string;
  deactivated?: boolean;
};
```

### 5.4 EF Implementation Pattern

Each EF follows the catalog EF pattern (e.g., `supabase/functions/catalog/create-product/index.ts`). Example for `purchasing/create-purchase-order/index.ts`:

```typescript
// Edge Function: purchasing/create-purchase-order

import { handlePurchasingRpc } from "../../_shared/purchasing_handler.ts";
import { CreatePurchaseOrderRequest } from "../../_shared/purchasing_schemas.ts";
import type { PurchaseOrderResult } from "../../_shared/purchasing_schemas.ts";

Deno.serve((req: Request) =>
  handlePurchasingRpc<PurchaseOrderResult>(
    req,
    "create_purchase_order",
    CreatePurchaseOrderRequest,
    (input) => input.company_id as string,
  )
);
```

All 4 EFs follow this identical minimal structure. The generic handler centralizes the 8-step pattern.

---

## 6. Sequence Diagram: Receive Purchase Order → Inventory Lot/Movement

```
Admin Client                    Edge Function                  PostgreSQL (RPC + Inventory)
    │                                │                                │
    │  POST /receive-purchase-order  │                                │
    │  { JWT, body }                 │                                │
    │ ─────────────────────────────► │                                │
    │                                │                                │
    │                                │  validateAuth(admin)           │
    │                                │  Zod parse input               │
    │                                │                                │
    │                                │  serviceClient.rpc(            │
    │                                │    'receive_purchase_          │
    │                                │     transaction',              │
    │                                │    { p: input })               │
    │                                │ ──────────────────────────────►│
    │                                │                                │
    │                                │                    ┌───────────┤
    │                                │                    │ BEGIN      │
    │                                │                    │            │
    │                                │                    │ 1. Verify  │
    │                                │                    │    company │
    │                                │                    │    + admin │
    │                                │                    │            │
    │                                │                    │ 2. SELECT  │
    │                                │                    │    FOR     │
    │                                │                    │    UPDATE  │
    │                                │                    │    ON      │
    │                                │                    │    PO      │
    │                                │                    │    (status │
    │                                │                    │     check) │
    │                                │                    │            │
    │                                │                    │ 3. SELECT  │
    │                                │                    │    FOR     │
    │                                │                    │    UPDATE  │
    │                                │                    │    ON ALL  │
    │                                │                    │    PO      │
    │                                │                    │    items   │
    │                                │                    │    (qty    │
    │                                │                    │     check) │
    │                                │                    │            │
    │                                │                    │ 4. INSERT  │
    │                                │                    │    purchase│
    │                                │                    │    _receipt│
    │                                │                    │            │
    │                                │                    │ FOR each   │
    │                                │                    │ receipt    │
    │                                │                    │ item:      │
    │                                │                    │            │
    │                                │                    │ 5a. INSERT │
    │                                │                    │  purchase_ │
    │                                │                    │  receipt_  │
    │                                │                    │  items     │
    │                                │                    │            │
    │                                │                    │ 5b. CALL   │
    │                                │                    │  receive_  │
    │                                │                    │  purchase_ │
    │                                │                    │  lot(p)    │
    │                                │                    │    │       │
    │                                │                    │    ├─INSERT│
    │                                │                    │    │ stock_ │
    │                                │                    │    │ lots   │
    │                                │                    │    ├─INSERT│
    │                                │                    │    │ stock_ │
    │                                │                    │    │ move-  │
    │                                │                    │    │ ments  │
    │                                │                    │    └─RETURN│
    │                                │                    │    lot_id, │
    │                                │                    │    move_id │
    │                                │                    │            │
    │                                │                    │ 5c. UPDATE │
    │                                │                    │  PO_item   │
    │                                │                    │  .received │
    │                                │                    │  _qty +=   │
    │                                │                    │  item.qty  │
    │                                │                    │            │
    │                                │                    │ 6. UPDATE  │
    │                                │                    │    PO      │
    │                                │                    │    .status │
    │                                │                    │    (partial│
    │                                │                    │    or      │
    │                                │                    │    received│
    │                                │                    │    )       │
    │                                │                    │            │
    │                                │                    │ COMMIT     │
    │                                │                    └───────────┤
    │                                │                                │
    │                                │ ◄── JSONB result ──────────────│
    │                                │    { receipt_id,               │
    │                                │      po_status,                │
    │                                │      lot_results[] }           │
    │                                │                                │
    │ ◄── Response 200               │                                │
    │    { success: true,            │                                │
    │      data: {...} }             │                                │
```

**Failure case**: If any step inside the PL/pgSQL transaction raises an exception (e.g., insufficient `ordered_qty` remaining, `lot_code` collision, variant not found, branch inactive), the entire transaction rolls back. No partial state — no receipt rows, no inventory lots, no movement records, no `received_qty` increment, no status transition.

---

## 7. Concurrency and Atomicity Strategy

### 7.1 Single RPC Transaction

All purchasing mutations execute inside a single PL/pgSQL function call, which is itself one PostgreSQL transaction. The Edge Function does NOT loop — it delegates entirely to one RPC. This eliminates the risk of partial completion from network interruptions between multiple RPC calls.

### 7.2 `SELECT FOR UPDATE` Row Locking

`receive_purchase_transaction` locks rows in this order to prevent deadlocks:

1. `SELECT ... FROM purchase_orders WHERE id = ... FOR UPDATE` — locks the PO header.
2. `SELECT ... FROM purchase_order_items WHERE id IN (...) FOR UPDATE` — locks all target line items in a single query using `IN (...)` clause (deterministic lock order by primary key prevents deadlocks with concurrent receipts on the same PO).

The lock order is consistent: always PO header first, then items. Two concurrent calls to `receive_purchase_transaction` on the same PO will serialize — the second waits for the first to commit.

### 7.3 `received_qty` Update Safety

```sql
UPDATE purchase_order_items
SET received_qty = received_qty + item.received_qty,
    updated_by = auth.uid()
WHERE id = item.purchase_order_item_id;
```

Using `SET received_qty = received_qty + ...` (not `SET received_qty = <new computed value>`) ensures the increment is atomic and concurrency-safe, even without `SELECT FOR UPDATE` (though the lock is still taken for consistency).

### 7.4 Inventory `receive_purchase_lot` Within Same Transaction

Since `receive_purchase_lot` is called from within the same PL/pgSQL function (same PostgreSQL transaction), both the purchasing-side records (receipts, receipt items) and the inventory-side records (stock_lots, stock_movements) share the same transactional boundary. Either both sides commit or neither does — no drift possible.

### 7.5 `received_qty` Critical Column Protection

The trigger `prevent_purchasing_critical_col_direct_edit()` blocks direct authenticated UPDATEs to `purchase_orders.status` and `purchase_order_items.received_qty`. Combined with the RLS policy that covers UPDATE but not on these columns, there are two independent layers of protection:

1. **Trigger layer**: rejects the write regardless of RLS (defense in depth).
2. **RLS layer**: restricts UPDATE to admin + own company.

SECURITY DEFINER RPCs bypass both layers because they run as the function owner.

---

## 8. Testing Strategy: pgTAP + Deno

### 8.1 pgTAP Tests (`supabase/tests/`)

Three test files following the inventory domain pattern:

#### `test_purchasing_constraints.sql`

Verifies:
- Composite FK enforcement (cross-tenant reference rejection, e.g. company A PO referencing company B supplier).
- CHECK constraints: `received_qty <= ordered_qty`, `ordered_qty > 0`, `received_qty >= 0`, PO status enum, receipt status enum.
- Unique constraints: duplicate `(company_id, order_number)`, duplicate `(company_id, receipt_number)`, duplicate `(company_id, slug)` on suppliers.
- Critical column protection trigger: authenticated UPDATE to `received_qty` or `purchase_orders.status` is rejected.
- `set_updated_at` trigger fires on all 5 tables.

Estimated: ~15 tests.

#### `test_purchasing_rls.sql`

Verifies (using `_set_claim` + `SET ROLE` helpers, matching catalog/inventory pgTAP pattern):
- Admin for company A sees only company A rows in all 5 tables.
- Admin for company A CANNOT see company B rows.
- Unauthenticated user returns zero rows on all 5 tables.
- Cashier can SELECT but cannot INSERT/UPDATE on any purchasing table.
- service_role bypasses all RLS.
- No DELETE path exists (physically deleting any row fails due to lack of DELETE grant/policy — or the RLS simply rejects).

Estimated: ~20 tests (5 tables × 4 role checks).

#### `test_purchasing_rpcs.sql`

Verifies:
- `create_purchase_order`: valid creation, validation errors (missing supplier, missing variant, empty items, cross-company), auto-computation of totals, default status `draft`.
- `receive_purchase_transaction`: full receipt (sent→received), partial receipt (sent→partial), overshoot rejection (received_qty > ordered_qty), PO not in receivable state rejection, POST-receipt status check, inventory lot and movement created with correct reference_type/reference_id.
- `cancel_purchase_order`: cancel draft, cancel sent, cancel partial (with existing receipts preserved), reject cancel on received PO, reject cancel on already cancelled PO.
- `manage_supplier`: create, update, deactivate (logical deletion), slug uniqueness, cross-company rejection.
- RPC hardening: `search_path`, REVOKE/GRANT, admin-only gate.

Estimated: ~25 tests.

### 8.2 Deno Tests (`supabase/functions/_test/`)

Two test files added to `_test/`:

#### `purchasing_ef_test.ts`

Tests each EF handler (unit-style with dependency injection via `InventoryHandlerDeps` / `PurchasingHandlerDeps`):

| Test | EF | Scenario |
|---|---|---|
| `createPurchaseOrder_validRequest` | `create-purchase-order` | Valid input → 200, success |
| `createPurchaseOrder_missingCompanyId` | `create-purchase-order` | Zod rejection → 400 |
| `createPurchaseOrder_unauthorized` | `create-purchase-order` | Cashier JWT → 403 |
| `createPurchaseOrder_unauthenticated` | `create-purchase-order` | No JWT → 401 |
| `createPurchaseOrder_companyMismatch` | `create-purchase-order` | JWT company ≠ request company_id → 403 |
| `receivePurchase_validRequest` | `receive-purchase-order` | Valid input → 200 |
| `receivePurchase_emptyItems` | `receive-purchase-order` | Zod rejection → 400 |
| `receivePurchase_unauthorized` | `receive-purchase-order` | Cashier → 403 |
| `cancelPurchase_validRequest` | `cancel-purchase-order` | Valid input → 200 |
| `cancelPurchase_alreadyReceived` | `cancel-purchase-order` | RPC rejects → 400 |
| `cancelPurchase_unauthorized` | `cancel-purchase-order` | Cashier → 403 |
| `manageSupplier_create` | `manage-supplier` | Valid create → 200 |
| `manageSupplier_unauthorized` | `manage-supplier` | Cashier → 403 |

Estimated: ~15 tests.

Test infrastructure: follows the inventory_handler.ts pattern with `InventoryHandlerDeps` (injectable `validateAuth` and `createServiceClient`), allowing mock/stub of auth context and RPC response without a live Supabase instance.

---

## 9. Rollback Plan

### 9.1 Full Rollback (Remove Purchasing Domain)

Since `00006_purchasing_domain.sql` creates only new objects and does not modify any existing schema:

1. Drop migration: remove `00006_purchasing_domain.sql` from the `supabase/migrations/` directory.
2. Reset database: `supabase db reset` applies all migrations from scratch excluding 00006.
3. Remove Edge Functions: delete all files under `supabase/functions/purchasing/`.
4. Remove shared files: delete `supabase/functions/_shared/purchasing_handler.ts` and `supabase/functions/_shared/purchasing_schemas.ts`.
5. Remove tests: delete `supabase/tests/test_purchasing_*.sql` and `supabase/functions/_test/purchasing_ef_test.ts`.

No downstream domains depend on purchasing yet, so rollback has zero impact on catalog or inventory.

### 9.2 Partial Rollback (If `last_cost` Column Added)

If open decision #1 is adopted and `00006` adds `product_variants.last_cost`:

1. Create a new migration `00007_remove_last_cost.sql` that drops the column via `ALTER TABLE product_variants DROP COLUMN last_cost`.
2. Apply and push the rollback migration.

The column addition is a narrow, reversible change. No data loss: `last_cost` is a denormalized cache; cost history lives in `purchase_order_items.unit_cost` and `purchase_receipt_items.unit_cost`.

### 9.3 Data Safety

No data migration or backfill is required (all tables are new). Only new data could exist in a deployed environment, and rollback would remove it via the migration drop.

---

## 10. Open Decisions and Recommended Choices

### Decision 1: Add `product_variants.last_cost` in `00006`

**Context**: `last_cost` would be a single `NUMERIC(12,2)` column on `product_variants`, updated atomically by `receive_purchase_transaction` after successful inventory receipt. It provides a quick lookup for last purchase cost without joining purchasing tables. The catalog spec RC4 does not currently include this column.

**Recommendation**: **Adopt**. Add `product_variants.last_cost NUMERIC(12,2)` in `00006` and update it inside `receive_purchase_transaction`:
```sql
UPDATE product_variants
SET last_cost = receipt_item.unit_cost,
    updated_at = now()
WHERE id = receipt_item.variant_id
  AND company_id = v_company_id;
```
Rationale:
- Low risk: single-column addition to an existing table, no FK or constraint changes.
- Updated inside the same transaction as the receipt — no drift possible.
- Makes inventory valuation and cost-based dashboards trivial (frequent POS use case).
- Rollback is trivial (`DROP COLUMN`).
- Matches inventory domain's `stock_lots.cost_per_unit` pattern (cost tracking at the right grain).

### Decision 2: Supplier Mutations — EF→RPC or SDK+RLS

**Context**: Supplier master data is CRUD with logical deletion. Reads from SDK+RLS are uncontroversial. Mutations could follow either path.

**Recommendation**: **EF→RPC**. Use `purchasing/manage-supplier` EF → `manage_supplier(p JSONB)` RPC.

Rationale:
- Consistency with catalog CRUD (brands, categories, units all go through EF→RPC per RC6 and RC15).
- Constitution R2 and R11: critical ops through Edge Functions. Supplier data integrity matters for purchase order audit trail.
- Logical deletion audit (`deleted_at`, `deleted_by`) is enforced server-side in the RPC.
- The catalog domain already has 9 EFs for its CRUD entities; adding one more for supplier management is low cost.

### Decision 3: `payment_method` as Simple Text or Enum

**Context**: `purchase_orders.payment_method` could be a free-text field, a CHECK-constrained enum, or reference a separate `payment_methods` table.

**Recommendation**: **TEXT field, no constraint**. Simplest V1 approach.

Rationale:
- V1 purchasing scope is focused on receiving and inventory integration. Payment processing is in cash-session domain (#7).
- A text field lets operators record whatever they need now (e.g., "Transferencia 30 días", "Efectivo contra entrega").
- Migration to a lookup table later is additive (add table + migration to convert text to FK).
- No business logic depends on `payment_method` in V1.

### Decision 4: `cancel_purchase_order` for Partially Received POs

**Context**: Should a PO with some items already received be cancellable?

**Recommendation**: **Yes — close without reversing receipts**.

Rationale:
- Aligns with V1 scope: receipt cancellation and inventory reversal are explicitly deferred.
- Closing a partially received PO at `cancelled` is straightforward: stop accepting further receipts, preserve what was received.
- The `cancel_purchase_order` RPC does not touch inventory — it only sets `status = 'cancelled'` on the PO.
- If the business later needs receipt reversal, that's a separate workflow (likely a new RPC `reverse_receipt` in V2) that would undo both the inventory lots and the PO item `received_qty`.

### Decision 5 (Implicit): Separate EFs per Operation vs. Single Multiplexed EF

**Context**: The proposal lists 4 EFs (3 purchase order operations + 1 supplier management). Should these be separate files or a single multiplexed EF?

**Recommendation**: **Separate files per operation**. Follow catalog pattern (RC15: "Generic multiplexed EF is PROHIBITED").

Rationale:
- Constitution R3: every critical operation must be traceable — separate EFs give clear audit boundaries.
- Matches existing catalog pattern (13 separate EF files under `catalog/`).
- Easier to reason about, test, and deploy independently.

---

## Key Design Decisions Summary

| # | Decision | Choice | Rationale |
|---|----------|--------|-----------|
| D1 | `product_variants.last_cost` | Add in 00006 | Low-risk denormalization; updated atomically in same transaction |
| D2 | Supplier CRUD path | EF→RPC | Consistency with catalog CRUD pattern |
| D3 | `payment_method` type | TEXT | Simplest V1; migrate to lookup table later |
| D4 | Cancel partially received PO | Yes (close only) | Deferred receipt reversal; preserves audit |
| D5 | EF file structure | Separate per operation | Follows catalog RC15 prohibition on multiplexed EFs |
| D6 | Critical column protection | Trigger + RLS | Defense in depth matching inventory pattern |
| D7 | Composite FK pattern | `(company_id, id)` on all relationships | Consistent with 00004/00005; no cross-tenant FK mistakes |
| D8 | RPC execute hardening | All 4 RPCs: SEARCH_PATH + REVOKE/GRANT | Matches catalog RC17 and inventory RI8 |

---

## Risks

| Risk | Severity | Mitigation | Residual |
|------|----------|------------|----------|
| `received_qty` drift (purchasing vs inventory) | High | Same transaction; trigger blocks direct writes | Zero |
| Concurrent receipt race on same PO | High | `SELECT FOR UPDATE` on PO + all items in consistent order | Zero |
| Cross-tenant FK mistakes | High | Composite FKs `(company_id, id)` on all relationships | Zero |
| Edge Function timeout on large PO receipts | Low | Entire workflow is one RPC call; no N+1 networking from EF | Negligible |
| `receive_purchase_lot` change breaks purchasing | Medium | Inventory RPC is NOT modified; purchasing calls it as-is with stable contract | Tolerable |
| Receipt cancellation complexity | Medium | Deferred from V1; `cancelled` status is a placeholder on receipts | Managed |
| Missing `last_cost` denormalization | Low | Cost data exists in purchasing tables; query-join is acceptable for now | Negligible |

---

## Next Phase

`sdd-tasks` — break down `00006_purchasing_domain.sql`, RPCs, EFs, and tests into an implementation task checklist with the 4-PR slice strategy from the proposal.
