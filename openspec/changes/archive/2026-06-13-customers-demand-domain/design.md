# Design: Customers Demand Domain

## 1. Architecture Overview

The customers-demand domain adds four tables to the existing multi-tenant schema, following the patterns established by catalog (00004), inventory (00005), and purchasing (00006). It captures customer identity and demand signals without touching inventory or money in V1.

```
┌─────────────────────────────────────────────────────────────────┐
│                   Customers Demand Domain V1                     │
│                                                                 │
│  customers ─────────────────────────────────────────────────┐   │
│  │  id (PK)                                                │   │
│  │  company_id ──► companies(id)                           │   │
│  │  name, slug (unique per company)                         │   │
│  │  tax_id, phone, email, address, notes                   │   │
│  │  is_active, created/updated/deleted audit               │   │
│  │                                                         │   │
│  ├── customer_requests ──────────────────────────────┐      │   │
│  │     id (PK)                                       │      │   │
│  │     company_id, customer_id ──► customers          │      │   │
│  │     variant_id (nullable) ──► product_variants     │      │   │
│  │     requested_qty, status, notes                   │      │   │
│  │     is_active, audit columns                       │      │   │
│  │                                                    │      │   │
│  └── preorders ───────────────────────────────────┐   │      │   │
│        id (PK)                                    │   │      │   │
│        company_id, branch_id ──► branches          │   │      │   │
│        customer_id ──► customers                   │   │      │   │
│        preorder_number (unique per company)        │   │      │   │
│        status, notes                               │   │      │   │
│        is_active, audit columns                    │   │      │   │
│                                                    │   │      │   │
│        └── preorder_items ────────────────────┐    │   │      │   │
│              id (PK)                         │    │   │      │   │
│              company_id, preorder_id ──► PO   │    │   │      │   │
│              variant_id ──► product_variants   │    │   │      │   │
│              qty, unit_price (nullable)        │    │   │      │   │
│              is_active, audit columns          │    │   │      │   │
│                                                │    │   │      │   │
│  Mutations: SDK + RLS (admin)                  │    │   │      │   │
│  Reads:     SDK + RLS (authenticated)          │    │   │      │   │
│  No EFs, no RPCs in V1                         │    │   │      │   │
└────────────────────────────────────────────────┴────┴───┴──────┴───┘
```

**Layer assignment:**

| Layer | Table | Rationale |
|-------|-------|-----------|
| SDK + RLS (admin write, cashier read) | `customers` | Customer CRUD — not money, not inventory. Constitution R2 only mandates EF→RPC for critical ops. |
| SDK + RLS (admin write, cashier read) | `customer_requests` | Demand signals — informational only, no inventory commitment. |
| SDK + RLS (admin write, cashier read) | `preorders` | Demand signals — no stock commitment in V1. |
| SDK + RLS (admin write, cashier read) | `preorder_items` | Sub-entity of preorders. |

**Why no EFs/RPCs in V1:** The constitution R2 states critical ops (money, inventory, collections) MUST go through Edge Functions. Customers-demand-domain does not touch any of these. Customer CRUD and demand signals are non-critical reads/writes. When stock reservation is activated in a future domain, preorder confirmation MAY require an EF→RPC path — but that is deferred and documented here for forward compatibility.

## 2. Data Model and Composite FK Plan

### 2.1 `customers`

```sql
CREATE TABLE public.customers (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id  UUID NOT NULL REFERENCES public.companies(id),
  name        TEXT NOT NULL,
  slug        TEXT NOT NULL,
  tax_id      TEXT,
  phone       TEXT,
  email       TEXT,
  address     TEXT,
  notes       TEXT,
  is_active   BOOLEAN NOT NULL DEFAULT TRUE,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  deleted_at  TIMESTAMPTZ,
  created_by  UUID,
  updated_by  UUID,
  deleted_by  UUID,

  UNIQUE(company_id, slug)
);
```

