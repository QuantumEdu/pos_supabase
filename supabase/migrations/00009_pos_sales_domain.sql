-- Migration: 00009_pos_sales_domain
-- Source: pos-sales-domain spec/design, Phase 1 — SQL foundation only

-- ============================================================================
-- Helper: next_sale_number — branch-scoped sale numbering
-- ============================================================================
CREATE SEQUENCE IF NOT EXISTS public.sale_number_seq
  INCREMENT BY 1 NO CYCLE;

CREATE OR REPLACE FUNCTION public.next_sale_number(p_company_id UUID, p_branch_id UUID)
RETURNS BIGINT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_seq_name TEXT;
  v_next     BIGINT;
BEGIN
  -- Use a deterministic sequence name per branch so each branch gets its own
  v_seq_name := 'sale_number_seq_' || replace(p_company_id::text, '-', '_')
             || '_' || replace(p_branch_id::text, '-', '_');

  -- Create sequence if it does not exist
  IF NOT EXISTS (
    SELECT 1 FROM pg_class WHERE relname = v_seq_name AND relkind = 'S'
  ) THEN
    EXECUTE format('CREATE SEQUENCE IF NOT EXISTS %I START 1 INCREMENT 1 NO CYCLE', v_seq_name);
  END IF;

  EXECUTE format('SELECT nextval(%L)', v_seq_name) INTO v_next;
  RETURN v_next;
END;
$$;

-- ============================================================================
-- Tables
-- ============================================================================

-- sales: branch-scoped sale header
CREATE TABLE IF NOT EXISTS public.sales (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id        UUID NOT NULL REFERENCES public.companies(id),
  branch_id         UUID NOT NULL,
  cashier_user_id   UUID NOT NULL,
  customer_id       UUID,
  cash_session_id   UUID NOT NULL,
  preorder_id       UUID,
  status            TEXT NOT NULL CHECK (status IN ('active', 'cancelled')),
  subtotal          NUMERIC(12,2) NOT NULL CHECK (subtotal >= 0),
  discount_amount   NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (discount_amount >= 0),
  tax_amount        NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (tax_amount >= 0),
  total             NUMERIC(12,2) NOT NULL CHECK (total >= 0),
  sale_number       BIGINT NOT NULL,
  notes             TEXT,
  is_active         BOOLEAN NOT NULL DEFAULT TRUE,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_by        UUID,
  updated_by        UUID,
  deleted_at        TIMESTAMPTZ,
  deleted_by        UUID
);

-- sale_items: line items per sale
CREATE TABLE IF NOT EXISTS public.sale_items (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id       UUID NOT NULL REFERENCES public.companies(id),
  sale_id          UUID NOT NULL,
  variant_id       UUID NOT NULL,
  quantity         NUMERIC(12,3) NOT NULL CHECK (quantity > 0),
  unit_price       NUMERIC(12,2) NOT NULL CHECK (unit_price >= 0),
  discount_percent NUMERIC(5,2) NOT NULL DEFAULT 0 CHECK (discount_percent >= 0),
  discount_amount  NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (discount_amount >= 0),
  tax_percent      NUMERIC(5,2) NOT NULL DEFAULT 0 CHECK (tax_percent >= 0),
  tax_amount       NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (tax_amount >= 0),
  line_total       NUMERIC(12,2) NOT NULL CHECK (line_total >= 0),
  is_manual_price  BOOLEAN NOT NULL DEFAULT FALSE,
  is_active        BOOLEAN NOT NULL DEFAULT TRUE,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_by       UUID,
  updated_by       UUID,
  deleted_at       TIMESTAMPTZ,
  deleted_by       UUID
);

-- sale_item_batches: FEFO lot traceability per sale item
CREATE TABLE IF NOT EXISTS public.sale_item_batches (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id    UUID NOT NULL REFERENCES public.companies(id),
  sale_item_id  UUID NOT NULL,
  lot_id        UUID NOT NULL,
  quantity      NUMERIC(12,3) NOT NULL CHECK (quantity > 0),
  cost_price    NUMERIC(12,2),
  is_active     BOOLEAN NOT NULL DEFAULT TRUE,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_by    UUID,
  updated_by    UUID,
  deleted_at    TIMESTAMPTZ,
  deleted_by    UUID
);

