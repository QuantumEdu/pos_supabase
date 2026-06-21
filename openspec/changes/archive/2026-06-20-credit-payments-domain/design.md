# Design: Credit Payments Domain

## Technical Approach

Trigger-seeded, RPC-maintained `customer_balances` (resolves R11 #2). An AFTER INSERT trigger on `payments WHERE payment_method='credit'` atomically seeds one balance row per `(company_id, sale_id)` when a credit payment is inserted — `create_sale_transaction` remains unaware. A second trigger on `sales AFTER UPDATE (status)` transitions balances to `'cancelled'`. The `register_customer_payment_transaction()` RPC processes abonos under `FOR UPDATE` lock, updating `paid_amount` and status. The `register-payment` Edge Function follows the project's 8-step critical-op pattern via `validateAuth` → Zod → RPC → return.

## Architecture Decisions

### Decision D1: Generated Column for remaining_amount

| Option | Tradeoff | Decision |
|--------|----------|----------|
| `NUMERIC(14,2) GENERATED ALWAYS AS (total_amount - paid_amount) STORED` | Always correct; no stale data risk; slightly slower INSERT | ✅ Chosen |
| Application-maintained column | Faster writes but race-prone with concurrent abonos | ❌ Rejected |
| View computed at read time | No storage but full scan per query | ❌ Rejected |

**Rationale**: `STORED` generated column guarantees `remaining_amount = total_amount - paid_amount` at all times, eliminating stale-balance bugs under concurrent abonos. Matches RCP1.

### Decision D2: Trigger-seeded balance from payments (not from sales)

| Option | Tradeoff | Decision |
|--------|----------|----------|
| AFTER INSERT trigger on `payments WHERE payment_method='credit'` | Atomic with sale transaction; no cross-domain RPC calls | ✅ Chosen |
| RPC call inside `create_sale_transaction` | Tighter coupling; pos-sales must know about credit-payments | ❌ Rejected |
| Application-layer seeding after sale creation | Not atomic; race condition window | ❌ Rejected |

**Rationale**: The trigger fires inside the same transaction as `create_sale_transaction`'s payment inserts. Multiple credit payment rows for a mixed-payment sale are aggregated by `(company_id, sale_id)` into one balance row via `ON CONFLICT DO UPDATE`. pos-sales code is untouched.

### Decision D3: Cancellation trigger transitions regardless of abono state

| Option | Tradeoff | Decision |
|--------|----------|----------|
| Transition balance to `'cancelled'` unconditionally | Simple; no partial-reversal logic | ✅ Chosen (V1) |
| Reverse abonos then cancel | Complex; requires abono ledger rewriting | ❌ Deferred to V2 |

**Rationale**: V1 scope excludes reversal of individual abonos. The trigger simply sets `status = 'cancelled'` on the linked balance. Callable RPC rejects abonos on cancelled balances (RCP5).

### Decision D4: FOR UPDATE lock in abono RPC

| Option | Tradeoff | Decision |
|--------|----------|----------|
| `SELECT ... FOR UPDATE` on `customer_balances` row | Serializes concurrent abonos per balance; correct | ✅ Chosen |
| Optimistic concurrency (version column) | Requires retry logic; over-engineering for MVP | ❌ Rejected |
| No locking | Lost updates under concurrency | ❌ Rejected |

**Rationale**: `FOR UPDATE` inside the SECURITY DEFINER transaction locks the balance row for the duration of the abono, preventing lost-update race conditions (RCP4).

### Decision D5: EF follows critical-op pattern (R2)

| Option | Tradeoff | Decision |
|--------|----------|----------|
| Shared handler pattern (like `cash-session`) | Proven handler abstraction; Zod + validateAuth + RPC dispatch | ✅ Chosen |
| Standalone EF with inline auth/error | More code duplication | ❌ Rejected |

**Rationale**: The cash-session handler pattern (`validateAuth` → Zod → inject `actor_user_id`/`company_id` → RPC → return) is established. The `register-payment` EF will use the same `_shared/auth.ts`, `_shared/types.ts`, and a new `_shared/credit_payment_handler.ts` following the identical 8-step flow.

## Data Flow

```
create_sale_transaction RPC
  └─ INSERT INTO payments (payment_method='credit')
       └─ trg_seed_customer_balance (AFTER INSERT)
            └─ INSERT INTO customer_balances
                 (ON CONFLICT DO UPDATE — aggregates multiple credit rows)

register_customer_payment_transaction RPC
  └─ SELECT ... FOR UPDATE on customer_balances
  └─ INSERT INTO customer_payments
  └─ UPDATE customer_balances SET paid_amount, status

cancel_sale_transaction RPC
  └─ UPDATE sales SET status='cancelled'
       └─ trg_cancel_customer_balance (AFTER UPDATE)
            └─ UPDATE customer_balances SET status='cancelled'

register-payment EF (8-step)
  1. CORS preflight → return 200
  2. validateAuth → AuthContext {user, companyId, role}
  3. Check role ∈ ['admin'] (step 4)
  4. Zod.parse body → RegisterCustomerPaymentRequest
  5. Inject actor_user_id + company_id into RPC payload
  6. service_role.rpc('register_customer_payment_transaction', {p})
  7. (audit logging — future: R12)
  8. Return EFResult<RegisterCustomerPaymentResult>
```

## File Changes

| File | Action | Description |
|------|--------|-------------|
| `supabase/migrations/00010_credit_payments_domain.sql` | Create | Tables, triggers, RPC, RLS, grants |
| `supabase/functions/_shared/credit_payment_handler.ts` | Create | Shared handler for register-payment EF |
| `supabase/functions/_shared/credit_payment_schemas.ts` | Create | Zod schemas + TypeScript types |
| `supabase/functions/register-payment/index.ts` | Create | Edge Function entry point |
| `supabase/tests/test_credit_payments_constraints.sql` | Create | pgTAP: table constraints, CHECK, UNIQUE, composite FK |
| `supabase/tests/test_credit_payments_rpcs.sql` | Create | pgTAP: seeding trigger, cancellation trigger, abono RPC |
| `supabase/tests/test_credit_payments_rls.sql` | Create | pgTAP: RLS policies |
| `supabase/functions/_test/credit_payment_ef_test.ts` | Create | Deno test: 8-step EF validation |

## Interfaces / Contracts

### customer_balances table

```sql
CREATE TABLE public.customer_balances (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id       UUID NOT NULL REFERENCES public.companies(id),
  sale_id          UUID NOT NULL,
  customer_id      UUID NOT NULL,
  total_amount     NUMERIC(14,2) NOT NULL CHECK (total_amount > 0),
  paid_amount      NUMERIC(14,2) NOT NULL DEFAULT 0 CHECK (paid_amount >= 0),
  remaining_amount NUMERIC(14,2) GENERATED ALWAYS AS (total_amount - paid_amount) STORED
                       CHECK (remaining_amount >= 0),
  status           TEXT NOT NULL DEFAULT 'pending'
                       CHECK (status IN ('pending','partial','paid','cancelled')),
  is_active        BOOLEAN NOT NULL DEFAULT TRUE,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_by       UUID,
  updated_by       UUID,
  deleted_at       TIMESTAMPTZ,
  deleted_by       UUID
);
-- Composite unique: (company_id, id)  → enables composite FK targets
-- Business unique: (company_id, sale_id) → one balance per credit sale
```

### customer_payments table

```sql
CREATE TABLE public.customer_payments (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id      UUID NOT NULL REFERENCES public.companies(id),
  balance_id      UUID NOT NULL,
  amount          NUMERIC(14,2) NOT NULL CHECK (amount > 0),
  payment_method  TEXT NOT NULL CHECK (payment_method IN ('cash','card','transfer')),
  reference       TEXT,
  is_active       BOOLEAN NOT NULL DEFAULT TRUE,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_by      UUID,
  updated_by      UUID,
  deleted_at      TIMESTAMPTZ,
  deleted_by      UUID
);
-- Append-only: prevent UPDATE and DELETE via triggers
```

### RPC: register_customer_payment_transaction

```sql
CREATE OR REPLACE FUNCTION public.register_customer_payment_transaction(p JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_company_id    UUID;
  v_actor_user_id UUID;
  v_balance_id    UUID;
  v_amount        NUMERIC(14,2);
  v_payment_method TEXT;
  v_reference     TEXT;
  v_balance       public.customer_balances%ROWTYPE;
  v_payment_id    UUID;
BEGIN
  v_company_id    := (p->>'company_id')::UUID;
  v_actor_user_id := (p->>'actor_user_id')::UUID;
  v_balance_id    := (p->>'balance_id')::UUID;
  v_amount        := (p->>'amount')::NUMERIC;
  v_payment_method := p->>'payment_method';
  v_reference     := p->>'reference';

  -- Validations
  IF v_company_id IS NULL OR v_actor_user_id IS NULL OR v_balance_id IS NULL THEN
    RAISE EXCEPTION 'company_id, actor_user_id, and balance_id are required';
  END IF;
  IF v_amount IS NULL OR v_amount <= 0 THEN
    RAISE EXCEPTION 'amount must be greater than zero';
  END IF;
  IF v_payment_method NOT IN ('cash','card','transfer') THEN
    RAISE EXCEPTION 'payment_method must be cash, card, or transfer';
  END IF;

  -- Lock balance row
  SELECT * INTO v_balance
    FROM public.customer_balances
   WHERE id = v_balance_id
     AND company_id = v_company_id
     AND is_active = TRUE
   FOR UPDATE;

  IF v_balance.id IS NULL THEN
    RAISE EXCEPTION 'Customer balance not found or not active';
  END IF;
  IF v_balance.status IN ('paid','cancelled') THEN
    RAISE EXCEPTION 'Cannot add payment to a % balance', v_balance.status;
  END IF;
  IF v_amount > v_balance.remaining_amount THEN
    RAISE EXCEPTION 'Payment amount (%) exceeds remaining balance (%)', v_amount, v_balance.remaining_amount;
  END IF;

  -- Insert payment
  INSERT INTO public.customer_payments (company_id, balance_id, amount, payment_method, reference, created_by, updated_by)
  VALUES (v_company_id, v_balance_id, v_amount, v_payment_method, v_reference, v_actor_user_id, v_actor_user_id)
  RETURNING id INTO v_payment_id;

  -- Update balance
  UPDATE public.customer_balances
     SET paid_amount = paid_amount + v_amount,
         status = CASE
           WHEN paid_amount + v_amount >= total_amount THEN 'paid'
           ELSE 'partial'
         END,
         updated_by = v_actor_user_id
   WHERE id = v_balance_id;

  RETURN jsonb_build_object(
    'success', true,
    'data', jsonb_build_object(
      'payment_id', v_payment_id,
      'balance_id', v_balance_id,
      'amount_paid', v_amount,
      'new_status', CASE
        WHEN v_balance.paid_amount + v_amount >= v_balance.total_amount THEN 'paid'
        ELSE 'partial'
      END
    )
  );
END;
$$;
```

### Trigger: trg_seed_customer_balance

```sql
CREATE OR REPLACE FUNCTION public.seed_customer_balance()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.payment_method = 'credit' THEN
    INSERT INTO public.customer_balances (company_id, sale_id, customer_id, total_amount, created_by, updated_by)
    SELECT NEW.company_id, NEW.sale_id, s.customer_id, NEW.amount, NEW.created_by, NEW.updated_by
      FROM public.sales s
     WHERE s.id = NEW.sale_id
       AND s.company_id = NEW.company_id
       AND s.is_active = TRUE
    ON CONFLICT (company_id, sale_id) DO UPDATE
      SET total_amount = customer_balances.total_amount + EXCLUDED.total_amount,
          updated_by = EXCLUDED.updated_by;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;
```

### Trigger: trg_cancel_customer_balance

```sql
CREATE OR REPLACE FUNCTION public.cancel_customer_balance()
RETURNS TRIGGER AS $$
BEGIN
  IF OLD.status <> 'cancelled' AND NEW.status = 'cancelled' THEN
    UPDATE public.customer_balances
       SET status = 'cancelled',
           updated_by = NEW.updated_by
     WHERE sale_id = NEW.id
       AND company_id = NEW.company_id
       AND status NOT IN ('cancelled');
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;
```

### EF: register-payment — Request/Response

```typescript
// Zod schema
const RegisterCustomerPaymentRequest = z.object({
  balance_id: z.string().uuid(),
  amount: z.number().positive("amount must be greater than zero"),
  payment_method: z.enum(["cash", "card", "transfer"]),
  reference: z.string().trim().min(1).optional(),
});

type RegisterCustomerPaymentResult = {
  payment_id: string;
  balance_id: string;
  amount_paid: number;
  new_status: "pending" | "partial" | "paid";
};
```

## Testing Strategy

| Layer | What to Test | Approach |
|-------|-------------|----------|
| pgTAP constraints | Table CHECK, UNIQUE `(company_id, sale_id)`, composite FK, generated column | Insert valid/invalid rows; assert violations |
| pgTAP triggers | Seed trigger fires on `payment_method='credit'` only; aggregates multiple credits; no seed on non-credit; cancel trigger transitions balance | Setup company/sale/payment; verify `customer_balances` row |
| pgTAP RPC | Happy path: pending→partial→paid; overpayment rejection; paid/cancelled rejection; amount≤0 rejection; FOR UPDATE serialization (two concurrent sessions) | Transaction-based tests with `dbms_lock` or `pg_sleep` for concurrency |
| pgTAP RLS | Company-scoped SELECT; admin INSERT/UPDATE; cross-company invisible; unauthenticated sees zero; no DELETE policy | SET role/claims; assert row visibility |
| Deno test EF | Auth→role validation→Zod input→RPC invocation→result; unauthenticated reject; non-admin reject | Mock `validateAuth` + `createServiceClient` following cash-session pattern |

## Migration / Rollout

Migration 00010 creates `customer_balances`, `customer_payments`, two triggers (on `payments` and `sales`), one RPC, RLS policies, and grants. Triggers on 00009 tables (`payments`, `sales`) are created by and owned by the 00010 migration. Rollback: `DROP` both tables, triggers, functions, RLS policies. No modification to 00009 schema objects. The `payments` table already blocks UPDATE/DELETE via `prevent_child_mutation()` trigger, so the seed trigger only fires on INSERT — no conflict with append-only Policy.

## Open Questions

- [ ] Should `customer_payments.payment_method` exclude `'credit'`? (Spec says abonos use cash/card/transfer — confirm in implementation)
- [ ] Audit logging for abonos (R12) — placeholder in EF step 7 for now; full implementation deferred to a future change