**Indexes:**
- `idx_customers_company_id` on `(company_id)`
- `idx_customers_company_id_id` UNIQUE on `(company_id, id)` — enables composite FK

**Composite unique:** `(company_id, slug)`, `(company_id, id)`.

### 2.2 `customer_requests`

```sql
CREATE TABLE public.customer_requests (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id    UUID NOT NULL REFERENCES public.companies(id),
  customer_id   UUID NOT NULL,
  variant_id    UUID,  -- nullable: requests may reference uncatalogued products
  requested_qty NUMERIC(14,3) NOT NULL CHECK (requested_qty > 0),
  status        TEXT NOT NULL DEFAULT 'pending'
                  CHECK (status IN ('pending', 'resolved', 'cancelled')),
  notes         TEXT,
  is_active     BOOLEAN NOT NULL DEFAULT TRUE,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  deleted_at    TIMESTAMPTZ,
  created_by    UUID,
  updated_by    UUID,
  deleted_by    UUID
);
```

**Indexes:**
- `idx_customer_requests_company_id` on `(company_id)`
- `idx_customer_requests_customer_id` on `(customer_id)`
- `idx_customer_requests_variant_id` on `(variant_id)` WHERE `variant_id IS NOT NULL`
- `idx_customer_requests_status` on `(status)`
- `idx_customer_requests_company_id_id` UNIQUE on `(company_id, id)` — enables composite FK

### 2.3 `preorders`

```sql
CREATE TABLE public.preorders (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id      UUID NOT NULL REFERENCES public.companies(id),
  branch_id       UUID NOT NULL,
  customer_id     UUID NOT NULL,
  preorder_number TEXT NOT NULL,
  status          TEXT NOT NULL DEFAULT 'draft'
                    CHECK (status IN ('draft', 'confirmed', 'fulfilled', 'cancelled')),
  notes           TEXT,
  is_active       BOOLEAN NOT NULL DEFAULT TRUE,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  deleted_at      TIMESTAMPTZ,
  created_by      UUID,
  updated_by      UUID,
  deleted_by      UUID,

  UNIQUE(company_id, preorder_number)
);
```

**Indexes:**
- `idx_preorders_company_id` on `(company_id)`
- `idx_preorders_branch_id` on `(branch_id)`
- `idx_preorders_customer_id` on `(customer_id)`
- `idx_preorders_status` on `(status)`
- `idx_preorders_company_id_id` UNIQUE on `(company_id, id)` — enables composite FK

### 2.4 `preorder_items`

```sql
CREATE TABLE public.preorder_items (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id    UUID NOT NULL REFERENCES public.companies(id),
  preorder_id   UUID NOT NULL,
  variant_id    UUID NOT NULL,
  qty           NUMERIC(14,3) NOT NULL CHECK (qty > 0),
  unit_price    NUMERIC(12,2),  -- nullable: may be set at preorder time or deferred to sale
  is_active     BOOLEAN NOT NULL DEFAULT TRUE,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  deleted_at    TIMESTAMPTZ,
  created_by    UUID,
  updated_by    UUID,
  deleted_by    UUID
);
```

**Indexes:**
- `idx_preorder_items_company_id` on `(company_id)`
- `idx_preorder_items_preorder_id` on `(preorder_id)`
- `idx_preorder_items_variant_id` on `(variant_id)`
- `idx_preorder_items_company_id_id` UNIQUE on `(company_id, id)` — enables composite FK

### 2.5 Composite Foreign Keys

All cross-table references use composite `(company_id, id)` FKs following the pattern established by catalog, inventory, and purchasing migrations. This prevents cross-tenant reference spoofing at the DDL level.