-- payments: one or more payment methods per sale
CREATE TABLE IF NOT EXISTS public.payments (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id      UUID NOT NULL REFERENCES public.companies(id),
  sale_id         UUID NOT NULL,
  payment_method  TEXT NOT NULL CHECK (payment_method IN ('cash', 'card', 'transfer', 'credit')),
  amount          NUMERIC(12,2) NOT NULL CHECK (amount > 0),
  reference       TEXT,
  is_active       BOOLEAN NOT NULL DEFAULT TRUE,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_by      UUID,
  updated_by      UUID,
  deleted_at      TIMESTAMPTZ,
  deleted_by      UUID
);

-- discount_authorizations: admin audit trail for discounts
CREATE TABLE IF NOT EXISTS public.discount_authorizations (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id       UUID NOT NULL REFERENCES public.companies(id),
  sale_id          UUID NOT NULL,
  authorized_by    UUID NOT NULL,
  authorized_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  discount_percent NUMERIC(5,2) NOT NULL CHECK (discount_percent >= 0),
  discount_amount  NUMERIC(12,2) NOT NULL CHECK (discount_amount >= 0),
  reason           TEXT NOT NULL,
  is_active        BOOLEAN NOT NULL DEFAULT TRUE,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_by       UUID,
  updated_by       UUID,
  deleted_at       TIMESTAMPTZ,
  deleted_by       UUID
);

-- ============================================================================
-- Indexes
-- ============================================================================

CREATE UNIQUE INDEX IF NOT EXISTS idx_sales_company_id_id
  ON public.sales(company_id, id);

CREATE UNIQUE INDEX IF NOT EXISTS idx_sales_company_branch_number
  ON public.sales(company_id, branch_id, sale_number);

CREATE INDEX IF NOT EXISTS idx_sales_company_branch_status
  ON public.sales(company_id, branch_id, status);

CREATE INDEX IF NOT EXISTS idx_sales_cash_session
  ON public.sales(company_id, cash_session_id);

CREATE UNIQUE INDEX IF NOT EXISTS idx_sale_items_company_id_id
  ON public.sale_items(company_id, id);

CREATE INDEX IF NOT EXISTS idx_sale_items_company_sale
  ON public.sale_items(company_id, sale_id);

CREATE UNIQUE INDEX IF NOT EXISTS idx_sale_item_batches_company_id_id
  ON public.sale_item_batches(company_id, id);

CREATE INDEX IF NOT EXISTS idx_sale_item_batches_company_sale_item
  ON public.sale_item_batches(company_id, sale_item_id);

CREATE UNIQUE INDEX IF NOT EXISTS idx_payments_company_id_id
  ON public.payments(company_id, id);

CREATE INDEX IF NOT EXISTS idx_payments_company_sale
  ON public.payments(company_id, sale_id);

CREATE UNIQUE INDEX IF NOT EXISTS idx_discount_auth_company_id_id
  ON public.discount_authorizations(company_id, id);

CREATE INDEX IF NOT EXISTS idx_discount_auth_company_sale
  ON public.discount_authorizations(company_id, sale_id);

-- ============================================================================
-- Composite Foreign Keys
-- ============================================================================

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'fk_sales_branch_same_company'
  ) THEN
    ALTER TABLE public.sales
      ADD CONSTRAINT fk_sales_branch_same_company
      FOREIGN KEY (company_id, branch_id) REFERENCES public.branches(company_id, id);
  END IF;
END;
$$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'fk_sales_cash_session_same_company'
  ) THEN
    ALTER TABLE public.sales
      ADD CONSTRAINT fk_sales_cash_session_same_company
      FOREIGN KEY (company_id, cash_session_id) REFERENCES public.cash_sessions(company_id, id);
  END IF;
END;
$$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'fk_sales_cashier_company_membership'
  ) THEN
    ALTER TABLE public.sales
      ADD CONSTRAINT fk_sales_cashier_company_membership
      FOREIGN KEY (company_id, cashier_user_id) REFERENCES public.company_users(company_id, user_id);
  END IF;
END;
$$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'fk_sales_customer_company_membership'
  ) THEN
    ALTER TABLE public.sales
      ADD CONSTRAINT fk_sales_customer_company_membership
      FOREIGN KEY (company_id, customer_id) REFERENCES public.company_users(company_id, user_id);
  END IF;
END;
$$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'fk_sale_items_sale_same_company'
  ) THEN
    ALTER TABLE public.sale_items
      ADD CONSTRAINT fk_sale_items_sale_same_company
      FOREIGN KEY (company_id, sale_id) REFERENCES public.sales(company_id, id);
  END IF;
END;
$$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'fk_sale_item_batches_sale_item_same_company'
  ) THEN
    ALTER TABLE public.sale_item_batches
      ADD CONSTRAINT fk_sale_item_batches_sale_item_same_company
      FOREIGN KEY (company_id, sale_item_id) REFERENCES public.sale_items(company_id, id);
  END IF;
