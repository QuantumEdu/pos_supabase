# POS Sales Domain Specification

## Purpose

Branch-scoped POS transactional core for supplement sales. This domain defines the sale header, line items, FEFO lot tracking, multiple payment methods, discount authorization, and integration with open cash sessions. Every sale requires an open cash session, and every sale triggers FEFO inventory deduction.

## ADDED Requirements

### RPS1: Sales Header Model
<!-- source: proposal.md §Data Model Overview -->
The system MUST define a `sales` table as the branch-scoped sale header. `sales` MUST include `id` (UUID PK, `gen_random_uuid()`), `company_id` (UUID NOT NULL), `branch_id` (UUID NOT NULL), `cashier_user_id` (UUID NOT NULL), `customer_id` (UUID NULL), `cash_session_id` (UUID NOT NULL), `preorder_id` (UUID NULL), `status` (TEXT NOT NULL with CHECK `status IN ('active', 'cancelled')`), `subtotal` (NUMERIC(12,2) NOT NULL), `discount_amount` (NUMERIC(12,2) NOT NULL DEFAULT 0), `tax_amount` (NUMERIC(12,2) NOT NULL DEFAULT 0), `total` (NUMERIC(12,2) NOT NULL), `sale_number` (BIGINT NOT NULL), `notes` (TEXT NULL), logical deletion columns (`is_active`, `deleted_at`, `deleted_by`), and audit columns (`created_at`, `updated_at`, `created_by`, `updated_by`). Composite uniqueness MUST include `(company_id, id)`. Physical deletion MUST be prohibited.

- **GIVEN** a cashier creates a sale for company A and branch B1 **WHEN** the sale is persisted **THEN** `sales` stores `company_id = A`, `branch_id = B1`, `cashier_user_id`, `status = 'active'`, `cash_session_id`, `subtotal`, `discount_amount`, `tax_amount`, `total`, and `sale_number`
- **GIVEN** a sale is created **WHEN** queried **THEN** `sale_number` SHALL be unique within `(company_id, branch_id)` and sequentially assigned
- **GIVEN** any actor attempts physical DELETE on `sales` **WHEN** the statement executes **THEN** the operation MUST be rejected

### RPS2: Sale Items Model
<!-- source: proposal.md §Data Model Overview -->
The system MUST define a `sale_items` table for line items. `sale_items` MUST include `id` (UUID PK), `company_id` (UUID NOT NULL), `sale_id` (UUID NOT NULL), `variant_id` (UUID NOT NULL), `quantity` (NUMERIC(12,3) NOT NULL), `unit_price` (NUMERIC(12,2) NOT NULL), `discount_percent` (NUMERIC(5,2) NOT NULL DEFAULT 0), `discount_amount` (NUMERIC(12,2) NOT NULL DEFAULT 0), `tax_percent` (NUMERIC(5,2) NOT NULL DEFAULT 0), `tax_amount` (NUMERIC(12,2) NOT NULL DEFAULT 0), `line_total` (NUMERIC(12,2) NOT NULL), `is_manual_price` (BOOLEAN NOT NULL DEFAULT false), and standard audit columns. The sale reference MUST use a composite foreign key `(company_id, sale_id) -> sales(company_id, id)`.

- **GIVEN** a sale with 3 line items **WHEN** the sale is created **THEN** each `sale_items` row references the correct `sale_id` via composite FK
- **GIVEN** a line item references sale S in company A **WHEN** persisted **THEN** the composite FK MUST reject a `sale_id` that belongs to another company

### RPS3: Sale Item Batches Model (FEFO Traceability)
<!-- source: proposal.md §Data Model Overview -->
The system MUST define a `sale_item_batches` table to track exact inventory lots consumed per sale item. `sale_item_batches` MUST include `id` (UUID PK), `company_id` (UUID NOT NULL), `sale_item_id` (UUID NOT NULL), `lot_id` (UUID NOT NULL), `quantity` (NUMERIC(12,3) NOT NULL), `cost_price` (NUMERIC(12,2) NULL), and standard audit columns.