```sql
-- customer_requests → customers
ALTER TABLE public.customer_requests
  ADD CONSTRAINT fk_customer_requests_customer_same_company
  FOREIGN KEY (company_id, customer_id) REFERENCES public.customers(company_id, id);

-- customer_requests → product_variants (nullable)
ALTER TABLE public.customer_requests
  ADD CONSTRAINT fk_customer_requests_variant_same_company
  FOREIGN KEY (company_id, variant_id) REFERENCES public.product_variants(company_id, id);

-- preorders → branches
ALTER TABLE public.preorders
  ADD CONSTRAINT fk_preorders_branch_same_company
  FOREIGN KEY (company_id, branch_id) REFERENCES public.branches(company_id, id);

-- preorders → customers
ALTER TABLE public.preorders
  ADD CONSTRAINT fk_preorders_customer_same_company
  FOREIGN KEY (company_id, customer_id) REFERENCES public.customers(company_id, id);

-- preorder_items → preorders
ALTER TABLE public.preorder_items
  ADD CONSTRAINT fk_preorder_items_preorder_same_company
  FOREIGN KEY (company_id, preorder_id) REFERENCES public.preorders(company_id, id);

-- preorder_items → product_variants (NOT NULL)
ALTER TABLE public.preorder_items
  ADD CONSTRAINT fk_preorder_items_variant_same_company
  FOREIGN KEY (company_id, variant_id) REFERENCES public.product_variants(company_id, id);
```

**Prerequisite unique indexes (enabler pattern from 00004, 00005, 00006):**

| Index | On Table | Enables |
|-------|----------|---------|
| `idx_customers_company_id_id` | `customers` | All FKs to `customers` |
| `idx_preorders_company_id_id` | `preorders` | `fk_preorder_items_preorder_same_company` |
| `idx_preorder_items_company_id_id` | `preorder_items` | Future FKs to `preorder_items` |

Note: `idx_branches_company_id_id` already exists from 00005; `idx_product_variants_company_id_id` already exists from 00004. No new unique indexes needed for those targets.

**FK validation behavior:**
- `customer_requests.variant_id` is nullable: PostgreSQL skips FK validation when any referencing column is NULL, allowing requests for uncatalogued products.
- `preorder_items.variant_id` is NOT NULL: the composite FK enforces both existence and same-company ownership.
- All FKs default to `ON DELETE RESTRICT` — no cascade deletes. Physical deletion of referenced entities is already prohibited by their respective domain specs.

### 2.6 `set_updated_at()` Triggers

All four tables use the existing `set_updated_at()` function from migration 00001 via the DO-loop pattern:

```sql
DO $$
DECLARE
  t TEXT;
BEGIN
  FOREACH t IN ARRAY ARRAY['customers', 'customer_requests', 'preorders', 'preorder_items']
  LOOP
    EXECUTE format(
      'CREATE TRIGGER set_updated_at BEFORE UPDATE ON public.%I
       FOR EACH ROW EXECUTE FUNCTION public.set_updated_at()',
      t
    );
  END LOOP;
END;
$$;
```

## 3. RLS and Grants Plan

### 3.1 Policy Matrix

| Role | customers | customer_requests | preorders | preorder_items |
|------|-----------|-------------------|-----------|----------------|
| Admin | SELECT/INSERT/UPDATE own company | SELECT/INSERT/UPDATE own company | SELECT/INSERT/UPDATE own company | SELECT/INSERT/UPDATE own company |
| Cashier | SELECT own company | SELECT own company | SELECT own branch | SELECT own company (*) |
| Unauthenticated (anon) | Zero rows | Zero rows | Zero rows | Zero rows |
| Service role | ALL bypass | ALL bypass | ALL bypass | ALL bypass |

(*) `preorder_items` cashier scope is enforced through its parent `preorders.branch_id`. Since `preorder_items` has no independent `branch_id`, the RLS policy uses an `EXISTS` subquery through `preorders` so cashiers only see line items whose parent preorder belongs to their assigned branch. This is stricter than the generic `purchase_order_items` pattern because the customers-demand spec requires branch-scoped cashier reads for preorder items.