END;
$$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'fk_payments_sale_same_company'
  ) THEN
    ALTER TABLE public.payments
      ADD CONSTRAINT fk_payments_sale_same_company
      FOREIGN KEY (company_id, sale_id) REFERENCES public.sales(company_id, id);
  END IF;
END;
$$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'fk_discount_auth_sale_same_company'
  ) THEN
    ALTER TABLE public.discount_authorizations
      ADD CONSTRAINT fk_discount_auth_sale_same_company
      FOREIGN KEY (company_id, sale_id) REFERENCES public.sales(company_id, id);
  END IF;
END;
$$;

-- ============================================================================
-- Triggers: logical-delete prevention
-- ============================================================================

CREATE OR REPLACE FUNCTION public.prevent_sales_delete()
RETURNS TRIGGER AS $$
BEGIN
  RAISE EXCEPTION 'sales uses logical deletion only';
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION public.prevent_child_mutation()
RETURNS TRIGGER AS $$
BEGIN
  RAISE EXCEPTION 'child tables are append-only via RPC';
END;
$$ LANGUAGE plpgsql;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger WHERE tgname = 'trg_sales_no_delete'
  ) THEN
    CREATE TRIGGER trg_sales_no_delete
      BEFORE DELETE ON public.sales
      FOR EACH ROW EXECUTE FUNCTION public.prevent_sales_delete();
  END IF;
END;
$$;

-- Prevent direct DELETE on child tables
DO $$
DECLARE
  t TEXT;
BEGIN
  FOREACH t IN ARRAY ARRAY['sale_items', 'sale_item_batches', 'payments', 'discount_authorizations']
  LOOP
    IF NOT EXISTS (
      SELECT 1 FROM pg_trigger WHERE tgname = format('trg_%s_no_delete', t)
    ) THEN
      EXECUTE format(
        'CREATE TRIGGER trg_%I_no_delete BEFORE DELETE ON public.%I FOR EACH ROW EXECUTE FUNCTION public.prevent_child_mutation()',
        t, t
      );
    END IF;
  END LOOP;
END;
$$;

-- Prevent direct UPDATE on append-only child tables
DO $$
DECLARE
  t TEXT;
BEGIN
  FOREACH t IN ARRAY ARRAY['sale_item_batches', 'payments', 'discount_authorizations']
  LOOP
    IF NOT EXISTS (
      SELECT 1 FROM pg_trigger WHERE tgname = format('trg_%s_no_update', t)
    ) THEN
      EXECUTE format(
        'CREATE TRIGGER trg_%I_no_update BEFORE UPDATE ON public.%I FOR EACH ROW EXECUTE FUNCTION public.prevent_child_mutation()',
        t, t
      );
    END IF;
  END LOOP;
END;
$$;

-- updated_at triggers
DO $$
DECLARE
  t TEXT;
BEGIN
  FOREACH t IN ARRAY ARRAY['sales', 'sale_items', 'sale_item_batches', 'payments', 'discount_authorizations']
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
-- RLS Policies
-- ============================================================================

ALTER TABLE public.sales ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sale_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sale_item_batches ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.payments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.discount_authorizations ENABLE ROW LEVEL SECURITY;

-- Sales: SELECT per company scope
DROP POLICY IF EXISTS "sales_select_company_scope" ON public.sales;
CREATE POLICY "sales_select_company_scope"
  ON public.sales FOR SELECT
  TO authenticated
  USING (
    company_id = public.get_company_id()
    AND (
      public.is_admin()
      OR cashier_user_id = auth.uid()
      OR EXISTS (
        SELECT 1 FROM public.branch_users bu
        WHERE bu.user_id = auth.uid()
          AND bu.branch_id = sales.branch_id
          AND bu.company_id = public.get_company_id()
          AND bu.is_active = TRUE
      )
    )
  );

DROP POLICY IF EXISTS "sales_service_all" ON public.sales;
CREATE POLICY "sales_service_all"
  ON public.sales FOR ALL
  TO service_role
  USING (TRUE)
  WITH CHECK (TRUE);

