-- Migration: 00008_cash_session_domain
-- Source: cash-session-domain spec/design, Phase 1 — SQL foundation only

CREATE UNIQUE INDEX IF NOT EXISTS idx_company_users_company_id_user_id
  ON public.company_users(company_id, user_id);

CREATE TABLE IF NOT EXISTS public.cash_sessions (
  id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id            UUID NOT NULL REFERENCES public.companies(id),
  branch_id             UUID NOT NULL,
  cashier_user_id       UUID NOT NULL,
  status                TEXT NOT NULL CHECK (status IN ('open', 'closed')),
  opened_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
  closed_at             TIMESTAMPTZ,
  opening_amount        NUMERIC(12,2) NOT NULL CHECK (opening_amount >= 0),
  expected_cash_amount  NUMERIC(12,2) NOT NULL,
  counted_cash_amount   NUMERIC(12,2),
  difference_amount     NUMERIC(12,2),
  notes                 TEXT,
  is_active             BOOLEAN NOT NULL DEFAULT TRUE,
  created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_by            UUID,
  updated_by            UUID,
  deleted_at            TIMESTAMPTZ,
  deleted_by            UUID
);

CREATE TABLE IF NOT EXISTS public.cash_movements (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id       UUID NOT NULL REFERENCES public.companies(id),
  branch_id        UUID NOT NULL,
  cash_session_id  UUID NOT NULL,
  movement_type    TEXT NOT NULL CHECK (movement_type IN ('opening_float', 'manual_cash_in', 'manual_cash_out')),
  amount           NUMERIC(12,2) NOT NULL CHECK (
                     amount >= 0
                     AND (
                       (movement_type = 'opening_float')
                       OR (movement_type IN ('manual_cash_in', 'manual_cash_out') AND amount > 0)
                     )
                   ),
  reference_type   TEXT,
  reference_id     UUID,
  reason           TEXT,
  notes            TEXT,
  is_active        BOOLEAN NOT NULL DEFAULT TRUE,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_by       UUID,
  updated_by       UUID,
  deleted_at       TIMESTAMPTZ,
  deleted_by       UUID
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_cash_sessions_company_id_id
  ON public.cash_sessions(company_id, id);

CREATE UNIQUE INDEX IF NOT EXISTS idx_cash_movements_company_id_id
  ON public.cash_movements(company_id, id);

CREATE INDEX IF NOT EXISTS idx_cash_sessions_company_branch_cashier_status
  ON public.cash_sessions(company_id, branch_id, cashier_user_id, status);

CREATE UNIQUE INDEX IF NOT EXISTS idx_cash_sessions_one_open_per_cashier_branch
  ON public.cash_sessions(company_id, branch_id, cashier_user_id)
  WHERE status = 'open' AND is_active = TRUE;

CREATE INDEX IF NOT EXISTS idx_cash_movements_company_session_created_at
  ON public.cash_movements(company_id, cash_session_id, created_at);

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'fk_cash_sessions_branch_same_company'
  ) THEN
    ALTER TABLE public.cash_sessions
      ADD CONSTRAINT fk_cash_sessions_branch_same_company
      FOREIGN KEY (company_id, branch_id) REFERENCES public.branches(company_id, id);
  END IF;
END;
$$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'fk_cash_sessions_cashier_company_membership'
  ) THEN
    ALTER TABLE public.cash_sessions
      ADD CONSTRAINT fk_cash_sessions_cashier_company_membership
      FOREIGN KEY (company_id, cashier_user_id) REFERENCES public.company_users(company_id, user_id);
  END IF;
END;
$$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'fk_cash_movements_branch_same_company'
  ) THEN
    ALTER TABLE public.cash_movements
      ADD CONSTRAINT fk_cash_movements_branch_same_company
      FOREIGN KEY (company_id, branch_id) REFERENCES public.branches(company_id, id);
  END IF;