### 3.2 Per-Table Policy Definitions

**Pattern template** (repeated for all four tables):

```sql
ALTER TABLE public.{table} ENABLE ROW LEVEL SECURITY;

-- SELECT: own company rows
CREATE POLICY "{table}_select_own"
  ON public.{table} FOR SELECT
  TO authenticated
  USING (company_id = public.get_company_id());

-- INSERT: admin only, own company
CREATE POLICY "{table}_insert_admin"
  ON public.{table} FOR INSERT
  TO authenticated
  WITH CHECK (company_id = public.get_company_id() AND public.is_admin());

-- UPDATE: admin only, own company
CREATE POLICY "{table}_update_admin"
  ON public.{table} FOR UPDATE
  TO authenticated
  USING (company_id = public.get_company_id() AND public.is_admin());

-- Service role: full bypass
CREATE POLICY "{table}_service_all"
  ON public.{table} FOR ALL
  TO service_role
  USING (TRUE) WITH CHECK (TRUE);
```

**Exception — preorders branch scoping for cashier SELECT:**

```sql
CREATE POLICY "preorders_select_own"
  ON public.preorders FOR SELECT
  TO authenticated
  USING (
    company_id = public.get_company_id()
    AND (
      public.is_admin()
      OR branch_id = public.get_user_branch_id()
      OR EXISTS (
        SELECT 1 FROM public.branch_users bu
        WHERE bu.user_id = auth.uid()
          AND bu.branch_id = preorders.branch_id
          AND bu.company_id = public.get_company_id()
          AND bu.is_active = TRUE
      )
    )
  );
```

This matches the `stock_lots` and `branches` branch-scoped SELECT pattern from 00003 and 00005.

### 3.3 Grants

```sql
GRANT SELECT, INSERT, UPDATE ON public.customers TO authenticated;
GRANT SELECT ON public.customers TO anon;
GRANT SELECT ON public.customers TO service_role;

GRANT SELECT, INSERT, UPDATE ON public.customer_requests TO authenticated;
GRANT SELECT ON public.customer_requests TO anon;
GRANT SELECT ON public.customer_requests TO service_role;

GRANT SELECT, INSERT, UPDATE ON public.preorders TO authenticated;
GRANT SELECT ON public.preorders TO anon;
GRANT SELECT ON public.preorders TO service_role;

GRANT SELECT, INSERT, UPDATE ON public.preorder_items TO authenticated;
GRANT SELECT ON public.preorder_items TO anon;
GRANT SELECT ON public.preorder_items TO service_role;
```

Note: `service_role` only gets SELECT on these tables because there are no RPCs that need INSERT/UPDATE/DELETE via service_role in V1. This contrasts with catalog/inventory/purchasing where service_role needs full write access for SECURITY DEFINER RPCs. If a future domain adds preorder RPCs, service_role grants can be elevated then.

## 4. CRUD via SDK + RLS Rationale

### 4.1 Why SDK + RLS (no EF/RPC) for V1

The constitution R2 defines critical ops as "money, inventory, collections." Customers-demand-domain operations are:

| Operation | Critical? | Reasoning |
|-----------|-----------|-----------|
| Create/update customer | No | Master data — no financial or inventory impact |
| Deactivate customer | No | Logical deletion — preserved for audit |
| Create customer request | No | Informational demand signal — no inventory commitment |
| Create preorder | No | Demand signal — no stock commitment in V1 |
| Update preorder status | No | Status change only — no inventory mutation |
| Deactivate preorder | No | Logical deletion — no reversal needed |

Since none of these touch money, inventory, or collections, the constitution's R2 EF/RPC mandate does not apply. SDK + RLS provides sufficient tenant isolation through `company_id = get_company_id()` policies.

### 4.2 Forward Compatibility

When stock reservation is activated in a future domain:

1. A `reserve_stock` call may be added to preorder confirmation.
2. At that point, preorder confirmation should become an EF→RPC path (or an RPC called from the frontend SDK).
3. The migration for that future domain would add:
   - A SECURITY DEFINER RPC for `confirm_preorder(p JSONB)`.
   - RLS policy update on `preorders` to deny direct `status` column updates (matching the `prevent_purchasing_critical_col_direct_edit` trigger pattern from 00006).
   - Elevation of `service_role` grants to include INSERT/UPDATE.

This design documents the V1 boundary explicitly so future implementers understand the migration path.

### 4.3 No RPC Contracts in V1

Unlike catalog (which has `create_product_with_variant`, `deactivate_product`, etc.), purchasing (which has `create_purchase_order`, `receive_purchase_transaction`, etc.), and inventory (which has `receive_purchase_lot`, `record_sale_deduction`, etc.), the customers-demand-domain has zero RPCs in V1. All CRUD is direct table access via SDK with RLS enforcement.

## 5. State Machines and Status Values

### 5.1 Customer Request Status

```
pending ──► resolved
  │
  └──► cancelled
```

| Transition | Trigger | Constraint |
|-----------|---------|------------|
| `pending` → `resolved` | Admin marks request as fulfilled | None (SDK UPDATE) |
| `pending` → `cancelled` | Admin cancels request | None (SDK UPDATE) |
| `resolved` → `pending` | Allowed (reopen) | None |
| `cancelled` → any | Prohibited | CHECK constraint on column; enforcement left to application logic in V1 |

V1 enforcement: CHECK constraint `status IN ('pending', 'resolved', 'cancelled')` on the column prevents invalid values. State transitions are not server-enforced in V1 — customer requests have no financial or inventory consequence, so incorrect transitions are low-risk. A future domain adding purchase suggestion automation may add an RPC-enforced state machine.

### 5.2 Preorder Status

```
draft ──► confirmed ──► fulfilled
  │           │
  └───────────┴──► cancelled
```

| Transition | Trigger | Constraint |
|-----------|---------|------------|
| `draft` → `confirmed` | Customer commits to preorder | None (SDK UPDATE) |
| `confirmed` → `fulfilled` | All items delivered | None (SDK UPDATE in V1) |
| `draft` → `cancelled` | Preorder cancelled before confirmation | None (SDK UPDATE) |
| `confirmed` → `cancelled` | Preorder cancelled after confirmation | None (SDK UPDATE) — no inventory reversal since no stock was committed |
| `fulfilled` → `cancelled` | **Prohibited** | Application-layer enforcement in V1 |
| `fulfilled` → `confirmed` | **Prohibited** | Application-layer enforcement in V1 |

V1 enforcement: CHECK constraint `status IN ('draft', 'confirmed', 'fulfilled', 'cancelled')` on the column. No server-side transition enforcement because:
- V1 preorders do not commit stock — incorrect transitions have no inventory impact.
- V1 preorders do not touch money — incorrect transitions have no financial impact.
- When stock reservation is activated in a future domain, the `confirmed` transition MUST become an RPC-enforced path with a trigger blocking direct `status` column updates (matching the purchasing `prevent_purchasing_critical_col_direct_edit` pattern).

### 5.3 Preorder Number Generation

`preorder_number` is a TEXT column, unique per company via `UNIQUE(company_id, preorder_number)`. In V1, preorder numbers are client-supplied. Auto-generation (e.g., `PRE-{branch_short}-{YYYYMMDD}-{seq}`) is deferred to a future domain that adds preorder RPCs, matching the `order_number` pattern from purchasing where `create_purchase_order` RPC validates uniqueness but allows client-supplied values.

## 6. Testing Strategy

### 6.1 pgTAP: Constraints

File: `supabase/tests/test_customers_demand_constraints.sql`

Tests covering:

- **Unique constraints:**
  - `customers`: duplicate `(company_id, slug)` rejected; same slug in different company allowed.
  - `customer_requests`: `(company_id, id)` uniqueness enforced.
  - `preorders`: duplicate `(company_id, preorder_number)` rejected; same number in different company allowed.
  - `preorder_items`: `(company_id, id)` uniqueness enforced.

- **CHECK constraints:**
  - `customer_requests.status` rejects invalid values.
  - `customer_requests.requested_qty > 0` enforced.
  - `preorders.status` rejects invalid values.
  - `preorder_items.qty > 0` enforced.
  - `preorder_items.unit_price` accepts NULL.

- **Composite FK integrity:**
  - Cross-tenant `customer_requests.customer_id` reference rejected.
  - Cross-tenant `preorders.customer_id` reference rejected.
  - Cross-tenant `preorders.branch_id` reference rejected.
  - Cross-tenant `preorder_items.variant_id` reference rejected.
  - Cross-tenant `preorder_items.preorder_id` reference rejected.
  - `customer_requests.variant_id` NULL accepted (no FK violation).
  - `customer_requests.variant_id` pointing to valid same-company variant accepted.
  - `preorder_items.variant_id` NOT NULL — NULL insert rejected.

- **Logical deletion columns:**
  - `customers.deleted_at`, `deleted_by` accept NULL and non-NULL values.
  - `customer_requests.deleted_at`, `deleted_by` accept NULL and non-NULL values.
  - `preorders.deleted_at`, `deleted_by` accept NULL and non-NULL values.
  - `preorder_items.deleted_at`, `deleted_by` accept NULL and non-NULL values.

- **`set_updated_at` trigger:**
  - UPDATE on each of the four tables changes `updated_at`.

### 6.2 pgTAP: RLS Isolation

File: `supabase/tests/test_customers_demand_rls.sql`

Tests covering (matching the purchasing RLS test pattern):

- **Cross-tenant isolation:** Admin of company A cannot see company B's customers, customer_requests, preorders, or preorder_items.
- **Admin full access:** Admin of company A can SELECT all company A rows, INSERT new rows, UPDATE existing rows.
- **Cashier read-only:** Cashier of company A can SELECT company A rows, but INSERT and UPDATE fail (policy violation).
- **Cashier preorders branch scoping:** Cashier sees only preorders for their assigned branch.
- **Unauthenticated:** `anon` role sees zero rows on all four tables.
- **Service role bypass:** `service_role` can SELECT all rows regardless of company_id (no INSERT/UPDATE grant in V1, so those operations are tested as `insufficient_privilege`).
- **Logical deletion:** There are no DELETE policies — `DELETE` fails with `insufficient_privilege` for all roles.

### 6.3 No Deno.test in V1

Since there are no Edge Functions or RPCs in V1 for this domain, no Deno.test files are created. When a future domain adds preorder confirmation EF→RPC, Deno.test coverage will be added then.

### 6.4 Test Invocation

```bash
supabase test db
```

All three test files pass: `test_customers_demand_constraints.sql`, `test_customers_demand_rls.sql`.

## 7. Rollback Plan

### 7.1 Full Rollback

Since customers-demand-domain adds only new tables (no modifications to existing catalog, inventory, or purchasing schemas), rollback is a clean removal:

1. Delete migration `00007_customers_demand_domain.sql`.
2. Run `supabase db reset` — this drops all tables and reapplies migrations 00001–00006, restoring the pre-customers state.

### 7.2 Partial Rollback Risks