-- Sale items
DROP POLICY IF EXISTS "sale_items_select_company_scope" ON public.sale_items;
CREATE POLICY "sale_items_select_company_scope"
  ON public.sale_items FOR SELECT
  TO authenticated
  USING (
    company_id = public.get_company_id()
    AND (
      public.is_admin()
      OR EXISTS (
        SELECT 1 FROM public.sales s
        WHERE s.company_id = sale_items.company_id
          AND s.id = sale_items.sale_id
          AND (s.cashier_user_id = auth.uid()
            OR EXISTS (
              SELECT 1 FROM public.branch_users bu
              WHERE bu.user_id = auth.uid()
                AND bu.branch_id = s.branch_id
                AND bu.company_id = public.get_company_id()
                AND bu.is_active = TRUE
            ))
      )
    )
  );

DROP POLICY IF EXISTS "sale_items_service_all" ON public.sale_items;
CREATE POLICY "sale_items_service_all"
  ON public.sale_items FOR ALL
  TO service_role
  USING (TRUE)
  WITH CHECK (TRUE);

-- Sale item batches
DROP POLICY IF EXISTS "sale_item_batches_select_company_scope" ON public.sale_item_batches;
CREATE POLICY "sale_item_batches_select_company_scope"
  ON public.sale_item_batches FOR SELECT
  TO authenticated
  USING (company_id = public.get_company_id());

DROP POLICY IF EXISTS "sale_item_batches_service_all" ON public.sale_item_batches;
CREATE POLICY "sale_item_batches_service_all"
  ON public.sale_item_batches FOR ALL
  TO service_role
  USING (TRUE)
  WITH CHECK (TRUE);

-- Payments
DROP POLICY IF EXISTS "payments_select_company_scope" ON public.payments;
CREATE POLICY "payments_select_company_scope"
  ON public.payments FOR SELECT
  TO authenticated
  USING (company_id = public.get_company_id());

DROP POLICY IF EXISTS "payments_service_all" ON public.payments;
CREATE POLICY "payments_service_all"
  ON public.payments FOR ALL
  TO service_role
  USING (TRUE)
  WITH CHECK (TRUE);

-- Discount authorizations
DROP POLICY IF EXISTS "discount_auth_select_company_scope" ON public.discount_authorizations;
CREATE POLICY "discount_auth_select_company_scope"
  ON public.discount_authorizations FOR SELECT
  TO authenticated
  USING (company_id = public.get_company_id());

DROP POLICY IF EXISTS "discount_auth_service_all" ON public.discount_authorizations;
CREATE POLICY "discount_auth_service_all"
  ON public.discount_authorizations FOR ALL
  TO service_role
  USING (TRUE)
  WITH CHECK (TRUE);

-- ============================================================================
-- Grants
-- ============================================================================

GRANT SELECT ON public.sales TO anon, authenticated, service_role;
GRANT INSERT, UPDATE ON public.sales TO service_role;

GRANT SELECT ON public.sale_items TO anon, authenticated, service_role;
GRANT INSERT, UPDATE ON public.sale_items TO service_role;

GRANT SELECT ON public.sale_item_batches TO anon, authenticated, service_role;
GRANT INSERT ON public.sale_item_batches TO service_role;

GRANT SELECT ON public.payments TO anon, authenticated, service_role;
GRANT INSERT ON public.payments TO service_role;

GRANT SELECT ON public.discount_authorizations TO anon, authenticated, service_role;
GRANT INSERT ON public.discount_authorizations TO service_role;

GRANT USAGE ON ALL SEQUENCES IN SCHEMA public TO service_role;

-- ============================================================================
-- RPC: create_sale_transaction
-- Full sale creation with FEFO deduction, cash session validation, lot mapping
-- ============================================================================

