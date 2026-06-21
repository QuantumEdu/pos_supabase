# Credit Payments Domain Specification

## Purpose

Abono (partial payment) tracking and customer credit-balance visibility for multi-tenant SaaS POS. When a sale is paid on credit, the business MUST know who owes what and record payments toward it. This domain seeds a `customer_balances` row atomically from a credit sale payment, processes abonos via an RPC under row lock, transitions balances on sale cancellation, and exposes a `register-payment` Edge Function following the project's critical-op pattern. Resolves project-architecture R11 #2 ("trigger-seeded, RPC-maintained table"). Depends on customers-demand (#5) and pos-sales PR1+PR2 (#6).

## Requirements

### RCP1: Customer Balances Schema

The system MUST create a `customer_balances` table: company-scoped, sale-linked, lifecycle `pending → partial → paid → cancelled`. Columns: `id` (UUID PK), `company_id` (NOT NULL, FK→`companies`), `sale_id` (NOT NULL, composite FK→`sales(company_id,id)`), `customer_id` (NOT NULL, composite FK→`customers`), `total_amount` (NUMERIC(14,2) NOT NULL), `paid_amount` (NUMERIC(14,2) DEFAULT 0), `remaining_amount` (NUMERIC(14,2) generated = `total_amount - paid_amount`), `status` (TEXT NOT NULL DEFAULT 'pending', CHECK IN ('pending','partial','paid','cancelled')), audit + logical-deletion columns. Composite unique `(company_id, id)`; UNIQUE `(company_id, sale_id)` (one balance per sale).

- **GIVEN** a valid credit sale → **WHEN** migration 00010 applied → **THEN** table exists with CHECK, unique, and composite FK constraints
- **GIVEN** a sale → **WHEN** two balance rows inserted for same `(company_id, sale_id)` → **THEN** UNIQUE constraint rejects the second
- **GIVEN** insert/update → **WHEN** `status='foo'` → **THEN** CHECK rejects

### RCP2: Credit Payment Seeding Trigger

The system MUST create a `customer_balances` row automatically via an AFTER INSERT trigger on `payments WHERE payment_method='credit'`. The row MUST have `total_amount = credit amount`, `remaining_amount = total_amount`, `status='pending'`. Multiple credit payment rows for one sale converge into ONE balance row (aggregated by `(company_id, sale_id)`).

- **GIVEN** a sale with a credit payment row → **WHEN** the `payments` INSERT commits → **THEN** a `customer_balances` row exists with `total_amount = credit amount`, `status='pending'`
- **GIVEN** a sale with two credit payment rows (mixed payment) → **WHEN** both inserts commit → **THEN** exactly ONE balance row exists (aggregated)
- **GIVEN** a sale with a non-credit payment only → **WHEN** insert commits → **THEN** no balance row is created

### RCP3: Balance Cancellation Trigger

The system MUST transition the linked balance to `'cancelled'` via an AFTER UPDATE trigger on `sales WHERE status → 'cancelled'`.

- **GIVEN** a credit sale with an active balance → **WHEN** sale `status` updates to `'cancelled'` → **THEN** the linked balance transitions to `'cancelled'`
- **GIVEN** a balance already `'paid'` → **WHEN** sale cancelled → **THEN** trigger transitions balance to `'cancelled'` (V1 does not reverse individual abonos)

### RCP4: Register Customer Payment Transaction RPC

The system MUST provide `register_customer_payment_transaction()` SECURITY DEFINER RPC that inserts a `customer_payments` row and updates the balance under `SELECT ... FOR UPDATE` on `customer_balances`.

- **GIVEN** a balance in `'pending'` or `'partial'` → **WHEN** RPC called with valid abono → **THEN** a `customer_payments` row is created AND `paid_amount`, `remaining_amount`, and `status` update on `customer_balances`
- **GIVEN** `paid_amount + abono < total_amount` → **WHEN** abono applied → **THEN** `status='partial'`
- **GIVEN** `paid_amount + abono = total_amount` → **WHEN** abono applied → **THEN** `status='paid'`, `remaining_amount=0`
- **GIVEN** two concurrent abonos toward the same balance → **WHEN** both RPC calls execute → **THEN** serialized by `FOR UPDATE`; no lost updates; sum of both abonos reflected exactly

### RCP5: Abono Validation

The RPC MUST reject invalid abonos atomically (no row created).

- **GIVEN** an abono exceeding `remaining_amount` → **WHEN** RPC processes it → **THEN** returns error; no `customer_payments` row created
- **GIVEN** a balance in `'paid'` or `'cancelled'` → **WHEN** RPC processes an abono → **THEN** returns error; no row created
- **GIVEN** abono amount ≤ 0 → **WHEN** RPC processes it → **THEN** returns error

### RCP6: Row-Level Security

`customer_balances` and `customer_payments` MUST enforce `company_id = get_company_id()` RLS matching domain conventions.

- **GIVEN** any authenticated user → **WHEN** SELECT → **THEN** only own-company rows visible
- **GIVEN** cashier/other company user → **WHEN** SELECT → **THEN** cross-company rows invisible
- **GIVEN** unauthenticated → **WHEN** SELECT → **THEN** zero rows
- **GIVEN** admin → **WHEN** INSERT/UPDATE → **THEN** write succeeds (`is_admin()` policy)
- **GIVEN** service_role → **WHEN** any operation → **THEN** RLS bypassed
- **GIVEN** any role → **WHEN** DELETE → **THEN** rejected (no DELETE policy; logical deletion only)

### RCP7: Register-Payment Edge Function

The `register-payment` Edge Function MUST follow the 8-step critical-op pattern (R2): validate user → company → branch → role → input → invoke RPC → audit → return result. The frontend MUST NOT call the RPC directly.

- **GIVEN** authenticated admin → **WHEN** POST abono to EF → **THEN** EF validates role/input, invokes `register_customer_payment_transaction()`, writes audit, returns result
- **GIVEN** unauthenticated request → **WHEN** POST to EF → **THEN** rejected at step 1
- **GIVEN** non-admin role → **WHEN** POST to EF → **THEN** rejected at role-validating step

### RCP8: Test Coverage

pgTAP MUST cover schema constraints, trigger seeding/cancellation, RPC happy/edge/concurrency, and RLS isolation. Deno.test MUST cover the EF's 8-step sequence and validation rejections.

- **GIVEN** `supabase test db` → **THEN** all pgTAP tests pass (constraints, triggers, RPC, RLS)
- **GIVEN** `deno test` → **THEN** all EF tests pass (auth, role validation, RPC invocation, audit)