END;
$$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'fk_cash_movements_session_same_company'
  ) THEN
    ALTER TABLE public.cash_movements
      ADD CONSTRAINT fk_cash_movements_session_same_company
      FOREIGN KEY (company_id, cash_session_id) REFERENCES public.cash_sessions(company_id, id);
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.prevent_cash_sessions_delete()
RETURNS TRIGGER AS $$
BEGIN
  RAISE EXCEPTION 'cash_sessions uses logical deletion only';
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION public.prevent_cash_movements_mutation()
RETURNS TRIGGER AS $$
BEGIN
  RAISE EXCEPTION 'cash_movements is append-only';
END;
$$ LANGUAGE plpgsql;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger WHERE tgname = 'trg_cash_sessions_no_delete'
  ) THEN
    CREATE TRIGGER trg_cash_sessions_no_delete
      BEFORE DELETE ON public.cash_sessions
      FOR EACH ROW EXECUTE FUNCTION public.prevent_cash_sessions_delete();
  END IF;
END;
$$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger WHERE tgname = 'trg_cash_movements_no_update'
  ) THEN
    CREATE TRIGGER trg_cash_movements_no_update
      BEFORE UPDATE ON public.cash_movements
      FOR EACH ROW EXECUTE FUNCTION public.prevent_cash_movements_mutation();
  END IF;
END;
$$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger WHERE tgname = 'trg_cash_movements_no_delete'
  ) THEN
    CREATE TRIGGER trg_cash_movements_no_delete
      BEFORE DELETE ON public.cash_movements
      FOR EACH ROW EXECUTE FUNCTION public.prevent_cash_movements_mutation();
  END IF;
END;
$$;

DO $$
DECLARE
  t TEXT;
BEGIN
  FOREACH t IN ARRAY ARRAY['cash_sessions', 'cash_movements']
  LOOP
    IF NOT EXISTS (
      SELECT 1
      FROM pg_trigger
      WHERE tgname = format('set_updated_at_%s', t)
    ) THEN
      EXECUTE format(
        'CREATE TRIGGER set_updated_at_%I BEFORE UPDATE ON public.%I FOR EACH ROW EXECUTE FUNCTION public.set_updated_at()',
        t,
        t
      );
    END IF;
  END LOOP;
END;
$$;

ALTER TABLE public.cash_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.cash_movements ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "cash_sessions_select_company_scope" ON public.cash_sessions;
CREATE POLICY "cash_sessions_select_company_scope"
  ON public.cash_sessions FOR SELECT
  TO authenticated
  USING (
    company_id = public.get_company_id()
    AND (
      public.is_admin()
      OR (
        cashier_user_id = auth.uid()
        AND (
          branch_id = public.get_user_branch_id()
          OR EXISTS (
            SELECT 1
            FROM public.branch_users bu
            WHERE bu.user_id = auth.uid()
              AND bu.branch_id = cash_sessions.branch_id
              AND bu.company_id = public.get_company_id()
              AND bu.is_active = TRUE
          )
        )
      )
    )
  );

DROP POLICY IF EXISTS "cash_sessions_service_all" ON public.cash_sessions;
CREATE POLICY "cash_sessions_service_all"
  ON public.cash_sessions FOR ALL
  TO service_role
  USING (TRUE)
  WITH CHECK (TRUE);

DROP POLICY IF EXISTS "cash_movements_select_company_scope" ON public.cash_movements;
CREATE POLICY "cash_movements_select_company_scope"
  ON public.cash_movements FOR SELECT
  TO authenticated
  USING (
    company_id = public.get_company_id()
    AND (
      public.is_admin()
      OR EXISTS (
        SELECT 1
        FROM public.cash_sessions cs
        WHERE cs.company_id = cash_movements.company_id
          AND cs.id = cash_movements.cash_session_id
          AND cs.cashier_user_id = auth.uid()
          AND (
            cs.branch_id = public.get_user_branch_id()
            OR EXISTS (
              SELECT 1
              FROM public.branch_users bu
              WHERE bu.user_id = auth.uid()
                AND bu.branch_id = cs.branch_id
                AND bu.company_id = public.get_company_id()
                AND bu.is_active = TRUE
            )
          )
      )
    )
  );

DROP POLICY IF EXISTS "cash_movements_service_all" ON public.cash_movements;
CREATE POLICY "cash_movements_service_all"
  ON public.cash_movements FOR ALL
  TO service_role
  USING (TRUE)
  WITH CHECK (TRUE);