CREATE OR REPLACE FUNCTION public.create_sale_transaction(p JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_company_id        UUID;
  v_branch_id         UUID;
  v_actor_user_id     UUID;
  v_cashier_user_id   UUID;
  v_customer_id       UUID;
  v_cash_session_id   UUID;
  v_items             JSONB;
  v_payments          JSONB;
  v_notes             TEXT;
  v_sale_id           UUID;
  v_sale_number       BIGINT;
  v_subtotal          NUMERIC(12,2) := 0;
  v_discount_amount   NUMERIC(12,2) := 0;
  v_tax_amount        NUMERIC(12,2) := 0;
  v_total             NUMERIC(12,2) := 0;
  v_item              JSONB;
  v_item_id           UUID;
  v_fefo_result       JSONB;
  v_fefo_entry        JSONB;
  v_movement_id       UUID;
  v_payment           JSONB;
  v_is_admin          BOOLEAN;
BEGIN
  -- Extract and validate input
  v_company_id      := (p->>'company_id')::UUID;
  v_branch_id       := (p->>'branch_id')::UUID;
  v_actor_user_id   := (p->>'actor_user_id')::UUID;
  v_cashier_user_id := COALESCE((p->>'cashier_user_id')::UUID, v_actor_user_id);

  -- Set JWT auth context so nested functions (e.g. record_sale_deduction)
  -- can use auth.uid() via request.jwt.claim.sub
  PERFORM set_config('request.jwt.claims', json_build_object(
    'sub', v_actor_user_id,
    'role', 'service_role',
    'app_metadata', json_build_object(
      'company_id', v_company_id,
      'role', 'admin'
    )
  )::text, true);
  v_customer_id     := (p->>'customer_id')::UUID;
  v_items           := p->'items';
  v_payments        := p->'payments';
  v_notes           := p->>'notes';

  -- Validate caller is active admin or cashier in company
  IF NOT public.is_active_company_user(v_company_id, v_actor_user_id) THEN
    RETURN jsonb_build_object('success', false, 'code', 'FORBIDDEN', 'message', 'Caller not active in company');
  END IF;

  v_is_admin := public.has_role(v_company_id, v_actor_user_id, 'admin');

  -- If actor is different from cashier, actor must be admin
  IF v_actor_user_id <> v_cashier_user_id AND NOT v_is_admin THEN
    RETURN jsonb_build_object('success', false, 'code', 'FORBIDDEN', 'message', 'Only admins can create sales for other cashiers');
  END IF;

  -- Validate cashier is active cashier in company
  IF NOT public.has_role(v_company_id, v_cashier_user_id, 'cashier') THEN
    RETURN jsonb_build_object('success', false, 'code', 'VALIDATION_ERROR', 'message', 'Cashier must have cashier role');
  END IF;

  -- Validate branch belongs to company
  IF NOT EXISTS (SELECT 1 FROM public.branches WHERE id = v_branch_id AND company_id = v_company_id AND is_active) THEN
    RETURN jsonb_build_object('success', false, 'code', 'VALIDATION_ERROR', 'message', 'Branch not found or not active in company');
  END IF;

  -- Validate open cash session
  SELECT cs.id INTO v_cash_session_id
    FROM public.cash_sessions cs
   WHERE cs.company_id = v_company_id
     AND cs.branch_id = v_branch_id
     AND cs.cashier_user_id = v_cashier_user_id
     AND cs.status = 'open'
     AND cs.is_active
   LIMIT 1;

  IF v_cash_session_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'code', 'VALIDATION_ERROR', 'message', 'No open cash session for this cashier in this branch');
  END IF;

  -- Validate credit payments require customer
  IF v_customer_id IS NULL AND v_payments @> '[{"payment_method": "credit"}]'::JSONB THEN
    RETURN jsonb_build_object('success', false, 'code', 'VALIDATION_ERROR', 'message', 'Customer is required for credit payments');
  END IF;

  -- Generate sale number
  v_sale_number := public.next_sale_number(v_company_id, v_branch_id);

  -- Create sale header
  INSERT INTO public.sales (
    company_id, branch_id, cashier_user_id, customer_id, cash_session_id,
    status, subtotal, discount_amount, tax_amount, total, sale_number, notes, created_by, updated_by
  ) VALUES (
    v_company_id, v_branch_id, v_cashier_user_id, v_customer_id, v_cash_session_id,
    'active', 0, 0, 0, 0, v_sale_number, v_notes, v_actor_user_id, v_actor_user_id
  )
  RETURNING id INTO v_sale_id;

  -- Process items
  FOR v_item IN SELECT * FROM jsonb_array_elements(v_items)
  LOOP
    INSERT INTO public.sale_items (
      company_id, sale_id, variant_id, quantity, unit_price,
      discount_percent, discount_amount, tax_percent, tax_amount, line_total,
      is_manual_price, created_by, updated_by
    ) VALUES (
      v_company_id, v_sale_id,
      (v_item->>'variant_id')::UUID,
      (v_item->>'quantity')::NUMERIC,
      COALESCE((v_item->>'unit_price')::NUMERIC, 0),
      COALESCE((v_item->>'discount_percent')::NUMERIC, 0),
      COALESCE((v_item->>'discount_amount')::NUMERIC, 0),
      COALESCE((v_item->>'tax_percent')::NUMERIC, 0),
      COALESCE((v_item->>'tax_amount')::NUMERIC, 0),
      COALESCE((v_item->>'line_total')::NUMERIC, 0),
      COALESCE((v_item->>'is_manual_price')::BOOLEAN, FALSE),
      v_actor_user_id, v_actor_user_id
    )
    RETURNING id INTO v_item_id;

    v_subtotal        := v_subtotal + COALESCE((v_item->>'unit_price')::NUMERIC * (v_item->>'quantity')::NUMERIC, 0);
    v_discount_amount := v_discount_amount + COALESCE((v_item->>'discount_amount')::NUMERIC, 0);
    v_tax_amount      := v_tax_amount + COALESCE((v_item->>'tax_amount')::NUMERIC, 0);
    v_total           := v_total + COALESCE((v_item->>'line_total')::NUMERIC, 0);

    -- Call FEFO deduction for this item
    -- record_sale_deduction raises exceptions on failure (insufficient stock, etc.)
    v_fefo_result := public.record_sale_deduction(jsonb_build_object(
      'company_id', v_company_id,
      'branch_id', v_branch_id,
      'variant_id', v_item->>'variant_id',
      'qty', (v_item->>'quantity')::NUMERIC,
      'reference_type', 'sale',
      'reference_id', v_sale_id
    ));

    -- Persist lot mapping from FEFO result
    FOR v_fefo_entry IN SELECT * FROM jsonb_array_elements(v_fefo_result->'data'->'lots')
    LOOP
      INSERT INTO public.sale_item_batches (
        company_id, sale_item_id, lot_id, quantity, cost_price, created_by, updated_by
      ) VALUES (
        v_company_id, v_item_id,
        (v_fefo_entry->>'lot_id')::UUID,
        (v_fefo_entry->>'quantity')::NUMERIC,
        (v_fefo_entry->>'cost_price')::NUMERIC,
        v_actor_user_id, v_actor_user_id
      );
    END LOOP;
  END LOOP;

  -- Update sale with computed totals
  UPDATE public.sales
    SET subtotal = v_subtotal,
        discount_amount = v_discount_amount,
        tax_amount = v_tax_amount,
        total = v_total,
        updated_by = v_actor_user_id
  WHERE id = v_sale_id;

  -- Process payments
  FOR v_payment IN SELECT * FROM jsonb_array_elements(v_payments)
  LOOP
    INSERT INTO public.payments (
      company_id, sale_id, payment_method, amount, reference, created_by, updated_by
    ) VALUES (
      v_company_id, v_sale_id,
      v_payment->>'payment_method',
      (v_payment->>'amount')::NUMERIC,
      v_payment->>'reference',
      v_actor_user_id, v_actor_user_id
    );
  END LOOP;

  -- Return complete sale
  RETURN jsonb_build_object(
    'success', true,
    'data', jsonb_build_object(
      'sale_id', v_sale_id,
      'sale_number', v_sale_number,
      'cash_session_id', v_cash_session_id,
      'status', 'active',
      'subtotal', v_subtotal,
      'discount_amount', v_discount_amount,
      'tax_amount', v_tax_amount,
      'total', v_total
    )
  );
