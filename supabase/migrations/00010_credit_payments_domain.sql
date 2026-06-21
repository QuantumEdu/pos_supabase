-- Migration: 00010_credit_payments_domain
-- Source: credit-payments-domain spec (RCP1–RCP8), design (D1–D5)
-- Phase 1 — SQL foundation only (PR1 slice)
-- Resolves project-architecture R11 #2 ("trigger-seeded, RPC-maintained table")
--
-- Creates: customer_balances, customer_payments tables;
--          seed + cancellation triggers on pos-sales tables (payments, sales);
--          register_customer_payment_transaction() RPC;
--          RLS policies + grants.
-- Triggers on 00009 tables (payments, sales) are created by and owned by this
-- migration, so dropping 00010 removes them cleanly. No 00009 schema objects
-- are modified.

-- ============================================================================
-- Tables
-- ============================================================================

-- customer_balances: one balance row per credit sale, RPC-maintained
CREATE TABLE IF NOT EXISTS public.customer_balances (
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

COMMENT ON TABLE public.customer_balances IS 'Customer credit-balance master. Trigger-seeded from credit payments, RPC-maintained abonos. Logical deletion only. (source: RCP1, R11 #2)';
COMMENT ON COLUMN public.customer_balances.remaining_amount IS 'STORED generated column = total_amount - paid_amount; always correct under concurrent abonos. (source: D1)';
COMMENT ON COLUMN public.customer_balances.status IS 'pending → partial → paid | cancelled. Lifecycle transitions via RPC (partial/paid) or cancellation trigger (cancelled).';

-- customer_payments: abono records, append-only
CREATE TABLE IF NOT EXISTS public.customer_payments (
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

COMMENT ON TABLE public.customer_payments IS 'Abono (partial payment) records linked to customer_balances. Append-only via RPC. (source: RCP1)';
COMMENT ON COLUMN public.customer_payments.payment_method IS 'Abono tender type: cash | card | transfer. credit excluded (credit denotes the debt, not a repayment).';

-- ============================================================================
-- Indexes
-- ============================================================================

-- Composite unique (company_id, id) — enables composite FK targets
CREATE UNIQUE INDEX IF NOT EXISTS idx_customer_balances_company_id_id
  ON public.customer_balances(company_id, id);

CREATE UNIQUE INDEX IF NOT EXISTS idx_customer_payments_company_id_id
  ON public.customer_payments(company_id, id);

-- Business unique: one balance per credit sale
CREATE UNIQUE INDEX IF NOT EXISTS idx_customer_balances_company_sale
  ON public.customer_balances(company_id, sale_id);

-- Lookup indexes
CREATE INDEX IF NOT EXISTS idx_customer_balances_company_customer
  ON public.customer_balances(company_id, customer_id);

CREATE INDEX IF NOT EXISTS idx_customer_payments_company_balance
  ON public.customer_payments(company_id, balance_id);

-- ============================================================================
-- Composite Foreign Keys
-- (enforce same-company reference integrity for sale + customer links)
-- ============================================================================

-- customer_balances → sales (composite FK on (company_id, sale_id))
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'fk_customer_balances_sale_same_company'
  ) THEN
    ALTER TABLE public.customer_balances
      ADD CONSTRAINT fk_customer_balances_sale_same_company
      FOREIGN KEY (company_id, sale_id) REFERENCES public.sales(company_id, id);
  END IF;
END;
$$;

-- customer_balances → customers (composite FK on (company_id, customer_id))
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'fk_customer_balances_customer_same_company'
  ) THEN
    ALTER TABLE public.customer_balances
      ADD CONSTRAINT fk_customer_balances_customer_same_company
      FOREIGN KEY (company_id, customer_id) REFERENCES public.customers(company_id, id);
  END IF;
END;
$$;

-- customer_payments → customer_balances (composite FK on (company_id, balance_id))
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'fk_customer_payments_balance_same_company'
  ) THEN
    ALTER TABLE public.customer_payments
      ADD CONSTRAINT fk_customer_payments_balance_same_company
      FOREIGN KEY (company_id, balance_id) REFERENCES public.customer_balances(company_id, id);
  END IF;