| Risk | Severity | Mitigation |
|------|----------|------------|
| Subsequent migrations reference customers-demand tables | Low | No downstream domains exist yet (pos-sales-domain is domain #6). The `customers` table is a prerequisite for credit-payments (domain #8) but that domain has not been started. |
| Orphaned FK references after rollback | None | Rollback via `db reset` drops all tables and recreates from scratch. |
| Data loss on rollback | Medium | V1 is pre-production; no production data exists. If production data existed, logical deletion would preserve rows and a data migration approach would be required. |

### 7.3 Forward Migration Compatibility

If a future domain needs to modify customers-demand tables (e.g., add `credit_limit` to `customers`), the migration should use `ALTER TABLE ... ADD COLUMN IF NOT EXISTS` with idempotent DO blocks, following the `last_cost` pattern from migration 00006.

## 8. Open Decisions and Recommended Choices

| # | Decision | Options | Recommendation | Rationale |
|---|----------|---------|----------------|-----------|
| 1 | Edge Functions for customer/preorder mutations | A) SDK + RLS (V1), EFs later | **A** | Customer data and preorders are not critical ops per constitution R2 (no money, no inventory). SDK+RLS is sufficient. Add EF→RPC when stock reservation is activated (future domain). |
| 2 | `customer_requests.variant_id` nullable vs free-text field | A) Nullable `variant_id` FK; B) Separate `requested_product_name` TEXT | **A** | Nullable FK is simpler, keeps schema minimal, and leverages existing composite FK infrastructure. If uncatalogued requests become common, add a `requested_product_description` TEXT column later without breaking existing data. |
| 3 | `preorder_items.unit_price` nullable vs NOT NULL | A) Nullable; B) NOT NULL with default 0 | **A** | V1 preorders are demand signals. Price may not be known at preorder time and is set at sale time (pos-sales-domain). Nullable signals "unknown" more accurately than 0. |
| 4 | `preorders.preorder_number` — add column or defer | A) Add in V1; B) Defer to RPC phase | **A** | Adding a `preorder_number TEXT UNIQUE (company_id, preorder_number)` column is low-risk (one column, one unique constraint, one index). Consistency with `purchase_orders.order_number` and `purchase_receipts.receipt_number` patterns. Client-supplied in V1; auto-generation deferred to future RPC phase. |
| 5 | `preorder_items` logical deletion columns | A) Add `is_active`, `deleted_at`, `deleted_by`; B) No deletion columns, follow parent lifecycle only | **A** | `purchase_order_items` in 00006 has `is_active` and audit columns including `deleted_at`/`deleted_by`. Consistency with that pattern. Independent logical deletion allows line-item removal without cancelling the entire preorder. |
| 6 | Preorders cashier branch scoping | A) Branch-scoped SELECT via `branch_users` JOIN; B) Cashier sees all company preorders | **A** | Matches `stock_lots` and `branches` pattern from 00003/00005. Cashiers should only see preorders for their assigned branch. Admin sees all company preorders. |

---

## Design Decisions

### D1: SDK + RLS for All Four Tables

**Decision:** All CRUD operations on `customers`, `customer_requests`, `preorders`, and `preorder_items` use direct SDK calls with RLS enforcement. No Edge Functions or RPCs in V1.

**Rationale:** Customers-demand-domain does not touch money, inventory, or collections — the three categories that constitution R2 mandates for EF→RPC. Stored procedures increase migration complexity, test surface, and review line count without proportional benefit when all mutations are simple single-row operations with RLS-enforced tenant isolation.

**Forward path:** When stock reservation is activated in a future domain, preorder confirmation (`draft` → `confirmed`) should become an RPC that calls `reserve_stock()`. At that point: add a SECURITY DEFINER RPC, add a trigger blocking direct `status` column updates, elevate `service_role` grants.

### D2: Preorder Number Column Included in V1

**Decision:** Add `preorder_number TEXT NOT NULL UNIQUE(company_id, preorder_number)` to the `preorders` table in migration 00007.

**Rationale:** Consistent with `purchase_orders.order_number` and `purchase_receipts.receipt_number`. Human-readable identifier for preorder lookup. Client-supplied in V1 (no auto-generation). Low cost: one column, one unique constraint.

### D3: `preorder_items` Has Independent Logical Deletion

**Decision:** `preorder_items` includes `is_active`, `deleted_at`, `deleted_by` columns following the `purchase_order_items` pattern.