END;
$$;

-- ============================================================================
-- RPC: cancel_sale_transaction
-- Cancels a sale and reverses inventory deduction
-- ============================================================================

CREATE OR REPLACE FUNCTION public.cancel_sale_transaction(p JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_company_id      UUID;
  v_actor_user_id   UUID;
  v_sale_id         UUID;
  v_reason          TEXT;
  v_sale_status     TEXT;
  v_sale_cashier    UUID;
  v_sale_branch     UUID;
  v_batch           RECORD;
  v_is_admin        BOOLEAN;
  v_reversed_items  JSONB := '[]'::JSONB;
  v_adjust_result   JSONB;
BEGIN
  v_company_id    := (p->>'company_id')::UUID;
  v_actor_user_id := (p->>'actor_user_id')::UUID;
  v_sale_id       := (p->>'sale_id')::UUID;
  v_reason        := p->>'reason';

  -- Set JWT auth context for nested functions
  PERFORM set_config('request.jwt.claims', json_build_object(
    'sub', v_actor_user_id,
    'role', 'service_role',
    'app_metadata', json_build_object(
      'company_id', v_company_id,
      'role', 'admin'
    )
  )::text, true);

  -- Validate caller is active in company
  IF NOT public.is_active_company_user(v_company_id, v_actor_user_id) THEN
    RETURN jsonb_build_object('success', false, 'code', 'FORBIDDEN', 'message', 'Caller not active in company');
  END IF;

  v_is_admin := public.has_role(v_company_id, v_actor_user_id, 'admin');

  -- Read sale
  SELECT status, cashier_user_id, branch_id INTO v_sale_status, v_sale_cashier, v_sale_branch
    FROM public.sales
   WHERE id = v_sale_id AND company_id = v_company_id AND is_active;

  IF v_sale_status IS NULL THEN
    RETURN jsonb_build_object('success', false, 'code', 'NOT_FOUND', 'message', 'Sale not found');
  END IF;

  IF v_sale_status != 'active' THEN
    RETURN jsonb_build_object('success', false, 'code', 'VALIDATION_ERROR', 'message', 'Sale is not active');
  END IF;

  -- Cashier can only cancel own sales; admin can cancel any
  IF NOT v_is_admin AND v_actor_user_id != v_sale_cashier THEN
    RETURN jsonb_build_object('success', false, 'code', 'FORBIDDEN', 'message', 'Cashiers can only cancel their own sales');
  END IF;

  -- Reverse inventory for each batch
  FOR v_batch IN
    SELECT sib.id AS batch_id, sib.lot_id, sib.quantity, sib.sale_item_id, si.variant_id
      FROM public.sale_item_batches sib
      JOIN public.sale_items si ON si.id = sib.sale_item_id AND si.company_id = v_company_id
      JOIN public.sales s ON s.id = si.sale_id AND s.company_id = v_company_id
     WHERE s.id = v_sale_id AND sib.company_id = v_company_id AND sib.is_active
  LOOP
    -- Reverse inventory via adjust_inventory_stock
    v_adjust_result := public.adjust_inventory_stock(jsonb_build_object(
      'company_id', v_company_id,
      'branch_id', v_sale_branch,
      'variant_id', v_batch.variant_id,
      'lot_id', v_batch.lot_id,
      'quantity', v_batch.quantity,
      'movement_type', 'sale_return',
      'reference_type', 'sale_cancellation',
      'reference_id', v_sale_id,
      'actor_user_id', v_actor_user_id
    ));

    IF (v_adjust_result->>'success') IS DISTINCT FROM 'true' THEN
      RAISE EXCEPTION 'Inventory reversal failed for lot %: %', v_batch.lot_id, v_adjust_result->>'message';
    END IF;

    v_reversed_items := v_reversed_items || jsonb_build_object(
      'lot_id', v_batch.lot_id,
      'variant_id', v_batch.variant_id,
      'quantity', v_batch.quantity
    );
  END LOOP;

  -- Mark sale as cancelled
  UPDATE public.sales
    SET status = 'cancelled',
        updated_by = v_actor_user_id,
        notes = CASE WHEN v_reason IS NOT NULL THEN notes || E'\nCancellation: ' || v_reason ELSE notes END
  WHERE id = v_sale_id AND company_id = v_company_id;

  RETURN jsonb_build_object(
    'success', true,
    'data', jsonb_build_object(
      'sale_id', v_sale_id,
      'status', 'cancelled',
      'reversed_items', v_reversed_items
    )
  );
END;
$$;

-- ============================================================================
-- RPC: authorize_discount
-- Records admin authorization for a discount
-- ============================================================================

CREATE OR REPLACE FUNCTION public.authorize_discount(p JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_company_id       UUID;
  v_actor_user_id    UUID;
  v_sale_id          UUID;
  v_discount_percent NUMERIC(5,2);
  v_discount_amount  NUMERIC(12,2);
  v_reason           TEXT;
  v_sale_status      TEXT;
  v_auth_id          UUID;
BEGIN
  v_company_id       := (p->>'company_id')::UUID;
  v_actor_user_id    := (p->>'actor_user_id')::UUID;
  v_sale_id          := (p->>'sale_id')::UUID;
  v_discount_percent := (p->>'discount_percent')::NUMERIC;
  v_discount_amount  := (p->>'discount_amount')::NUMERIC;
  v_reason           := p->>'reason';

  -- Validate caller is active admin in company
  IF NOT public.has_role(v_company_id, v_actor_user_id, 'admin') THEN
    RETURN jsonb_build_object('success', false, 'code', 'FORBIDDEN', 'message', 'Only admins can authorize discounts');
  END IF;

  -- Validate sale exists and is active
  SELECT status INTO v_sale_status
    FROM public.sales
   WHERE id = v_sale_id AND company_id = v_company_id AND is_active;

  IF v_sale_status IS NULL THEN
    RETURN jsonb_build_object('success', false, 'code', 'NOT_FOUND', 'message', 'Sale not found');
  END IF;

  IF v_sale_status != 'active' THEN
    RETURN jsonb_build_object('success', false, 'code', 'VALIDATION_ERROR', 'message', 'Cannot authorize discount for non-active sale');
  END IF;

  -- Insert authorization
  INSERT INTO public.discount_authorizations (
    company_id, sale_id, authorized_by, discount_percent, discount_amount, reason,
    created_by, updated_by
  ) VALUES (
    v_company_id, v_sale_id, v_actor_user_id, v_discount_percent, v_discount_amount, v_reason,
    v_actor_user_id, v_actor_user_id
  )
  RETURNING id INTO v_auth_id;

  RETURN jsonb_build_object(
    'success', true,
    'data', jsonb_build_object(
      'authorization_id', v_auth_id,
      'sale_id', v_sale_id,
      'authorized_by', v_actor_user_id,
      'authorized_at', now(),
      'discount_percent', v_discount_percent,
      'discount_amount', v_discount_amount
    )
  );
END;
$$;

-- ============================================================================
-- RPC: adjust_inventory_stock(p JSONB)
-- Restores stock to a specific lot (used by cancel_sale_transaction).
-- Accepts explicit actor_user_id (not JWT-dependent).
-- ============================================================================

CREATE OR REPLACE FUNCTION public.adjust_inventory_stock(p JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_company_id      UUID;
  v_branch_id       UUID;
  v_variant_id      UUID;
  v_lot_id          UUID;
  v_quantity        NUMERIC(14, 3);
  v_movement_type   TEXT;
  v_reference_type  TEXT;
  v_reference_id    UUID;
  v_actor_user_id   UUID;
  v_movement_id     UUID;
BEGIN
  v_company_id     := (p->>'company_id')::UUID;
  v_branch_id      := (p->>'branch_id')::UUID;
  v_variant_id     := (p->>'variant_id')::UUID;
  v_lot_id         := (p->>'lot_id')::UUID;
  v_quantity       := (p->>'quantity')::NUMERIC;
  v_movement_type  := p->>'movement_type';
  v_reference_type := p->>'reference_type';
  v_reference_id   := (p->>'reference_id')::UUID;
  v_actor_user_id  := (p->>'actor_user_id')::UUID;

  IF v_company_id IS NULL OR v_branch_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'code', 'VALIDATION_ERROR', 'message', 'company_id and branch_id are required');
  END IF;
  IF v_variant_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'code', 'VALIDATION_ERROR', 'message', 'variant_id is required');
  END IF;
  IF v_lot_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'code', 'VALIDATION_ERROR', 'message', 'lot_id is required');
  END IF;
  IF v_quantity IS NULL OR v_quantity <= 0 THEN
    RETURN jsonb_build_object('success', false, 'code', 'VALIDATION_ERROR', 'message', 'quantity must be positive');
  END IF;
  IF v_actor_user_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'code', 'VALIDATION_ERROR', 'message', 'actor_user_id is required');
  END IF;

  -- Update lot stock
  UPDATE public.stock_lots
  SET remaining_qty = remaining_qty + v_quantity,
      status = CASE WHEN remaining_qty + v_quantity > 0 AND status = 'depleted' THEN 'active' ELSE status END,
      updated_by = v_actor_user_id
  WHERE id = v_lot_id
    AND company_id = v_company_id
    AND variant_id = v_variant_id
    AND is_active = TRUE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'code', 'NOT_FOUND', 'message', 'Lot not found or not active');
  END IF;

  -- Record stock movement
  INSERT INTO public.stock_movements (
    company_id, branch_id, variant_id, lot_id, movement_type,
    delta_qty, reference_type, reference_id, created_by, updated_by
  ) VALUES (
    v_company_id, v_branch_id, v_variant_id, v_lot_id, v_movement_type,
    v_quantity, v_reference_type, v_reference_id, v_actor_user_id, v_actor_user_id
  )
  RETURNING id INTO v_movement_id;

  RETURN jsonb_build_object(
    'success', true,
    'movement_id', v_movement_id,
    'lot_id', v_lot_id,
    'adjusted_qty', v_quantity
  );
END;
$$;

COMMENT ON FUNCTION public.adjust_inventory_stock(JSONB) IS 'Restores stock to a specific lot using explicit actor_user_id. Used by cancel_sale_transaction for inventory reversal.';

-- ============================================================================
-- Grant RPC execution to service_role only
-- ============================================================================

GRANT EXECUTE ON FUNCTION public.next_sale_number(UUID, UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.create_sale_transaction(JSONB) TO service_role;
GRANT EXECUTE ON FUNCTION public.cancel_sale_transaction(JSONB) TO service_role;
GRANT EXECUTE ON FUNCTION public.authorize_discount(JSONB) TO service_role;
GRANT EXECUTE ON FUNCTION public.adjust_inventory_stock(JSONB) TO service_role;
