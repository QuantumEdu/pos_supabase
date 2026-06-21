# Design: POS Sales Domain

## Technical Approach

Implement `pos-sales-domain` as migration `00009_pos_sales_domain.sql` plus three Edge Functions that call SECURITY DEFINER RPCs. Reads remain SDK + RLS. All money-affecting and inventory-affecting writes stay behind EF -> RPC to match `project-architecture` R2/R6 and the existing purchasing/inventory/cash-session pattern.

Because these sales RPCs are `service_role`-only, the Edge Function MUST pass explicit actor context (`actor_user_id`, `company_id`) in `p JSONB` and the SQL MUST validate that actor against membership tables instead of relying on DB-session JWT helpers — following the exact pattern established in `cash-session-domain`.

## Architecture Overview

`sales` is the branch-scoped sale header. `sale_items`, `sale_item_batches`, `payments`, and `discount_authorizations` are the child tables. Create/cancel/authorize-discount mutate through single-transaction RPCs.

```text
Client -> Edge Function -> shared sales handler -> public.create_sale_transaction RPC -> tables
                                                     |-> record_sale_deduction (inventory)
                                                     |-> sale_item_batches (traceability)
                                                     |-> cash_session validation

Client -> Edge Function -> shared sales handler -> public.cancel_sale_transaction RPC -> tables
                                                     |-> inventory reversal

Client -> Edge Function -> shared sales handler -> public.authorize_discount RPC -> discount_authorizations
```

## Data Model and Index Plan

| Table | Columns | FKs | Indexes |
|-------|---------|-----|---------|
| `sales` | `id` (UUID PK), `company_id` (UUID NN), `branch_id` (UUID NN), `cashier_user_id` (UUID NN), `customer_id` (UUID), `cash_session_id` (UUID NN), `preorder_id` (UUID), `status` (TEXT NN, CHECK `IN ('active','cancelled')`), `subtotal` (NUMERIC(12,2) NN), `discount_amount` (NUMERIC(12,2) NN DEFAULT 0), `tax_amount` (NUMERIC(12,2) NN DEFAULT 0), `total` (NUMERIC(12,2) NN), `sale_number` (BIGINT NN), `notes` (TEXT), `is_active` (BOOLEAN NN DEFAULT true), `deleted_at` (TIMESTAMPTZ), `deleted_by` (UUID), `created_at` (TIMESTAMPTZ NN), `updated_at` (TIMESTAMPTZ NN), `created_by` (UUID), `updated_by` (UUID) | `(company_id, branch_id) -> branches(company_id, id)`; `(company_id, cash_session_id) -> cash_sessions(company_id, id)`; `(company_id, customer_id) -> company_users(company_id, user_id)` (optional) | PK `(company_id, id)`; `(company_id, branch_id, status)`; `(company_id, cashier_user_id, status)`; `(company_id, branch_id, sale_number)` UNIQUE |
| `sale_items` | `id` (UUID PK), `company_id` (UUID NN), `sale_id` (UUID NN), `variant_id` (UUID NN), `quantity` (NUMERIC(12,3) NN), `unit_price` (NUMERIC(12,2) NN), `discount_percent` (NUMERIC(5,2) NN DEFAULT 0), `discount_amount` (NUMERIC(12,2) NN DEFAULT 0), `tax_percent` (NUMERIC(5,2) NN DEFAULT 0), `tax_amount` (NUMERIC(12,2) NN DEFAULT 0), `line_total` (NUMERIC(12,2) NN), `is_manual_price` (BOOLEAN NN DEFAULT false), audit columns | `(company_id, sale_id) -> sales(company_id, id)` | PK `(company_id, id)`; `(company_id, sale_id)` |
| `sale_item_batches` | `id` (UUID PK), `company_id` (UUID NN), `sale_item_id` (UUID NN), `lot_id` (UUID NN), `quantity` (NUMERIC(12,3) NN), `cost_price` (NUMERIC(12,2)), audit columns | `(company_id, sale_item_id) -> sale_items(company_id, id)` | PK `(company_id, id)`; `(company_id, sale_item_id)` |
| `payments` | `id` (UUID PK), `company_id` (UUID NN), `sale_id` (UUID NN), `payment_method` (TEXT NN, CHECK `IN ('cash','card','transfer','credit')`), `amount` (NUMERIC(12,2) NN), `reference` (TEXT), audit columns | `(company_id, sale_id) -> sales(company_id, id)` | PK `(company_id, id)`; `(company_id, sale_id)` |
| `discount_authorizations` | `id` (UUID PK), `company_id` (UUID NN), `sale_id` (UUID NN), `authorized_by` (UUID NN), `authorized_at` (TIMESTAMPTZ NN), `discount_percent` (NUMERIC(5,2) NN), `discount_amount` (NUMERIC(12,2) NN), `reason` (TEXT NN), audit columns | `(company_id, sale_id) -> sales(company_id, id)` | PK `(company_id, id)`; `(company_id, sale_id)` |