END;
$$;

-- ============================================================================
-- Append-only protection triggers (match 00008/00009 pattern)
-- ============================================================================

-- customer_balances: logical deletion only (no physical DELETE)
CREATE OR REPLACE FUNCTION public.prevent_customer_balances_delete()
RETURNS TRIGGER AS $$
BEGIN
  RAISE EXCEPTION 'customer_balances uses logical deletion only';
END;
$$ LANGUAGE plpgsql;

-- customer_payments: append-only (no UPDATE, no DELETE; abonos via RPC only)
CREATE OR REPLACE FUNCTION public.prevent_customer_payments_mutation()
RETURNS TRIGGER AS $$
BEGIN
  RAISE EXCEPTION 'customer_payments is append-only via RPC';
END;
$$ LANGUAGE plpgsql;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger WHERE tgname = 'trg_customer_balances_no_delete'
  ) THEN
    CREATE TRIGGER trg_customer_balances_no_delete
      BEFORE DELETE ON public.customer_balances
      FOR EACH ROW EXECUTE FUNCTION public.prevent_customer_balances_delete();
  END IF;
END;
$$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger WHERE tgname = 'trg_customer_payments_no_update'
  ) THEN
    CREATE TRIGGER trg_customer_payments_no_update
      BEFORE UPDATE ON public.customer_payments
      FOR EACH ROW EXECUTE FUNCTION public.prevent_customer_payments_mutation();
  END IF;
END;
$$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger WHERE tgname = 'trg_customer_payments_no_delete'
  ) THEN
    CREATE TRIGGER trg_customer_payments_no_delete
      BEFORE DELETE ON public.customer_payments
      FOR EACH ROW EXECUTE FUNCTION public.prevent_customer_payments_mutation();
  END IF;
END;
$$;

-- updated_at triggers
DO $$
DECLARE
  t TEXT;
BEGIN
  FOREACH t IN ARRAY ARRAY['customer_balances', 'customer_payments']
  LOOP
    IF NOT EXISTS (
      SELECT 1 FROM pg_trigger WHERE tgname = format('set_updated_at_%s', t)
    ) THEN
      EXECUTE format(
        'CREATE TRIGGER set_updated_at_%I BEFORE UPDATE ON public.%I FOR EACH ROW EXECUTE FUNCTION public.set_updated_at()',
        t, t
      );
    END IF;
  END LOOP;
END;
$$;

-- ============================================================================
-- Trigger: trg_seed_customer_balance
-- AFTER INSERT on payments WHERE payment_method='credit'
-- Seeds one customer_balances row per (company_id, sale_id); aggregates
-- multiple credit payment rows via ON CONFLICT DO UPDATE.
-- (source: RCP2, D2)
-- ============================================================================
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
      SET total_amount = public.customer_balances.total_amount + EXCLUDED.total_amount,
          updated_by = EXCLUDED.updated_by;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger WHERE tgname = 'trg_seed_customer_balance'
  ) THEN
    CREATE TRIGGER trg_seed_customer_balance
      AFTER INSERT ON public.payments
      FOR EACH ROW EXECUTE FUNCTION public.seed_customer_balance();
  END IF;
END;
$$;

-- ============================================================================
-- Trigger: trg_cancel_customer_balance
-- AFTER UPDATE on sales WHERE status → 'cancelled'
-- Transitions linked balance(s) to 'cancelled' regardless of abono state (V1).
-- (source: RCP3, D3)
-- ============================================================================
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

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger WHERE tgname = 'trg_cancel_customer_balance'
  ) THEN
    CREATE TRIGGER trg_cancel_customer_balance
      AFTER UPDATE ON public.sales
      FOR EACH ROW EXECUTE FUNCTION public.cancel_customer_balance();
  END IF;
END;
$$;