- **GIVEN** a sale item deducts inventory from 2 lots **WHEN** the sale transaction completes **THEN** exactly 2 `sale_item_batches` rows exist for that `sale_item_id`
- **GIVEN** a cancelled sale **WHEN** inventory is reversed **THEN** the `sale_item_batches` rows for that sale SHALL remain for audit traceability

### RPS4: Payments Model
<!-- source: proposal.md §Data Model Overview -->
The system MUST define a `payments` table for sale payment methods. `payments` MUST include `id` (UUID PK), `company_id` (UUID NOT NULL), `sale_id` (UUID NOT NULL), `payment_method` (TEXT NOT NULL with CHECK `payment_method IN ('cash', 'card', 'transfer', 'credit')`), `amount` (NUMERIC(12,2) NOT NULL), `reference` (TEXT NULL), and standard audit columns. Sale reference MUST use composite FK `(company_id, sale_id) -> sales(company_id, id)`.

- **GIVEN** a sale is paid with $50 cash and $50 card **WHEN** the sale is created **THEN** exactly 2 `payments` rows exist for that sale
- **GIVEN** a payment references sale S in a different company **WHEN** persisted **THEN** the composite FK MUST reject the cross-company reference

### RPS5: Discount Authorizations Model
<!-- source: proposal.md §Data Model Overview -->
The system MUST define a `discount_authorizations` table for admin discount audit trail. `discount_authorizations` MUST include `id` (UUID PK), `company_id` (UUID NOT NULL), `sale_id` (UUID NOT NULL), `authorized_by` (UUID NOT NULL), `authorized_at` (TIMESTAMPTZ NOT NULL), `discount_percent` (NUMERIC(5,2) NOT NULL), `discount_amount` (NUMERIC(12,2) NOT NULL), `reason` (TEXT NOT NULL), and standard audit columns.

- **GIVEN** an admin authorizes a 15% discount on sale S **WHEN** the authorization is recorded **THEN** `discount_authorizations` stores the admin user, timestamp, discount percent, amount, and reason
- **GIVEN** a discount authorization references sale S **WHEN** the sale is queried **THEN** the authorization SHALL be retrievable via the sale reference

### RPS6: Open Cash Session Enforcement
<!-- source: proposal.md §Cash Session Integration -->
The system MUST enforce that a sale can only be created when an open cash session exists for the `(company_id, branch_id, cashier_user_id)`. This enforcement MUST occur inside the SECURITY DEFINER RPC, not only in the Edge Function layer.

- **GIVEN** cashier U has no open cash session in branch B1 **WHEN** cashier U attempts to create a sale **THEN** the operation MUST be rejected with an error indicating no open session
- **GIVEN** cashier U has an open session in branch B1 **WHEN** cashier U creates a sale **THEN** the sale MUST be linked to that session via `cash_session_id`
- **GIVEN** a session has status `'closed'` **WHEN** any cashier attempts to create a sale linked to it **THEN** the operation MUST be rejected

### RPS7: RLS — Read Access Per Company Scope
<!-- source: proposal.md §Critical Mutation Boundary -->
The system MUST define RLS policies on `sales`, `sale_items`, `sale_item_batches`, `payments`, and `discount_authorizations` that allow SELECT only for rows matching the caller's `company_id`. All WRITE operations (INSERT, UPDATE, DELETE) MUST be denied for authenticated roles. Only `service_role` via SECURITY DEFINER RPCs MAY mutate these tables.

- **GIVEN** user U belongs to company A **WHEN** U queries `sales` **THEN** U sees only sales with `company_id = A`
- **GIVEN** user U belongs to company A **WHEN** U attempts to INSERT into `sales` directly **THEN** the operation MUST be rejected
- **GIVEN** user U belongs to company A **WHEN** U attempts to DELETE from `sales` **THEN** the operation MUST be rejected