### Sale Number Sequence

A dedicated sequence per `(company_id, branch_id)`:

```sql
CREATE SEQUENCE IF NOT EXISTS sale_number_seq
  INCREMENT BY 1 NO CYCLE;
```



A helper function `next_sale_number(p_company_id UUID, p_branch_id UUID)` SHALL create/get a sequence per branch using dynamic SQL and return the next value.

## RLS and Grants Plan

| Area | Plan |
|------|------|
| SELECT | All tables: `company_id = (SELECT company_id FROM auth_helper())` — same pattern as all existing domains |
| INSERT/UPDATE/DELETE | All tables: `false` (no-op for all authenticated roles) |
| service_role | Full access (used by SECURITY DEFINER RPCs) |

Grants:
- `USAGE` on all sequences to `service_role` only
- `EXECUTE` on all SECURITY DEFINER RPCs to `service_role` only
- Authenticated users can only RPC-indirectly via EFs

## Edge Function Design

All three EFs follow the shared handler pattern from `cash-session-domain`:

### `create-sale`

| Property | Value |
|----------|-------|
| Path | `/pos-sales/create-sale` |
| Allowed roles | `['cashier', 'admin']` |
| Request schema | `CreateSaleRequest` with `branch_id`, `cashier_user_id` (optional, admin override), `customer_id` (optional), `items[]` (variant_id, quantity, unit_price, discounts, taxes), `payments[]` (method, amount, reference) |
| RPC | `create_sale_transaction` |
| Response | `CreateSaleResult` with sale_id, sale_number, totals, items, payments |

### `cancel-sale`

| Property | Value |
|----------|-------|
| Path | `/pos-sales/cancel-sale` |
| Allowed roles | `['cashier', 'admin']` |
| Request schema | `CancelSaleRequest` with `sale_id`, `reason` (optional) |
| RPC | `cancel_sale_transaction` |
| Response | `CancelSaleResult` with sale_id, status, reversed_items |

### `authorize-discount`

| Property | Value |
|----------|-------|
| Path | `/pos-sales/authorize-discount` |
| Allowed roles | `['admin']` |
| Request schema | `AuthorizeDiscountRequest` with `sale_id`, `discount_percent`, `discount_amount`, `reason` |
| RPC | `authorize_discount` |
| Response | `AuthorizeDiscountResult` with authorization_id, sale_id, authorized_at |

## RPC Design

### `create_sale_transaction(p JSONB)`

Parameters (`p` object):
- `actor_user_id` UUID — from EF auth context
- `company_id` UUID — from EF auth context
- `branch_id` UUID
- `cashier_user_id` UUID — may differ from `actor_user_id` for admin-initiated sales
- `customer_id` UUID? — nullable
- `items[]` — array of `{variant_id, quantity, unit_price, discount_percent, discount_amount, tax_percent, tax_amount, is_manual_price}`
- `payments[]` — array of `{payment_method, amount, reference}`

Transaction steps:
1. Validate caller is active in company
2. Validate cashier is active in company and has role `cashier`
3. Validate branch belongs to company
4. **Validate open cash session**: `SELECT id FROM cash_sessions WHERE company_id, branch_id, cashier_user_id, status = 'open', is_active LIMIT 1`
5. Generate next `sale_number` for `(company_id, branch_id)`
6. INSERT into `sales` with `status = 'active'`
7. For each item: INSERT into `sale_items`
8. Call `record_sale_deduction()` for total FEFO deduction
9. For each lot returned by `record_sale_deduction`: INSERT into `sale_item_batches`
10. For each payment: INSERT into `payments`
11. Return complete sale result
12. On ANY exception: ROLLBACK

### `cancel_sale_transaction(p JSONB)`

Parameters:
- `actor_user_id` UUID
- `company_id` UUID
- `sale_id` UUID
- `reason` TEXT?

Transaction steps:
1. Validate caller is active in company
2. Validate sale exists, `company_id` matches, status = `'active'`
3. If caller role is `cashier`, validate `cashier_user_id` matches original sale cashier
4. Read `sale_item_batches` for the sale to know what lots to reverse
5. For each batch: reverse inventory (call inventory reversal mechanism)
6. UPDATE `sales` SET `status = 'cancelled'`, `updated_at`, `updated_by`
7. Return cancellation result

### `authorize_discount(p JSONB)`

Parameters:
- `actor_user_id` UUID
- `company_id` UUID
- `sale_id` UUID
- `discount_percent` NUMERIC(5,2)
- `discount_amount` NUMERIC(12,2)
- `reason` TEXT

Transaction steps:
1. Validate caller is active in company and role is `admin`
2. Validate sale exists, `company_id` matches, status = `'active'`
3. INSERT into `discount_authorizations`
4. Return authorization record

## Cash Session Integration

The open-session validation is embedded in `create_sale_transaction` (RPC-level), NOT in the EF layer. This guarantees atomicity:

```sql
SELECT cs.id, cs.expected_cash_amount
  FROM cash_sessions cs
 WHERE cs.company_id = p_company_id
   AND cs.branch_id = p_branch_id
   AND cs.cashier_user_id = p_cashier_user_id
   AND cs.status = 'open'
   AND cs.is_active
 LIMIT 1;
```

If no row is returned, the RPC raises an exception and the entire transaction rolls back.

`cash_session_id` is stored on every sale for traceability. Future `close_cash_session` SHALL check for active sales before closing.

## Inventory Integration

The `record_sale_deduction` RPC (existing, from inventory-domain) is called within `create_sale_transaction`:

```sql
SELECT * FROM record_sale_deduction(jsonb_build_object(
  'company_id', p_company_id,
  'branch_id', p_branch_id,
  'items', p_items_json,  -- same items array
  'actor_user_id', p_actor_user_id
));
```

Each returned lot deduction row is inserted into `sale_item_batches`.

Inventory reversal on cancel uses the same lot-level data from `sale_item_batches` to restore stock:

```sql
-- For each lot in sale_item_batches:
SELECT * FROM adjust_inventory_stock(jsonb_build_object(
  'company_id', p_company_id,
  'branch_id', (SELECT branch_id FROM sales WHERE id = p_sale_id),
  'variant_id', (SELECT si.variant_id FROM sale_items si WHERE si.id = p_sale_item_id),
  'lot_id', p_lot_id,
  'quantity', p_quantity,  -- positive (restore)
  'movement_type', 'sale_return',
  'reference_type', 'sale_cancellation',
  'reference_id', p_sale_id::text,
  'actor_user_id', p_actor_user_id
));
```

## Sequence Diagrams

### Create Sale Flow

```text
Client                  EF                       RPC                              DB
  |                     |                         |                                |
  |-- POST /create ---->|                         |                                |
  |                     |-- validateAuth() ------->|-- JWT + role check ----------->|
  |                     |<-- auth context ---------|                                |
  |                     |                         |                                |
  |                     |-- parse + validate ----->|-- Zod schema ----------------->|
  |                     |   request body           |                                |
  |                     |                         |                                |
  |                     |-- createServiceClient() -|----------------------------->||
  |                     |                         |                                |
  |                     |-- rpc(create_sale_transaction, p) -->|                    |
  |                     |                         |-- validate open session ------>||
  |                     |                         |-- generate sale_number ------->||
  |                     |                         |-- INSERT sales --------------->||
  |                     |                         |-- INSERT sale_items ---------->||
  |                     |                         |-- record_sale_deduction() ---->||
  |                     |                         |-- INSERT sale_item_batches --->||
  |                     |                         |-- INSERT payments ------------>||
  |                     |                         |-- COMMIT --------------------->||
  |                     |<-- sale result ----------|                                |
  |<-- 200 OK ----------|                         |                                |
```

### Cancel Sale Flow

```text
Client                  EF                       RPC                              DB
  |                     |                         |                                |
  |-- POST /cancel ---->|                         |                                |
  |                     |-- validateAuth() ------->|                                |
  |                     |<-- auth context ---------|                                |
  |                     |-- parse request body --->|                                |
  |                     |                         |                                |
  |                     |-- rpc(cancel_sale_transaction, p) ->|                     |
  |                     |                         |-- validate sale active ------->||
  |                     |                         |-- read sale_item_batches ----->||
  |                     |                         |-- reverse inventory per lot --->||
  |                     |                         |-- UPDATE sales cancelled ------>||
  |                     |                         |-- COMMIT --------------------->||
  |                     |<-- cancel result --------|                                |
  |<-- 200 OK ----------|                         |                                |
```

## Migration Plan

Migration `00009_pos_sales_domain.sql`:

1. Create tables: `sales`, `sale_items`, `sale_item_batches`, `payments`, `discount_authorizations`
2. Create composite FKs and indexes
3. Create sequence helper `next_sale_number(company_id, branch_id)` or equivalent per-branch sequence
4. Create SECURITY DEFINER RPCs: `create_sale_transaction`, `cancel_sale_transaction`, `authorize_discount`
5. Create RLS policies: SELECT per company, all writes denied
6. Grant EXECUTE on RPCs to `service_role`
7. Enable RLS on all tables

Seed data: none required; these are operational tables.

## Rollback and Safety

1. **Pre-migration**: If deployed before production data, run `supabase migration squash 00009` and `db reset`.
2. **Post-production**: If production data exists, destructive rollback is not recommended. Instead:
   - Deploy a forward-fix migration
   - Use `ALTER TABLE ... DISABLE RLS` only as emergency measure (breaks tenant isolation)
   - To disable a specific EF, remove or rename its directory before next deploy
3. **pgTAP safety**: Each test file can be commented out or removed independently. Full suite rollback to 511 tests is acceptable.
4. **Data integrity**: All mutations are transactional; partial writes are impossible by design.