-- ============================================================================
-- RPC: register_customer_payment_transaction(p JSONB)
-- SECURITY DEFINER. Inserts a customer_payments abono and updates the linked
-- customer_balances row under SELECT ... FOR UPDATE lock. Validates: positive
-- amount, ≤ remaining_amount, balance active and in pending/partial status.
-- (source: RCP4, RCP5, D4)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.register_customer_payment_transaction(p JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_company_id     UUID;
  v_actor_user_id  UUID;
  v_balance_id     UUID;
  v_amount         NUMERIC(14,2);
  v_payment_method TEXT;
  v_reference      TEXT;
  v_balance        public.customer_balances%ROWTYPE;
  v_payment_id     UUID;
BEGIN
  v_company_id     := (p->>'company_id')::UUID;
  v_actor_user_id  := (p->>'actor_user_id')::UUID;
  v_balance_id     := (p->>'balance_id')::UUID;
  v_amount         := (p->>'amount')::NUMERIC;
  v_payment_method := p->>'payment_method';
  v_reference      := p->>'reference';

  -- Required field validation
  IF v_company_id IS NULL OR v_actor_user_id IS NULL OR v_balance_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'code', 'VALIDATION_ERROR',
      'message', 'company_id, actor_user_id, and balance_id are required');
  END IF;
  IF v_amount IS NULL OR v_amount <= 0 THEN
    RETURN jsonb_build_object('success', false, 'code', 'VALIDATION_ERROR',
      'message', 'amount must be greater than zero');
  END IF;
  IF v_payment_method IS NULL OR v_payment_method NOT IN ('cash','card','transfer') THEN
    RETURN jsonb_build_object('success', false, 'code', 'VALIDATION_ERROR',
      'message', 'payment_method must be cash, card, or transfer');
  END IF;

  -- Lock balance row for the duration of this abono (serializes concurrent abonos)
  SELECT * INTO v_balance
    FROM public.customer_balances
   WHERE id = v_balance_id
     AND company_id = v_company_id
     AND is_active = TRUE
   FOR UPDATE;

  IF v_balance.id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'code', 'NOT_FOUND',
      'message', 'Customer balance not found or not active');
  END IF;

  IF v_balance.status IN ('paid','cancelled') THEN
    RETURN jsonb_build_object('success', false, 'code', 'VALIDATION_ERROR',
      'message', 'Cannot add payment to a ' || v_balance.status || ' balance');
  END IF;

  IF v_amount > v_balance.remaining_amount THEN
    RETURN jsonb_build_object('success', false, 'code', 'VALIDATION_ERROR',
      'message', 'Payment amount exceeds remaining balance');
  END IF;

  -- Insert abono
  INSERT INTO public.customer_payments (company_id, balance_id, amount, payment_method, reference, created_by, updated_by)
  VALUES (v_company_id, v_balance_id, v_amount, v_payment_method, v_reference, v_actor_user_id, v_actor_user_id)
  RETURNING id INTO v_payment_id;

  -- Update balance: paid_amount increments; status transitions pending → partial → paid
  UPDATE public.customer_balances
     SET paid_amount = paid_amount + v_amount,
         status = CASE
           WHEN paid_amount + v_amount >= total_amount THEN 'paid'
           ELSE 'partial'
         END,
         updated_by = v_actor_user_id
   WHERE id = v_balance_id;

  -- Refresh snapshot for accurate return new_status
  SELECT * INTO v_balance
    FROM public.customer_balances
   WHERE id = v_balance_id;

  RETURN jsonb_build_object(
    'success', true,
    'data', jsonb_build_object(
      'payment_id', v_payment_id,
      'balance_id', v_balance_id,
      'amount_paid', v_amount,
      'new_paid_amount', v_balance.paid_amount,
      'new_remaining_amount', v_balance.remaining_amount,
      'new_status', v_balance.status
    )
  );
END;
$$;