### RPS8: Create-Sale Edge Function and RPC
<!-- source: proposal.md §Critical Mutation Boundary -->
The system MUST provide a `create-sale` Edge Function that accepts an authenticated request from `cashier` or `admin` roles and invokes the `create_sale_transaction` SECURITY DEFINER RPC. The RPC MUST perform, in a single transaction: (1) validate open cash session, (2) create sale header, (3) insert sale items, (4) call `record_sale_deduction` for FEFO deduction, (5) persist `sale_item_batches` from deduction results, (6) insert payments, (7) assign branch-scoped `sale_number`, (8) compute totals. On any failure, the entire transaction MUST roll back.

- **GIVEN** a valid create-sale request with items, payments, and an open session **WHEN** the EF calls the RPC **THEN** the sale is created, inventory is deducted, and a complete sale result is returned
- **GIVEN** a create-sale request includes items with total quantity exceeding available stock **WHEN** `record_sale_deduction` fails **THEN** the entire transaction rolls back and no sale is persisted
- **GIVEN** an unauthenticated create-sale request **WHEN** the EF processes it **THEN** a 401 response is returned
- **GIVEN** a create-sale request from a non-cashier/non-admin user **WHEN** the EF processes it **THEN** a 403 response is returned

### RPS9: Cancel-Sale Edge Function and RPC
<!-- source: proposal.md §Critical Mutation Boundary -->
The system MUST provide a `cancel-sale` Edge Function that accepts an authenticated request from `cashier` (own sales) or `admin` (any sale in company) roles and invokes the `cancel_sale_transaction` SECURITY DEFINER RPC. The RPC MUST perform, in a single transaction: (1) validate the sale exists, is `active`, and belongs to the caller's company, (2) reverse inventory deduction, (3) mark sale as `cancelled`.

- **GIVEN** an active sale with inventory deducted **WHEN** a valid cancel-sale request is processed **THEN** the sale status becomes `cancelled` and inventory is restored
- **GIVEN** a cancel-sale request for a sale in `cancelled` status **WHEN** the RPC processes it **THEN** the operation MUST be rejected with an appropriate error
- **GIVEN** a cashier attempts to cancel another cashier's sale **WHEN** the EF processes it **THEN** the RPC SHALL reject the cross-cashier cancellation (only admin may cancel any sale)

### RPS10: Authorize-Discount Edge Function and RPC
<!-- source: proposal.md §Critical Mutation Boundary -->
The system MUST provide an `authorize-discount` Edge Function that accepts an authenticated request from `admin` role only and invokes the `authorize_discount` SECURITY DEFINER RPC. The RPC MUST insert a `discount_authorizations` row and return the authorization record.

- **GIVEN** an admin sends an authorize-discount request with valid sale ID and discount details **WHEN** the EF invokes the RPC **THEN** a `discount_authorizations` record is persisted and returned
- **GIVEN** a cashier attempts to authorize a discount **WHEN** the EF processes it **THEN** a 403 response is returned

### RPS11: Branch-Scoped Sale Numbering
<!-- source: proposal.md §Data Model Overview -->
The system MUST assign `sale_number` sequentially per `(company_id, branch_id)`. A dedicated sequence object per branch SHALL be created. The sequence MUST be called `sale_number_seq_{company_id}_{branch_id}` or an equivalent mechanism.

- **GIVEN** two sales are created in the same branch **WHEN** both complete **THEN** their `sale_number` values SHALL be sequential without gaps
- **GIVEN** sales are created in different branches of the same company **WHEN** both complete **THEN** their `sale_number` values MAY have the same number (each branch has its own sequence)

### RPS12: Inventory Reversal on Cancel
<!-- source: proposal.md §Inventory Integration -->
The `cancel_sale_transaction` RPC MUST reverse inventory deduction for all sale items. The reversal SHALL call the same underlying inventory movement mechanism as `record_sale_deduction` but with reversed quantity.

- **GIVEN** a sale with 5 units of variant V is cancelled **WHEN** the cancel transaction completes **THEN** inventory stock for variant V increases by 5 units
- **GIVEN** inventory reversal fails **WHEN** the cancel transaction executes **THEN** the entire transaction MUST roll back