GRANT SELECT ON public.cash_sessions TO anon, authenticated, service_role;
GRANT INSERT, UPDATE ON public.cash_sessions TO service_role;

GRANT SELECT ON public.cash_movements TO anon, authenticated, service_role;
GRANT INSERT, UPDATE ON public.cash_movements TO service_role;

CREATE OR REPLACE FUNCTION public.open_cash_session(p JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_company_id       UUID;
  v_branch_id        UUID;
  v_actor_user_id    UUID;
  v_cashier_user_id  UUID;
  v_opening_amount   NUMERIC(12,2);
  v_notes            TEXT;
  v_session_id       UUID;
  v_movement_id      UUID;
  v_actor_role       TEXT;
  v_target_role      TEXT;
BEGIN
  v_company_id := (p->>'company_id')::UUID;
  v_branch_id := (p->>'branch_id')::UUID;
  v_actor_user_id := (p->>'actor_user_id')::UUID;
  v_cashier_user_id := COALESCE((p->>'cashier_user_id')::UUID, v_actor_user_id);
  v_opening_amount := (p->>'opening_amount')::NUMERIC;
  v_notes := NULLIF(btrim(p->>'notes'), '');

  IF v_company_id IS NULL THEN
    RAISE EXCEPTION 'company_id is required';
  END IF;
  IF v_actor_user_id IS NULL THEN
    RAISE EXCEPTION 'actor_user_id is required';
  END IF;
  IF v_branch_id IS NULL THEN
    RAISE EXCEPTION 'branch_id is required';
  END IF;
  IF v_opening_amount IS NULL OR v_opening_amount < 0 THEN
    RAISE EXCEPTION 'opening_amount must be zero or greater';
  END IF;

  SELECT cu.role
  INTO v_actor_role
  FROM public.company_users cu
  WHERE cu.company_id = v_company_id
    AND cu.user_id = v_actor_user_id
    AND cu.is_active = TRUE
  LIMIT 1;

  IF v_actor_role IS NULL THEN
    RAISE EXCEPTION 'actor_user_id is not an active member of this company';
  END IF;
  IF v_actor_role NOT IN ('admin', 'cashier') THEN
    RAISE EXCEPTION 'actor_user_id must have admin or cashier role';
  END IF;
  IF v_cashier_user_id IS DISTINCT FROM v_actor_user_id AND v_actor_role <> 'admin' THEN
    RAISE EXCEPTION 'Only admins can open a session for another user';
  END IF;
  IF v_cashier_user_id = v_actor_user_id AND v_actor_role <> 'cashier' THEN
    RAISE EXCEPTION 'Cashiers can only open their own cash session';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.branches
    WHERE id = v_branch_id
      AND company_id = v_company_id
      AND is_active = TRUE
  ) THEN
    RAISE EXCEPTION 'branch_id not found, inactive, or not owned by your company';
  END IF;

  SELECT cu.role
  INTO v_target_role
  FROM public.company_users cu
  WHERE cu.company_id = v_company_id
    AND cu.user_id = v_cashier_user_id
    AND cu.is_active = TRUE
  LIMIT 1;

  IF v_target_role IS NULL THEN
    RAISE EXCEPTION 'cashier_user_id is not an active member of this company';
  END IF;
  IF v_target_role <> 'cashier' THEN
    RAISE EXCEPTION 'cashier_user_id must have cashier role';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.branch_users bu
    WHERE bu.company_id = v_company_id
      AND bu.branch_id = v_branch_id
      AND bu.user_id = v_cashier_user_id
      AND bu.is_active = TRUE
  ) THEN
    RAISE EXCEPTION 'cashier_user_id is not assigned to this branch';
  END IF;

  PERFORM 1
  FROM public.cash_sessions cs
  WHERE cs.company_id = v_company_id
    AND cs.branch_id = v_branch_id
    AND cs.cashier_user_id = v_cashier_user_id
    AND cs.status = 'open'
    AND cs.is_active = TRUE
  FOR UPDATE;

  IF FOUND THEN
    RAISE EXCEPTION 'An open cash session already exists for this cashier in this branch';
  END IF;

  BEGIN
    INSERT INTO public.cash_sessions (
      company_id,
      branch_id,
      cashier_user_id,
      status,
      opened_at,
      opening_amount,
      expected_cash_amount,
      notes,
      created_by,
      updated_by
    )
    VALUES (
      v_company_id,
      v_branch_id,
      v_cashier_user_id,
      'open',
      now(),
      v_opening_amount,
      v_opening_amount,
      v_notes,
      v_actor_user_id,
      v_actor_user_id
    )
    RETURNING id INTO v_session_id;
  EXCEPTION
    WHEN unique_violation THEN
      RAISE EXCEPTION 'An open cash session already exists for this cashier in this branch';
  END;

  INSERT INTO public.cash_movements (
    company_id,
    branch_id,
    cash_session_id,
    movement_type,
    amount,
    reason,
    notes,
    created_by,
    updated_by
  )
  VALUES (
    v_company_id,
    v_branch_id,
    v_session_id,
    'opening_float',
    v_opening_amount,
    'session_open',
    v_notes,
    v_actor_user_id,
    v_actor_user_id
  )
  RETURNING id INTO v_movement_id;

  RETURN jsonb_build_object(
    'cash_session_id', v_session_id,
    'movement_id', v_movement_id,
    'status', 'open',
    'expected_cash_amount', v_opening_amount
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.close_cash_session(p JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_company_id           UUID;
  v_actor_user_id        UUID;
  v_cash_session_id      UUID;
  v_counted_cash_amount  NUMERIC(12,2);
  v_notes                TEXT;
  v_session              public.cash_sessions%ROWTYPE;
  v_difference_amount    NUMERIC(12,2);
  v_actor_role           TEXT;
BEGIN
  v_company_id := (p->>'company_id')::UUID;
  v_actor_user_id := (p->>'actor_user_id')::UUID;
  v_cash_session_id := (p->>'cash_session_id')::UUID;
  v_counted_cash_amount := (p->>'counted_cash_amount')::NUMERIC;
  v_notes := NULLIF(btrim(p->>'notes'), '');

  IF v_company_id IS NULL THEN
    RAISE EXCEPTION 'company_id is required';
  END IF;
  IF v_actor_user_id IS NULL THEN
    RAISE EXCEPTION 'actor_user_id is required';
  END IF;
  IF v_cash_session_id IS NULL THEN
    RAISE EXCEPTION 'cash_session_id is required';
  END IF;
  IF v_counted_cash_amount IS NULL OR v_counted_cash_amount < 0 THEN
    RAISE EXCEPTION 'counted_cash_amount must be zero or greater';
  END IF;

  SELECT cu.role
  INTO v_actor_role
  FROM public.company_users cu
  WHERE cu.company_id = v_company_id
    AND cu.user_id = v_actor_user_id
    AND cu.is_active = TRUE
  LIMIT 1;

  IF v_actor_role IS NULL THEN
    RAISE EXCEPTION 'actor_user_id is not an active member of this company';
  END IF;
  IF v_actor_role NOT IN ('admin', 'cashier') THEN
    RAISE EXCEPTION 'actor_user_id must have admin or cashier role';
  END IF;

  SELECT *
  INTO v_session
  FROM public.cash_sessions cs
  WHERE cs.company_id = v_company_id
    AND cs.id = v_cash_session_id
    AND cs.is_active = TRUE
  FOR UPDATE;

  IF v_session.id IS NULL THEN
    RAISE EXCEPTION 'Cash session not found, inactive, or not owned by your company';
  END IF;
  IF v_session.status <> 'open' THEN
    RAISE EXCEPTION 'Cash session is not open';
  END IF;
  IF v_session.cashier_user_id <> v_actor_user_id THEN
    RAISE EXCEPTION 'You can only close your own cash session';
  END IF;

  v_difference_amount := v_counted_cash_amount - v_session.expected_cash_amount;

  UPDATE public.cash_sessions
  SET status = 'closed',
      closed_at = now(),
      counted_cash_amount = v_counted_cash_amount,
      difference_amount = v_difference_amount,
      notes = COALESCE(v_notes, notes),
      updated_by = v_actor_user_id
  WHERE id = v_session.id;

  RETURN jsonb_build_object(
    'cash_session_id', v_session.id,
    'status', 'closed',
    'expected_cash_amount', v_session.expected_cash_amount,
    'counted_cash_amount', v_counted_cash_amount,
    'difference_amount', v_difference_amount
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.record_cash_movement(p JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_company_id      UUID;
  v_actor_user_id   UUID;
  v_cash_session_id UUID;
  v_movement_type   TEXT;
  v_amount          NUMERIC(12,2);
  v_reference_type  TEXT;
  v_reference_id    UUID;
  v_reason          TEXT;
  v_notes           TEXT;
  v_session         public.cash_sessions%ROWTYPE;
  v_delta           NUMERIC(12,2);
  v_movement_id     UUID;
  v_new_expected    NUMERIC(12,2);
  v_actor_role      TEXT;
BEGIN
  v_company_id := (p->>'company_id')::UUID;
  v_actor_user_id := (p->>'actor_user_id')::UUID;
  v_cash_session_id := (p->>'cash_session_id')::UUID;
  v_movement_type := NULLIF(btrim(p->>'movement_type'), '');
  v_amount := (p->>'amount')::NUMERIC;
  v_reference_type := NULLIF(btrim(p->>'reference_type'), '');
  v_reference_id := (p->>'reference_id')::UUID;
  v_reason := NULLIF(btrim(p->>'reason'), '');
  v_notes := NULLIF(btrim(p->>'notes'), '');

  IF v_company_id IS NULL THEN
    RAISE EXCEPTION 'company_id is required';
  END IF;
  IF v_actor_user_id IS NULL THEN
    RAISE EXCEPTION 'actor_user_id is required';
  END IF;
  IF v_cash_session_id IS NULL THEN
    RAISE EXCEPTION 'cash_session_id is required';
  END IF;
  IF v_movement_type NOT IN ('manual_cash_in', 'manual_cash_out') THEN
    RAISE EXCEPTION 'movement_type must be manual_cash_in or manual_cash_out';
  END IF;
  IF v_amount IS NULL OR v_amount <= 0 THEN
    RAISE EXCEPTION 'amount must be greater than zero';
  END IF;

  SELECT cu.role
  INTO v_actor_role
  FROM public.company_users cu
  WHERE cu.company_id = v_company_id
    AND cu.user_id = v_actor_user_id
    AND cu.is_active = TRUE
  LIMIT 1;

  IF v_actor_role IS NULL THEN
    RAISE EXCEPTION 'actor_user_id is not an active member of this company';
  END IF;
  IF v_actor_role NOT IN ('admin', 'cashier') THEN
    RAISE EXCEPTION 'actor_user_id must have admin or cashier role';
  END IF;

  SELECT *
  INTO v_session
  FROM public.cash_sessions cs
  WHERE cs.company_id = v_company_id
    AND cs.id = v_cash_session_id
    AND cs.is_active = TRUE
  FOR UPDATE;

  IF v_session.id IS NULL THEN
    RAISE EXCEPTION 'Cash session not found, inactive, or not owned by your company';
  END IF;
  IF v_session.status <> 'open' THEN
    RAISE EXCEPTION 'Cash session is not open';
  END IF;
  IF v_actor_role <> 'admin' AND v_session.cashier_user_id <> v_actor_user_id THEN
    RAISE EXCEPTION 'You can only record movements on your own cash session';
  END IF;
  IF v_actor_role = 'admin'
     AND v_session.cashier_user_id <> v_actor_user_id
     AND v_reason IS NULL THEN
    RAISE EXCEPTION 'Admin cash movements for another cashier require a reason';
  END IF;

  v_delta := CASE WHEN v_movement_type = 'manual_cash_in' THEN v_amount ELSE -v_amount END;
  v_new_expected := v_session.expected_cash_amount + v_delta;

  UPDATE public.cash_sessions
  SET expected_cash_amount = v_new_expected,
      updated_by = v_actor_user_id
  WHERE id = v_session.id;

  INSERT INTO public.cash_movements (
    company_id,
    branch_id,
    cash_session_id,
    movement_type,
    amount,
    reference_type,
    reference_id,
    reason,
    notes,
    created_by,
    updated_by
  )
  VALUES (
    v_company_id,
    v_session.branch_id,
    v_session.id,
    v_movement_type,
    v_amount,
    v_reference_type,
    v_reference_id,
    v_reason,
    v_notes,
    v_actor_user_id,
    v_actor_user_id
  )
  RETURNING id INTO v_movement_id;

  RETURN jsonb_build_object(
    'cash_session_id', v_session.id,
    'movement_id', v_movement_id,
    'movement_type', v_movement_type,
    'expected_cash_amount', v_new_expected
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.force_close_cash_session(p JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_company_id           UUID;
  v_actor_user_id        UUID;
  v_cash_session_id      UUID;
  v_counted_cash_amount  NUMERIC(12,2);
  v_reason               TEXT;
  v_session              public.cash_sessions%ROWTYPE;
  v_difference_amount    NUMERIC(12,2);
  v_actor_role           TEXT;
BEGIN
  v_company_id := (p->>'company_id')::UUID;
  v_actor_user_id := (p->>'actor_user_id')::UUID;
  v_cash_session_id := (p->>'cash_session_id')::UUID;
  v_counted_cash_amount := (p->>'counted_cash_amount')::NUMERIC;
  v_reason := NULLIF(btrim(COALESCE(p->>'reason', p->>'notes')), '');

  IF v_company_id IS NULL THEN
    RAISE EXCEPTION 'company_id is required';
  END IF;
  IF v_actor_user_id IS NULL THEN
    RAISE EXCEPTION 'actor_user_id is required';
  END IF;
  IF v_cash_session_id IS NULL THEN
    RAISE EXCEPTION 'cash_session_id is required';
  END IF;
  IF v_counted_cash_amount IS NULL OR v_counted_cash_amount < 0 THEN
    RAISE EXCEPTION 'counted_cash_amount must be zero or greater';
  END IF;

  SELECT cu.role
  INTO v_actor_role
  FROM public.company_users cu
  WHERE cu.company_id = v_company_id
    AND cu.user_id = v_actor_user_id
    AND cu.is_active = TRUE
  LIMIT 1;

  IF v_actor_role IS NULL THEN
    RAISE EXCEPTION 'actor_user_id is not an active member of this company';
  END IF;
  IF v_actor_role <> 'admin' THEN
    RAISE EXCEPTION 'Only admins can force-close cash sessions';
  END IF;

  SELECT *
  INTO v_session
  FROM public.cash_sessions cs
  WHERE cs.company_id = v_company_id
    AND cs.id = v_cash_session_id
    AND cs.is_active = TRUE
  FOR UPDATE;

  IF v_session.id IS NULL THEN
    RAISE EXCEPTION 'Cash session not found, inactive, or not owned by your company';
  END IF;
  IF v_session.status <> 'open' THEN
    RAISE EXCEPTION 'Cash session is not open';
  END IF;

  v_difference_amount := v_counted_cash_amount - v_session.expected_cash_amount;

  UPDATE public.cash_sessions
  SET status = 'closed',
      closed_at = now(),
      counted_cash_amount = v_counted_cash_amount,
      difference_amount = v_difference_amount,
      notes = COALESCE(v_reason, notes),
      updated_by = v_actor_user_id
  WHERE id = v_session.id;

  RETURN jsonb_build_object(
    'cash_session_id', v_session.id,
    'status', 'closed',
    'expected_cash_amount', v_session.expected_cash_amount,
    'counted_cash_amount', v_counted_cash_amount,
    'difference_amount', v_difference_amount,
    'forced', TRUE
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.open_cash_session(JSONB) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.close_cash_session(JSONB) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.record_cash_movement(JSONB) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.force_close_cash_session(JSONB) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.open_cash_session(JSONB) TO service_role;
GRANT EXECUTE ON FUNCTION public.close_cash_session(JSONB) TO service_role;
GRANT EXECUTE ON FUNCTION public.record_cash_movement(JSONB) TO service_role;
GRANT EXECUTE ON FUNCTION public.force_close_cash_session(JSONB) TO service_role;