COMMENT ON FUNCTION public.register_customer_payment_transaction(JSONB) IS 'SECURITY DEFINER abono RPC. Inserts customer_payments row and updates customer_balances under FOR UPDATE lock. (source: RCP4, RCP5, D4)';

-- ============================================================================
-- RLS Policies + Grants
-- Pattern: SELECT own company for authenticated; admin-only INSERT/UPDATE;
--          no DELETE; service_role full bypass.
-- (source: RCP6)
-- ============================================================================

ALTER TABLE public.customer_balances ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.customer_payments ENABLE ROW LEVEL SECURITY;

-- customer_balances: company-scoped SELECT
DROP POLICY IF EXISTS "customer_balances_select_own" ON public.customer_balances;
CREATE POLICY "customer_balances_select_own"
  ON public.customer_balances FOR SELECT
  TO authenticated
  USING (company_id = public.get_company_id());

-- customer_balances: admin-only write
DROP POLICY IF EXISTS "customer_balances_insert_admin" ON public.customer_balances;
CREATE POLICY "customer_balances_insert_admin"
  ON public.customer_balances FOR INSERT
  TO authenticated
  WITH CHECK (company_id = public.get_company_id() AND public.is_admin());

DROP POLICY IF EXISTS "customer_balances_update_admin" ON public.customer_balances;
CREATE POLICY "customer_balances_update_admin"
  ON public.customer_balances FOR UPDATE
  TO authenticated
  USING (company_id = public.get_company_id() AND public.is_admin());

-- customer_balances: service_role full bypass
DROP POLICY IF EXISTS "customer_balances_service_all" ON public.customer_balances;
CREATE POLICY "customer_balances_service_all"
  ON public.customer_balances FOR ALL
  TO service_role
  USING (TRUE)
  WITH CHECK (TRUE);

-- customer_payments: company-scoped SELECT
DROP POLICY IF EXISTS "customer_payments_select_own" ON public.customer_payments;
CREATE POLICY "customer_payments_select_own"
  ON public.customer_payments FOR SELECT
  TO authenticated
  USING (company_id = public.get_company_id());

-- customer_payments: admin-only write
DROP POLICY IF EXISTS "customer_payments_insert_admin" ON public.customer_payments;
CREATE POLICY "customer_payments_insert_admin"
  ON public.customer_payments FOR INSERT
  TO authenticated
  WITH CHECK (company_id = public.get_company_id() AND public.is_admin());

DROP POLICY IF EXISTS "customer_payments_update_admin" ON public.customer_payments;
CREATE POLICY "customer_payments_update_admin"
  ON public.customer_payments FOR UPDATE
  TO authenticated
  USING (company_id = public.get_company_id() AND public.is_admin());

-- customer_payments: service_role full bypass
DROP POLICY IF EXISTS "customer_payments_service_all" ON public.customer_payments;
CREATE POLICY "customer_payments_service_all"
  ON public.customer_payments FOR ALL
  TO service_role
  USING (TRUE)
  WITH CHECK (TRUE);

-- ============================================================================
-- Grants
-- (source: RCP6)
--   authenticated: SELECT + INSERT/UPDATE (admin writes gated by is_admin()
--                  policy; matches customers-demand convention RCD8/RCD10)
--   anon:          SELECT only (read-only browsing)
--   service_role: SELECT + INSERT/UPDATE + EXECUTE (EF write path; RLS bypassed)
--   No DELETE grants — logical deletion only.
-- ============================================================================
GRANT SELECT ON public.customer_balances TO anon, authenticated, service_role;
GRANT INSERT, UPDATE ON public.customer_balances TO authenticated, service_role;

GRANT SELECT ON public.customer_payments TO anon, authenticated, service_role;
GRANT INSERT, UPDATE ON public.customer_payments TO authenticated, service_role;

-- ============================================================================
-- Grant RPC execution to service_role only
-- ============================================================================
REVOKE EXECUTE ON FUNCTION public.register_customer_payment_transaction(JSONB) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.register_customer_payment_transaction(JSONB) TO service_role;