# Customers Demand Domain Specification

## Purpose

Customer master data and demand capture for multi-tenant SaaS POS. Customer identity, informational product requests, and preorder tracking with branch scoping. V1 is SDK + RLS only — no Edge Functions, no RPCs, no inventory commitment. Customers are a prerequisite for credit-payments (domain #8) and preorders feed future purchase suggestions (dashboard-reports domain).

## ADDED Requirements

### RCD1: Customer Master Data

<!-- source: proposal.md §Data Model Overview §customers; exploration.md §Suggested Fields §customers -->
Customer master data MUST be company-scoped with logical deletion. The `customers` table MUST include `id` (UUID PK, `gen_random_uuid()`), `company_id` (UUID NOT NULL, FK → `companies(id)`), `name` (TEXT NOT NULL), `slug` (TEXT NOT NULL, unique per company via `(company_id, slug)`), optional `tax_id` (TEXT), `phone` (TEXT), `email` (TEXT), `address` (TEXT), `notes` (TEXT), `is_active` (BOOLEAN DEFAULT TRUE), and audit columns (`created_at`, `updated_at`, `created_by`, `updated_by`, `deleted_at`, `deleted_by`). Physical deletion PROHIBITED. Composite unique constraints: `(company_id, id)`, `(company_id, slug)`.

- **GIVEN** admin for company A → **WHEN** creating customer "ACME Corp" with slug "acme-corp" → **THEN** customer created with `company_id = A`, `is_active = true`, and audit columns populated
- **GIVEN** customer "ACME Corp" with slug "acme-corp" exists for company A → **WHEN** creating duplicate slug for same company → **THEN** rejected with unique constraint violation
- **GIVEN** admin → **WHEN** creating customer with optional `tax_id`, `phone`, `email`, `address`, `notes` NULL → **THEN** record created successfully with NULL optional fields
- **GIVEN** customer exists → **WHEN** admin deactivates → **THEN** `is_active = false`, `deleted_at` and `deleted_by` set; row preserved (no physical deletion)

### RCD2: Customer Logical Deletion

<!-- source: proposal.md §Security/RLS Approach; constitution §4, §5 -->
Customer deactivation MUST set `is_active = false`, `deleted_at = NOW()`, `deleted_by = auth.uid()`. RLS MUST deny physical DELETE — no DELETE policy SHALL exist on `customers`. Deactivated customers MUST remain in the database for referential integrity of existing `customer_requests` and `preorders`. The `(company_id, slug)` unique constraint applies to all rows — a deactivated customer's slug is NOT freed for reuse unless the design phase explicitly adopts active-only uniqueness.

- **GIVEN** active customer → **WHEN** admin deactivates via SDK UPDATE → **THEN** `is_active = false`, `deleted_at`, `deleted_by` set; row preserved
- **GIVEN** any role → **WHEN** attempting `DELETE FROM customers` → **THEN** rejected (no DELETE policy)
- **GIVEN** deactivated customer → **WHEN** querying existing `customer_requests` or `preorders` referencing it → **THEN** FK references valid (rows preserved)
- **GIVEN** deactivated customer slug "acme-corp" → **WHEN** creating new customer with same slug → **THEN** rejected by unique constraint (active-only uniqueness MAY be adopted in design phase)

### RCD3: Customer Requests

<!-- source: proposal.md §Data Model Overview §customer_requests; exploration.md §Suggested Fields §customer_requests -->
Customer requests MUST capture demand signals without committing inventory. The `customer_requests` table MUST include `id` (UUID PK, `gen_random_uuid()`), `company_id` (UUID NOT NULL), `customer_id` (UUID NOT NULL), `variant_id` (UUID — nullable, see RCD4), `requested_qty` (NUMERIC(14,3) NOT NULL), `status` (TEXT NOT NULL DEFAULT 'pending' with CHECK `status IN ('pending', 'resolved', 'cancelled')`), `notes` (TEXT), `is_active` (BOOLEAN DEFAULT TRUE), and audit columns (`created_at`, `updated_at`, `created_by`, `updated_by`, `deleted_at`, `deleted_by`). Physical deletion PROHIBITED. Composite unique constraint: `(company_id, id)`.

- **GIVEN** admin → **WHEN** creating customer request with `customer_id`, `requested_qty = 10`, and `variant_id = NULL` → **THEN** request created with `status = 'pending'` and NULL `variant_id`
- **GIVEN** admin → **WHEN** creating customer request with valid `variant_id` and `requested_qty = 5` → **THEN** request created referencing variant via composite FK
- **GIVEN** request with `status = 'pending'` → **WHEN** admin resolves → **THEN** `status = 'resolved'` via SDK UPDATE
- **GIVEN** request with `status = 'pending'` or `'resolved'` → **WHEN** admin cancels → **THEN** `status = 'cancelled'` via SDK UPDATE
- **GIVEN** admin → **WHEN** deactivating request → **THEN** `is_active = false`, `deleted_at`, `deleted_by` set; no physical deletion

### RCD4: Customer Request Variant Reference

<!-- source: proposal.md §Integration Points §With Catalog; exploration.md §Integration Points §Catalog -->
`customer_requests.variant_id` MUST be nullable. When non-NULL, it MUST reference `product_variants` via composite FK `(company_id, variant_id) → product_variants(company_id, id)`. A NULL `variant_id` indicates the customer is requesting a product not yet catalogued by the business. The FK MUST use `ON DELETE RESTRICT` (PostgreSQL default) — variant physical deletion is already PROHIBITED by catalog domain RC4.

- **GIVEN** active product variant in company A → **WHEN** creating customer request with `variant_id` set → **THEN** FK validates `(company_id, variant_id)` references existing variant
- **GIVEN** admin → **WHEN** creating customer request with `variant_id = NULL` → **THEN** record created successfully; no FK violation
- **GIVEN** customer request with `variant_id` set → **WHEN** queried → **THEN** variant reference remains even if variant is deactivated (catalog RC4 — only logical deletion)
- **GIVEN** customer request → **WHEN** `variant_id` references variant from different company → **THEN** composite FK rejects (cross-tenant prevention)

### RCD5: Preorder Headers and Status Lifecycle

<!-- source: proposal.md §Data Model Overview §preorders, §Preorder Status Lifecycle; exploration.md §Suggested Fields §preorders -->
Preorder headers MUST represent customer intent-to-buy at a specific branch. The `preorders` table MUST include `id` (UUID PK, `gen_random_uuid()`), `company_id` (UUID NOT NULL), `branch_id` (UUID NOT NULL), `customer_id` (UUID NOT NULL), `preorder_number` (TEXT NOT NULL, unique per company via `(company_id, preorder_number)`), `status` (TEXT NOT NULL DEFAULT 'draft' with CHECK `status IN ('draft', 'confirmed', 'fulfilled', 'cancelled')`), `notes` (TEXT), `is_active` (BOOLEAN DEFAULT TRUE), and audit columns (`created_at`, `updated_at`, `created_by`, `updated_by`, `deleted_at`, `deleted_by`). Physical deletion PROHIBITED. Composite unique constraints: `(company_id, id)`, `(company_id, preorder_number)`.

Preorder status lifecycle:

```
draft ──► confirmed ──► fulfilled
  │           │
  └───────────┴──► cancelled
```

- `draft → confirmed`: customer commits to the preorder.
- `confirmed → fulfilled`: all items delivered (future pos-sales domain or manual status update in V1).
- `draft|confirmed → cancelled`: preorder cancelled. No inventory reversal needed (no stock was committed).
- `fulfilled → cancelled`: PROHIBITED.

In V1, status transitions occur via SDK UPDATE by admin. No server-side state machine enforcement exists — this is a schema-level CHECK constraint with documented transition rules. When stock reservation is activated in a future domain, an RPC-enforced state machine MUST be added.

- **GIVEN** admin → **WHEN** creating preorder with `customer_id`, `branch_id`, `preorder_number`, and `status = 'draft'` → **THEN** preorder header created with audit columns populated
- **GIVEN** preorder number "PRE-001" exists for company A → **WHEN** creating another preorder with "PRE-001" for company A → **THEN** rejected by unique constraint
- **GIVEN** preorder number "PRE-001" exists for company A → **WHEN** creating "PRE-001" for company B → **THEN** allowed
- **GIVEN** preorder in `draft` → **WHEN** admin updates `status = 'confirmed'` → **THEN** transition allowed via SDK UPDATE
- **GIVEN** preorder in `confirmed` → **WHEN** admin updates `status = 'fulfilled'` → **THEN** transition allowed via SDK UPDATE
- **GIVEN** preorder in `draft` or `confirmed` → **WHEN** admin updates `status = 'cancelled'` → **THEN** transition allowed; no inventory reversal (no stock was committed)
- **GIVEN** preorder in `fulfilled` → **WHEN** admin attempts `status = 'cancelled'` → **THEN** CHECK constraint rejects; `fulfilled` is not a valid target for transition to `cancelled` at data level
- **GIVEN** admin → **WHEN** deactivating preorder → **THEN** `is_active = false`, `deleted_at`, `deleted_by` set; no physical deletion

### RCD6: Preorder Items

<!-- source: proposal.md §Data Model Overview §preorder_items; exploration.md §Suggested Fields §preorder_items -->
Preorder items MUST reference catalog variants and their parent preorder. The `preorder_items` table MUST include `id` (UUID PK, `gen_random_uuid()`), `company_id` (UUID NOT NULL), `preorder_id` (UUID NOT NULL), `variant_id` (UUID NOT NULL), `qty` (NUMERIC(14,3) NOT NULL), `unit_price` (NUMERIC(12,2) — nullable; price MAY be set at preorder time or deferred to sale), `is_active` (BOOLEAN DEFAULT TRUE), audit columns (`created_at`, `updated_at`, `created_by`, `updated_by`), and logical deletion columns (`deleted_at`, `deleted_by`). Composite unique constraint: `(company_id, id)`.

`preorder_items` MUST have independent logical deletion columns (`is_active`, `deleted_at`, `deleted_by`) to match the purchase-order item pattern from migration 00006 and to allow future preorder line cancellation without physically deleting historical demand.

- **GIVEN** preorder in `draft` → **WHEN** admin inserts preorder item with `variant_id`, `qty = 5`, and `unit_price = NULL` → **THEN** item created with NULL `unit_price`
- **GIVEN** preorder in `draft` → **WHEN** admin inserts preorder item with `variant_id`, `qty = 3`, and `unit_price = 199.99` → **THEN** item created with `unit_price` populated
- **GIVEN** preorder item → **WHEN** admin inserts item with `variant_id` referencing variant from different company → **THEN** composite FK `(company_id, variant_id)` rejects
- **GIVEN** preorder item → **WHEN** `variant_id = NULL` on insert → **THEN** rejected (NOT NULL constraint)
- **GIVEN** preorder item exists → **WHEN** admin deactivates the item → **THEN** `is_active = false`, `deleted_at`, `deleted_by` set; no physical deletion

### RCD7: Composite Foreign Key Integrity

<!-- source: proposal.md §Data Model Overview, §Integration Points; constitution §8 -->
All cross-table foreign keys MUST use the composite pattern `(company_id, target_id)` matching the conventions established by catalog (migration 00004), inventory (migration 00005), and purchasing (migration 00006) domains. This prevents cross-tenant reference spoofing at the database level.

| Source Table | FK Columns | Target Table | Target Columns | Nullable |
|---|---|---|---|---|
| `customers` | `(company_id)` | `companies` | `(id)` | No |
| `customer_requests` | `(company_id, customer_id)` | `customers` | `(company_id, id)` | No |
| `customer_requests` | `(company_id, variant_id)` | `product_variants` | `(company_id, id)` | Yes |
| `preorders` | `(company_id, customer_id)` | `customers` | `(company_id, id)` | No |
| `preorders` | `(company_id, branch_id)` | `branches` | `(company_id, id)` | No |
| `preorder_items` | `(company_id, preorder_id)` | `preorders` | `(company_id, id)` | No |
| `preorder_items` | `(company_id, variant_id)` | `product_variants` | `(company_id, id)` | No |

All composite foreign keys MUST use PostgreSQL `REFERENCES` clause with matching column pairs. The `customer_requests(company_id, variant_id)` FK MUST permit NULL via the `MATCH SIMPLE` default (nullable FK behavior).

- **GIVEN** customer_requests row with `company_id = X, customer_id = Y` → **WHEN** no customer exists with `company_id = X, id = Y` → **THEN** FK constraint rejects
- **GIVEN** preorder_items row with `company_id = X, preorder_id = Y` → **WHEN** preorder belongs to different company → **THEN** composite FK rejects
- **GIVEN** customer_requests row with `company_id = X, variant_id = NULL` → **WHEN** inserted → **THEN** FK not enforced on NULL (standard PostgreSQL behavior)
- **GIVEN** preorder_items row with `variant_id = NULL` → **WHEN** inserted → **THEN** rejected (NOT NULL column constraint, not FK)

### RCD8: RLS Multi-Tenant Isolation

<!-- source: proposal.md §Security/RLS Approach; constitution §8, §9; project-architecture spec R3 -->
All four tables MUST enforce RLS with `company_id = get_company_id()` patterns matching catalog, inventory, and purchasing domains. RLS policies MUST follow the foundation pattern established by migration 00003.

| Role | `customers` | `customer_requests` | `preorders` | `preorder_items` |
|---|---|---|---|---|
| Admin | Read/Write | Read/Write | Read/Write | Read/Write |
| Cashier | Read | Read | Read (branch-scoped) | Read (branch-scoped) |
| Unauthenticated | Zero rows | Zero rows | Zero rows | Zero rows |
| Service role | ALL bypass | ALL bypass | ALL bypass | ALL bypass |

Admin INSERT and UPDATE policies MUST check `company_id = get_company_id() AND is_admin()`. Cashier SELECT policies MUST filter by `company_id = get_company_id()`. No DELETE policies SHALL exist on any table — logical deletion only.

- **GIVEN** admin for company A → **WHEN** querying `customers` → **THEN** sees only company A rows; company B rows invisible
- **GIVEN** admin for company A → **WHEN** inserting into `customers` → **THEN** `company_id = A` enforced by RLS policy
- **GIVEN** cashier for company A → **WHEN** querying `customer_requests` → **THEN** sees only company A rows; cannot insert/update/delete
- **GIVEN** unauthenticated → **WHEN** querying any table → **THEN** zero rows returned
- **GIVEN** service role → **WHEN** accessing any table → **THEN** ALL bypass (RLS not enforced)
- **GIVEN** any role → **WHEN** attempting DELETE on any table → **THEN** rejected (no DELETE policy)

### RCD9: Cashier Branch Scoping for Preorders

<!-- source: proposal.md §Security/RLS Approach §Key RLS decisions; constitution §8; project-architecture spec R3 -->
Cashier SELECT on `preorders` MUST additionally filter by `branch_id` matching the cashier's assigned branch via `get_user_branch_id()` or `branch_users` lookup. Cashier SELECT on `preorder_items` MUST be scoped to items whose parent `preorder` belongs to the cashier's branch (via a JOIN or EXISTS subquery in the RLS policy). Admin SELECT on preorders and preorder_items SHALL NOT be branch-scoped — admin sees all branches within their company.

- **GIVEN** cashier assigned to branch B1 → **WHEN** querying `preorders` → **THEN** sees only preorders with `branch_id = B1`; branch B2 preorders invisible
- **GIVEN** cashier assigned to branch B1 → **WHEN** querying `preorder_items` → **THEN** sees only items whose parent preorder has `branch_id = B1`
- **GIVEN** admin → **WHEN** querying `preorders` → **THEN** sees preorders from all branches within their company
- **GIVEN** cashier assigned to branch B1 → **WHEN** querying `customers` or `customer_requests` → **THEN** sees all company rows (customers and requests are NOT branch-scoped)

### RCD10: SDK + RLS Mutation Boundary (V1)

<!-- source: proposal.md §Approach, §Open Decisions §1; constitution §2, §9 -->
V1 MUST use SDK + RLS for all mutations in this domain. NO Edge Functions, NO RPCs, NO SECURITY DEFINER functions SHALL be created for `customers`, `customer_requests`, `preorders`, or `preorder_items` in V1. This is constitutionally permitted under R2 because customer data and preorders without stock commitment are not critical ops — they do not touch money, inventory, or collections.

Mutations are performed by admin via SDK `insert()` / `update()` calls, with RLS enforcing `company_id = get_company_id() AND is_admin()`. Cashier role has SELECT only on all four tables.

If a future domain (e.g., stock reservation activation) introduces inventory mutation during preorder confirmation, the mutation boundary MUST be re-evaluated and EF→RPC enforcement MAY be added at that time.

- **GIVEN** V1 → **WHEN** admin inserts a customer → **THEN** mutation via SDK + RLS; no EF or RPC involved
- **GIVEN** V1 → **WHEN** admin updates a preorder status → **THEN** mutation via SDK + RLS; no EF or RPC involved
- **GIVEN** V1 → **WHEN** inspecting `supabase/functions/` → **THEN** no `customers/`, `customer-requests/`, `preorders/`, or `preorder-items/` directories exist
- **GIVEN** V1 → **WHEN** inspecting `supabase/migrations/` → **THEN** migration 00007 contains no `CREATE OR REPLACE FUNCTION` (RPC) statements for this domain

### RCD11: V1 Inventory Non-Integration

<!-- source: proposal.md §Integration Points §With Inventory, §Non-Goals; exploration.md §Integration Points §Inventory -->
V1 preorders MUST NOT commit inventory. The following inventory operations are explicitly PROHIBITED for V1 preorder workflows and MUST NOT be referenced, called, or triggered by any artifact in this change:

- Calling `reserve_stock()` or any inventory reservation RPC
- Calling `release_reservation()` or any inventory release RPC
- Modifying `stock_lots`, `stock_movements`, or `v_stock_available`
- Creating `stock_reservations` rows

Preorders in V1 are demand signals only. Inventory reservation RPCs in the inventory domain remain V1 rejection stubs and are NOT called by this domain. Preorder creation, confirmation, fulfilment, and cancellation have zero effect on inventory quantities.

When stock reservations are activated in a future domain, preorder confirmation MAY trigger reservation via a migration that adds RPC-enforced state machine logic. That integration point is acknowledged here for forward compatibility but is explicitly OUT of V1.

- **GIVEN** admin creates preorder in `draft` → **WHEN** committed → **THEN** `v_stock_available` unchanged; no `stock_movements` row created
- **GIVEN** admin confirms preorder (`draft → confirmed`) → **WHEN** committed → **THEN** no `reserve_stock()` call; inventory quantities unchanged
- **GIVEN** admin cancels preorder (`draft → cancelled`) → **WHEN** committed → **THEN** no `release_reservation()` call (no reservation was made)
- **GIVEN** migration 00007 applied → **WHEN** reviewing migration SQL → **THEN** no reference to `stock_lots`, `stock_movements`, `reserve_stock`, `release_reservation`, or `stock_reservations`
- **GIVEN** V1 → **WHEN** `reserve_stock()` is called manually from any context → **THEN** inventory domain returns V1 rejection stub response; customers-demand-domain does not call it

### RCD12: Preorder Status Lifecycle Enforcement

<!-- source: proposal.md §Preorder Status Lifecycle, §Acceptance Criteria; exploration.md §Workflow -->
The `preorders.status` column MUST be constrained to `CHECK (status IN ('draft', 'confirmed', 'fulfilled', 'cancelled'))`. V1 enforcement is schema-level only — the CHECK constraint rejects invalid literal values but does NOT prevent semantically invalid transitions (e.g., `fulfilled → cancelled` IS prevented by CHECK since the transition sets status to `'cancelled'` which is NOT `'fulfilled'`, but direct assignment of invalid values like `'shipped'` is blocked). 

Wait — actually, `fulfilled → cancelled` is NOT prevented by the CHECK constraint alone, because setting `status = 'cancelled'` when current status is `'fulfilled'` passes the CHECK (both are valid enum values). The prohibition is a BUSINESS RULE documented here for implementers. In V1, no server-side state machine prevents `fulfilled → cancelled`. When stock reservation is activated in a future domain, an RPC-enforced state machine with transition validation MUST be added.

- **GIVEN** preorder insertion or update → **WHEN** `status` set to value outside `('draft', 'confirmed', 'fulfilled', 'cancelled')` → **THEN** CHECK constraint rejects
- **GIVEN** preorder in `draft` → **WHEN** admin updates `status = 'confirmed'` → **THEN** allowed; CHECK constraint passes
- **GIVEN** preorder in `confirmed` → **WHEN** admin updates `status = 'fulfilled'` → **THEN** allowed; CHECK constraint passes
- **GIVEN** preorder in `draft` or `confirmed` → **WHEN** admin updates `status = 'cancelled'` → **THEN** allowed; CHECK constraint passes
- **GIVEN** preorder in `fulfilled` → **WHEN** admin updates `status = 'cancelled'` → **THEN** CHECK constraint passes (both values valid); business rule PROHIBITS this transition — implementers MUST NOT perform this transition; future domain MUST add RPC enforcement

### RCD13: Customer Request Status Enforcement

<!-- source: proposal.md §Data Model Overview §customer_requests, §Acceptance Criteria; exploration.md §Suggested Fields §customer_requests -->
The `customer_requests.status` column MUST be constrained to `CHECK (status IN ('pending', 'resolved', 'cancelled'))`. Status transitions occur via SDK UPDATE by admin. No server-side state machine enforcement in V1.

- **GIVEN** customer request insertion or update → **WHEN** `status` set to value outside `('pending', 'resolved', 'cancelled')` → **THEN** CHECK constraint rejects
- **GIVEN** request in `pending` → **WHEN** admin updates `status = 'resolved'` → **THEN** allowed via SDK UPDATE
- **GIVEN** request in `pending` → **WHEN** admin updates `status = 'cancelled'` → **THEN** allowed via SDK UPDATE
- **GIVEN** request in `resolved` → **WHEN** admin updates `status = 'pending'` → **THEN** allowed via SDK UPDATE (reopening permitted in V1; no state machine enforcement)

### RCD14: Audit Trail and Triggers

<!-- source: proposal.md §Data Model Overview, §Security/RLS Approach; catalog spec RC3; inventory spec RI2 -->
All four tables MUST use the `set_updated_at()` trigger from the shared migration foundation. `created_by` and `updated_by` MUST be populated on INSERT and UPDATE respectively via `auth.uid()`. `deleted_at` MUST be set to `NOW()` and `deleted_by` to `auth.uid()` on logical deletion of `customers`, `customer_requests`, `preorders`, and `preorder_items`.

- **GIVEN** any row inserted → **WHEN** `created_at` and `created_by` → **THEN** populated automatically
- **GIVEN** any row updated → **WHEN** `updated_at` → **THEN** set to transaction timestamp via `set_updated_at()` trigger
- **GIVEN** customer deactivated via `is_active = false` → **WHEN** committed → **THEN** `deleted_at = NOW()`, `deleted_by = auth.uid()`
- **GIVEN** `preorder_items` row → **WHEN** inspected → **THEN** `is_active`, `deleted_at`, and `deleted_by` columns exist and support logical deletion without physical DELETE

### RCD15: Migration Idempotency

<!-- source: proposal.md §Approach, §Acceptance Criteria; project-architecture spec R7, R8 -->
Migration `00007_customers_demand_domain.sql` MUST apply idempotently as part of `supabase db reset` alongside migrations 00001 through 00006. The migration MUST create all four tables with composite unique constraints, composite foreign keys, CHECK constraints, and `set_updated_at()` triggers. It MUST create indexes on `company_id` and all FK columns. It MUST enable RLS and create all required policies. The migration MUST NOT modify any existing catalog, inventory, or purchasing schema objects (migrations 00004, 00005, 00006).

- **GIVEN** `supabase db reset` → **WHEN** migrations 00001–00007 applied in order → **THEN** all four tables, constraints, indexes, triggers, and RLS policies exist; no errors
- **GIVEN** migration 00007 applied → **WHEN** `supabase db reset` re-applied → **THEN** idempotent; no duplicate object errors
- **GIVEN** migration 00007 applied → **WHEN** inspecting catalog, inventory, or purchasing tables → **THEN** schema unchanged (no columns added, no triggers modified, no RLS altered)

### RCD16: Test Requirements

<!-- source: proposal.md §Acceptance Criteria; project-architecture spec R8; catalog spec RC20; inventory spec RI11; purchasing spec RP13 -->
pgTAP tests MUST cover all constraints and RLS behaviors for the four new tables. No Deno.test (Edge Function tests) are required for this V1 domain — there are no Edge Functions or RPCs.

pgTAP test coverage MUST include:

- **RLS isolation**: admin sees/writes own-company rows on all 4 tables; cashier read-only on all 4 tables; cashier branch scoping on `preorders` and `preorder_items`; unauthenticated returns zero rows on all 4 tables; cross-tenant invisibility verified
- **Composite unique constraints**: `(company_id, id)` on all 4 tables; `(company_id, slug)` on `customers`
- **Composite FK integrity**: all 7 composite FK references in RCD7 validated with `company_id` scope; cross-tenant FK rejection tested
- **CHECK constraints**: `preorders.status` IN valid values with invalid value rejection; `customer_requests.status` IN valid values with invalid value rejection
- **Nullable acceptance**: `customer_requests.variant_id` accepts NULL; `preorder_items.variant_id` rejects NULL
- **RLS policy absence**: no DELETE policy exists on any of the 4 tables
- **Trigger presence**: `set_updated_at()` trigger active on all 4 tables
- **RLS policy counts**: each table has expected number of policies matching the role matrix in RCD8

- **GIVEN** `supabase test db` → **THEN** all pgTAP tests pass with zero failures
- **GIVEN** V1 → **WHEN** running `deno test` → **THEN** no EF tests exist for this domain; test runner MAY report zero tests or skip

### RCD17: V1 Domain Boundaries and Exclusions

<!-- source: proposal.md §Non-Goals, §Scope §Out of Scope; exploration.md §V1 Scope -->
The following features are explicitly OUT of V1 scope for this domain and MUST NOT be included in migration `00007` or any artifact produced by this change:

- Stock reservation activation (`reserve_stock()`, `release_reservation()`, `stock_reservations`)
- Preorder → inventory commitment (preorders do not modify `stock_lots`, `stock_movements`, or `v_stock_available`)
- Layaway / apartados workflows
- Budgets, quotes, or quotations (cotizaciones)
- Purchase suggestion engine (future dashboard-reports domain)
- Customer credit balances (credit-payments-domain, domain #8)
- Edge Functions or RPCs for this domain in V1
- Preorder number auto-generation (the `preorder_number` column exists, but automatic generation is out of V1 scope)
- Frontend / UI

Customer requests are later inputs to purchase suggestions. `customers` is a prerequisite for future credit-payments (domain #8). Both integration points are acknowledged for forward compatibility but are OUT of V1 scope.

- **GIVEN** migration 00007 → **WHEN** inspecting SQL → **THEN** `preorder_number` exists as a required caller-provided value, with no auto-generation, no reservation logic, no inventory mutation, and no RPC definitions
- **GIVEN** V1 → **WHEN** `supabase/functions/` inspected → **THEN** no directories for `customers/`, `customer-requests/`, `preorders/`, or `preorder-items/`
- **GIVEN** V1 → **WHEN** `preorders.status` transitions to `confirmed` → **THEN** no inventory reservation triggered; no stock commitment

---

## Design Decisions

### DCD1: SDK + RLS Mutation Boundary for V1

<!-- source: proposal.md §Open Decisions §1; constitution §2, §9 -->
Customer data and preorder mutations do not touch money, inventory, or collections. Per constitution R2, non-critical ops MAY use SDK + RLS. Admin role performs all mutations via Supabase SDK `insert()` / `update()` with RLS enforcing `company_id = get_company_id() AND is_admin()`. When stock reservation is activated in a future domain and preorder confirmation triggers inventory mutation, the mutation boundary SHALL be re-evaluated and EF→RPC enforcement MAY be added at that time.

### DCD2: Nullable `variant_id` on Customer Requests

<!-- source: proposal.md §Open Decisions §2; exploration.md §Integration Points §Catalog -->
`customer_requests.variant_id` is nullable to support requests for products not yet in the catalog. A NULL `variant_id` means "product not catalogued." This is simpler than adding a separate `requested_product_description` TEXT column. If uncatalogued requests become common, a TEXT column MAY be added in a future migration without breaking existing data. This decision matches the proposal recommendation.

### DCD3: Nullable `unit_price` on Preorder Items

<!-- source: proposal.md §Open Decisions §3 -->
`preorder_items.unit_price` is nullable because the sale price may not be known at preorder time. V1 preorders are demand signals only — the actual price is set at sale time in the future pos-sales-domain. This decision matches the proposal recommendation.

### DCD4: Preorder Items Have Independent Logical Deletion

<!-- source: proposal.md §Open Decisions §5, §Risks and Mitigations -->
`preorder_items` have independent logical deletion columns (`is_active`, `deleted_at`, `deleted_by`) to match the final design decision and the purchase-order item pattern from migration 00006. The RLS SELECT policy on `preorder_items` MUST branch-scope cashier access through the parent `preorders` row, but it does not need to filter by parent `is_active` in V1.

### DCD5: V1 Preorders Are Demand Signals Only

<!-- source: proposal.md §Non-Goals, §Integration Points §With Inventory -->
Preorders in V1 do not commit or reserve inventory. They are demand signals that capture customer intent-to-buy. Inventory reservation RPCs (`reserve_stock()`, `release_reservation()`) remain V1 rejection stubs in the inventory domain and are NOT called by this domain. When stock reservations are activated in a future domain, preorder confirmation workflow MUST be re-designed with RPC-enforced state machine and inventory integration.

### DCD6: Open Decisions Deferred

<!-- source: proposal.md §Open Decisions -->
| # | Decision | Resolution | Spec Impact |
|---|---|---|---|
| 1 | Edge Functions for customer/preorder mutations | RESOLVED: SDK + RLS for V1 | RCD10, DCD1 |
| 2 | `customer_requests.variant_id` nullable vs TEXT field | RESOLVED: nullable `variant_id` | RCD4, DCD2 |
| 3 | `preorder_items.unit_price` nullable | RESOLVED: nullable | RCD6, DCD3 |
| 4 | Preorder number auto-generation | RESOLVED: caller-provided `preorder_number`; auto-generation deferred | RCD5, RCD17 |
| 5 | `preorder_items` logical deletion columns | RESOLVED: independent logical deletion columns | RCD6, DCD4 |

---

## Cross-Domain Touchpoints

| Source Table | FK Target | Composite FK | Domain |
|---|---|---|---|
| `customers` | `companies(id)` | `(company_id, id)` | Bootstrap |
| `customer_requests` | `customers(id)`, `product_variants(id)` | `(company_id, customer_id)`, `(company_id, variant_id)` — nullable | Customers → Catalog |
| `preorders` | `customers(id)`, `branches(id)` | `(company_id, customer_id)`, `(company_id, branch_id)` | Customers → Bootstrap |
| `preorder_items` | `preorders(id)`, `product_variants(id)` | `(company_id, preorder_id)`, `(company_id, variant_id)` | Customers → Catalog |

No RPC call chain exists in V1 (no RPCs in this domain). Future integration point: preorder confirmation MAY call inventory `reserve_stock()` when stock reservation is activated.

Customer requests are future inputs to purchase suggestions (dashboard-reports domain). Customer master data is a prerequisite for credit balances (credit-payments domain #8).

---

## Non-Goals

- Stock reservation activation and inventory commitment
- Layaway / apartados workflows
- Budgets, quotes, quotations (cotizaciones)
- Purchase suggestion engine
- Customer credit balances and payment tracking
- Edge Functions or RPCs for this domain in V1
- Preorder number auto-generation
- Frontend / UI