**Rationale:** Allows line-item-level deactivation without cancelling the entire preorder. Consistent with purchasing domain conventions. The `purchase_order_items` table in 00006 has these columns and associated audit triggers.

### D4: No `preorder_id` Number Sequence Auto-Generation in V1

**Decision:** `preorder_number` is client-supplied in V1. No database sequence, auto-generation function, or RPC handles preorder numbering.

**Rationale:** Auto-generation requires either a DEFAULT expression (which can't easily produce readable formats like `PRE-SUC-20260613-0001`) or an RPC. Adding an RPC solely for number generation would violate the "no RPCs in V1" constraint. Client-side generation with server-side uniqueness enforcement is sufficient.

### D5: Cashier Preorder Branch Scoping

**Decision:** Cashier preorder SELECT uses branch scoping via `branch_users` JOIN, matching the `stock_lots` and `branches` policies.

**Rationale:** Preorders are placed at a specific branch. Cashiers should see only their own branch's preorders. Admin sees all company preorders. This aligns with the established branch-scoping pattern for inventory and purchasing.

---

## Migration Summary

**File:** `supabase/migrations/00007_customers_demand_domain.sql`

**Contents (order of execution):**

1. Create `customers` table with all columns, constraints, indexes.
2. Create `customer_requests` table with CHECK constraints, indexes.
3. Create `preorders` table with CHECK constraints, indexes.
4. Create `preorder_items` table with CHECK constraints, indexes.
5. Create unique indexes `(company_id, id)` on `customers`, `preorders`, `preorder_items` (enablers for composite FKs).
6. Add composite FK constraints (6 total).
7. Add `set_updated_at` triggers on all 4 tables.
8. Enable RLS and create policies (16 total: 4 SELECT, 4 INSERT, 4 UPDATE, 4 service_role).
9. GRANT statements.

**Estimated migration size:** ~220–260 lines.

**No modifications to existing migrations.** Migration 00007 is purely additive.

---

## Cross-Domain Dependencies

| Source | Target Table | FK Constraint | Existing Unique Index Required |
|--------|-------------|---------------|-------------------------------|
| `customer_requests` | `customers(company_id, id)` | Composite FK | `idx_customers_company_id_id` (new) |
| `customer_requests` | `product_variants(company_id, id)` | Composite FK (nullable) | `idx_product_variants_company_id_id` (exists from 00004) |
| `preorders` | `branches(company_id, id)` | Composite FK | `idx_branches_company_id_id` (exists from 00005) |
| `preorders` | `customers(company_id, id)` | Composite FK | `idx_customers_company_id_id` (new) |
| `preorder_items` | `preorders(company_id, id)` | Composite FK | `idx_preorders_company_id_id` (new) |
| `preorder_items` | `product_variants(company_id, id)` | Composite FK | `idx_product_variants_company_id_id` (exists from 00004) |

**No existing tables are modified.** All references are read-only.

**V1 does not call inventory RPCs** (`reserve_stock`, `release_reservation`, `receive_purchase_lot`, etc.). These remain available as V1 rejection stubs but are not invoked from the customers-demand domain.

---

## Estimated Review Budget

| Component | Lines |
|-----------|-------|
| Migration: tables + indexes + constraints | ~120 |
| Migration: composite FKs + unique indexes | ~40 |
| Migration: triggers + RLS + grants | ~80 |
| pgTAP: constraint tests | ~150 |
| pgTAP: RLS isolation tests | ~200 |
| **Total** | **~590** |

This exceeds the 400-line review budget per slice. Following the proposal's 2-PR chain strategy:

- **PR 1** (~350 lines): Migration (tables, indexes, constraints, FKs, triggers, RLS, grants) + constraint pgTAP tests.
- **PR 2** (~240 lines): RLS isolation pgTAP tests + `supabase db reset` verification + delta spec archive.
