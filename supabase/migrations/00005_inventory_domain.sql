-- Migration: 00005_inventory_domain
-- Source: inventory-domain spec (RI1-RI11), design (inventory domain)
-- Requirements: R3 (RLS-first multi-tenant), R4 (inventory movement integrity),
--               R5 (traceability + logical deletion), R6 (transactional consistency)

-- ============================================================
-- SUPPORTING UNIQUE INDEX
-- Enables composite FK enforcement for branch-scoped inventory tables.
-- (source: RI2, RI9)
-- ============================================================
CREATE UNIQUE INDEX idx_branches_company_id_id
  ON public.branches(company_id, id);

-- ============================================================
-- STOCK_LOTS
-- Per-batch inventory by company, branch, and variant. remaining_qty is a
-- denormalized cache updated only inside SECURITY DEFINER RPCs.
-- (source: RI1, RI2)
-- ============================================================
CREATE TABLE public.stock_lots (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id       UUID NOT NULL REFERENCES public.companies(id),
  branch_id        UUID NOT NULL,
  variant_id       UUID NOT NULL,
  lot_code         TEXT,
  expiration_date  DATE,
  received_qty     NUMERIC(14, 3) NOT NULL CHECK (received_qty > 0),
  remaining_qty    NUMERIC(14, 3) NOT NULL CHECK (remaining_qty >= 0),
  cost_per_unit    NUMERIC(12, 2),
  status           TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'expired', 'depleted')),
  is_active        BOOLEAN NOT NULL DEFAULT TRUE,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_by       UUID,
  updated_by       UUID,
  deleted_at       TIMESTAMPTZ,
  deleted_by       UUID,

  UNIQUE(company_id, branch_id, variant_id, lot_code)
);

COMMENT ON TABLE public.stock_lots IS 'Lot-based inventory batches. remaining_qty is mutation-protected and updated only by hardened inventory RPCs. (source: RI1, RI2)';
COMMENT ON COLUMN public.stock_lots.lot_code IS 'Supplier lot code or future auto-generated LOT code. Unique per company + branch + variant when present. (source: RI2, RI5)';
COMMENT ON COLUMN public.stock_lots.cost_per_unit IS 'Nullable in V1. Future COGS logic can backfill or compute later. (source: RI2)';
COMMENT ON COLUMN public.stock_lots.remaining_qty IS 'Denormalized stock cache. Direct authenticated updates are prohibited. (source: RI1, RI2)';

CREATE INDEX idx_stock_lots_company_id ON public.stock_lots(company_id);
CREATE INDEX idx_stock_lots_branch_id ON public.stock_lots(branch_id);
CREATE INDEX idx_stock_lots_variant_id ON public.stock_lots(variant_id);
CREATE INDEX idx_stock_lots_expiration_active
  ON public.stock_lots(company_id, branch_id, expiration_date, id)
  WHERE is_active = TRUE AND status = 'active';
CREATE UNIQUE INDEX idx_stock_lots_company_id_id ON public.stock_lots(company_id, id);
CREATE UNIQUE INDEX idx_stock_lots_company_branch_variant_id
  ON public.stock_lots(company_id, branch_id, variant_id, id);

ALTER TABLE public.stock_lots
  ADD CONSTRAINT fk_stock_lots_branch_same_company
  FOREIGN KEY (company_id, branch_id) REFERENCES public.branches(company_id, id);

ALTER TABLE public.stock_lots
  ADD CONSTRAINT fk_stock_lots_variant_same_company
  FOREIGN KEY (company_id, variant_id) REFERENCES public.product_variants(company_id, id);

CREATE TRIGGER set_updated_at
  BEFORE UPDATE ON public.stock_lots
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- ============================================================
-- STOCK_MOVEMENTS
-- Append-only audit ledger for all inventory deltas. Transfer types are enum
-- stubs only for V1.5 planning; no transfer behavior exists in this slice.
-- (source: RI1, RI3, RI10)
-- ============================================================
CREATE TABLE public.stock_movements (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id      UUID NOT NULL REFERENCES public.companies(id),
  branch_id       UUID NOT NULL,
  variant_id      UUID NOT NULL,
  lot_id          UUID NOT NULL,
  movement_type   TEXT NOT NULL CHECK (
    movement_type IN (
      'purchase_receipt',
      'sale',
      'sale_return',
      'adjustment_increase',
      'adjustment_decrease',
      'waste',
      'expiration',
      'transfer_in',
      'transfer_out'
    )
  ),
  delta_qty       NUMERIC(14, 3) NOT NULL CHECK (
    delta_qty <> 0
    AND (
      (movement_type IN ('purchase_receipt', 'sale_return', 'adjustment_increase', 'transfer_in') AND delta_qty > 0)
      OR
      (movement_type IN ('sale', 'adjustment_decrease', 'waste', 'expiration', 'transfer_out') AND delta_qty < 0)
    )
  ),
  reference_type  TEXT,
  reference_id    UUID,
  reason          TEXT,
  notes           TEXT,
  is_active       BOOLEAN NOT NULL DEFAULT TRUE,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_by      UUID NOT NULL,
  updated_by      UUID,
  deleted_at      TIMESTAMPTZ,
  deleted_by      UUID
);

COMMENT ON TABLE public.stock_movements IS 'Append-only inventory movement ledger. Every stock change must be traceable here. (source: RI1, RI3)';
COMMENT ON COLUMN public.stock_movements.delta_qty IS 'Positive for increases and negative for decreases. Sign must match movement_type. (source: RI3)';

CREATE INDEX idx_stock_movements_company_id ON public.stock_movements(company_id);
CREATE INDEX idx_stock_movements_branch_id ON public.stock_movements(branch_id);
CREATE INDEX idx_stock_movements_variant_id ON public.stock_movements(variant_id);
CREATE INDEX idx_stock_movements_lot_id ON public.stock_movements(lot_id);
CREATE INDEX idx_stock_movements_type_created_at
  ON public.stock_movements(movement_type, created_at DESC);

ALTER TABLE public.stock_movements
  ADD CONSTRAINT fk_stock_movements_branch_same_company
  FOREIGN KEY (company_id, branch_id) REFERENCES public.branches(company_id, id);

ALTER TABLE public.stock_movements
  ADD CONSTRAINT fk_stock_movements_variant_same_company
  FOREIGN KEY (company_id, variant_id) REFERENCES public.product_variants(company_id, id);

ALTER TABLE public.stock_movements
  ADD CONSTRAINT fk_stock_movements_lot_same_inventory_scope
  FOREIGN KEY (company_id, branch_id, variant_id, lot_id)
  REFERENCES public.stock_lots(company_id, branch_id, variant_id, id);

-- ============================================================
-- TRIGGER: prevent_inventory_quantity_direct_edit()
-- Authenticated direct edits to remaining_qty/status are prohibited. Future
-- SECURITY DEFINER RPCs will run as the function owner and are allowed.
-- (source: RI1)
-- ============================================================
CREATE OR REPLACE FUNCTION public.prevent_inventory_quantity_direct_edit()
RETURNS TRIGGER AS $$
BEGIN
  IF current_user NOT IN ('postgres', 'service_role')
     AND (
       NEW.remaining_qty IS DISTINCT FROM OLD.remaining_qty
       OR NEW.status IS DISTINCT FROM OLD.status
     ) THEN
    RAISE EXCEPTION 'Direct stock quantity edits are prohibited; use inventory RPCs';
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION public.prevent_inventory_quantity_direct_edit() IS 'Trigger function: blocks direct authenticated changes to remaining_qty/status. SECURITY DEFINER inventory RPCs are allowed. (source: RI1)';

CREATE TRIGGER trg_stock_lots_block_direct_quantity_update
  BEFORE UPDATE ON public.stock_lots
  FOR EACH ROW EXECUTE FUNCTION public.prevent_inventory_quantity_direct_edit();

-- ============================================================
-- TRIGGER: prevent_stock_movements_mutation()
-- Enforces append-only semantics on the ledger.
-- (source: RI3)
-- ============================================================
CREATE OR REPLACE FUNCTION public.prevent_stock_movements_mutation()
RETURNS TRIGGER AS $$
BEGIN
  RAISE EXCEPTION 'stock_movements is append-only';
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION public.prevent_stock_movements_mutation() IS 'Trigger function: rejects UPDATE and DELETE on stock_movements. (source: RI3)';

CREATE TRIGGER trg_stock_movements_no_update
  BEFORE UPDATE ON public.stock_movements
  FOR EACH ROW EXECUTE FUNCTION public.prevent_stock_movements_mutation();

CREATE TRIGGER trg_stock_movements_no_delete
  BEFORE DELETE ON public.stock_movements
  FOR EACH ROW EXECUTE FUNCTION public.prevent_stock_movements_mutation();

-- ============================================================
-- INVENTORY VIEWS
-- v_stock_available returns physical_qty only in V1.
-- v_stock_expiring returns all active lots in FEFO order with NULL dates last.
-- (source: RI7)
-- ============================================================
CREATE VIEW public.v_stock_available
WITH (security_invoker = true) AS
SELECT
  company_id,
  branch_id,
  variant_id,
  SUM(remaining_qty) AS physical_qty
FROM public.stock_lots
WHERE is_active = TRUE
  AND status = 'active'
GROUP BY company_id, branch_id, variant_id;

COMMENT ON VIEW public.v_stock_available IS 'Physical stock by company + branch + variant. Reservations/committed stock are deferred beyond V1. (source: RI7)';

CREATE VIEW public.v_stock_expiring
WITH (security_invoker = true) AS
SELECT
  id,
  company_id,
  branch_id,
  variant_id,
  lot_code,
  expiration_date,
  remaining_qty,
  cost_per_unit,
  created_at
FROM public.stock_lots
WHERE is_active = TRUE
  AND status = 'active'
ORDER BY expiration_date ASC NULLS LAST, lot_code ASC NULLS LAST, id ASC;

COMMENT ON VIEW public.v_stock_expiring IS 'Active inventory lots ordered FEFO: nearest expiration first, NULL expiration last. Dashboard filters are deferred. (source: RI7)';

-- ============================================================
-- RLS: Enable and define policies for both inventory tables.
-- Authenticated users are read-only on base inventory tables; mutations must
-- flow through SECURITY DEFINER RPCs. Cashier remains branch-scoped read-only.
-- service_role: full bypass. No DELETE policies.
-- (source: RI8, RI9)
-- ============================================================
ALTER TABLE public.stock_lots ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.stock_movements ENABLE ROW LEVEL SECURITY;

CREATE POLICY "stock_lots_select_company_branch_scope"
  ON public.stock_lots FOR SELECT
  TO authenticated
  USING (
    company_id = public.get_company_id()
    AND (
      public.is_admin()
      OR branch_id = public.get_user_branch_id()
      OR EXISTS (
        SELECT 1
        FROM public.branch_users bu
        WHERE bu.user_id = auth.uid()
          AND bu.branch_id = stock_lots.branch_id
          AND bu.company_id = public.get_company_id()
          AND bu.is_active = TRUE
      )
    )
  );

CREATE POLICY "stock_lots_service_all"
  ON public.stock_lots FOR ALL
  TO service_role
  USING (TRUE)
  WITH CHECK (TRUE);

CREATE POLICY "stock_movements_select_company_branch_scope"
  ON public.stock_movements FOR SELECT
  TO authenticated
  USING (
    company_id = public.get_company_id()
    AND (
      public.is_admin()
      OR branch_id = public.get_user_branch_id()
      OR EXISTS (
        SELECT 1
        FROM public.branch_users bu
        WHERE bu.user_id = auth.uid()
          AND bu.branch_id = stock_movements.branch_id
          AND bu.company_id = public.get_company_id()
          AND bu.is_active = TRUE
      )
    )
  );

CREATE POLICY "stock_movements_service_all"
  ON public.stock_movements FOR ALL
  TO service_role
  USING (TRUE)
  WITH CHECK (TRUE);

-- ============================================================
-- GRANTS
-- Inventory reads go through SDK + RLS. Base-table mutations are restricted to
-- privileged contexts; authenticated callers must use hardened inventory RPCs.
-- No DELETE grant is provided in V1.
-- (source: RI8, RI9)
-- ============================================================
GRANT SELECT ON public.stock_lots TO anon, authenticated, service_role;
GRANT INSERT, UPDATE ON public.stock_lots TO service_role;

GRANT SELECT ON public.stock_movements TO anon, authenticated, service_role;
GRANT INSERT, UPDATE ON public.stock_movements TO service_role;

-- Inventory RLS policies consult branch assignments for cashier visibility.
GRANT SELECT ON public.branch_users TO authenticated, service_role;

GRANT SELECT ON public.v_stock_available TO anon, authenticated, service_role;
GRANT SELECT ON public.v_stock_expiring TO anon, authenticated, service_role;

-- ============================================================
-- HELPER: generate_inventory_lot_code(...)
-- Builds LOT-/ADJ-prefixed codes with branch-derived short code.
-- Caller retries on unique conflicts to remain concurrency-safe.
-- (source: RI5, RI6)
-- ============================================================
CREATE OR REPLACE FUNCTION public.generate_inventory_lot_code(
  p_company_id UUID,
  p_branch_id UUID,
  p_variant_id UUID,
  p_prefix TEXT DEFAULT 'LOT'
)
RETURNS TEXT
LANGUAGE plpgsql
SET search_path = public
AS $$
DECLARE
  v_branch_slug   TEXT;
  v_branch_short  TEXT;
  v_candidate     TEXT;
  v_attempt       INTEGER := 0;
  v_date_part     TEXT := to_char(current_date, 'YYYYMMDD');
BEGIN
  SELECT slug
  INTO v_branch_slug
  FROM public.branches
  WHERE id = p_branch_id
    AND company_id = p_company_id
    AND is_active = TRUE;

  IF v_branch_slug IS NULL THEN
    RAISE EXCEPTION 'branch_id not found, inactive, or not owned by your company';
  END IF;

  v_branch_short := upper(left(regexp_replace(v_branch_slug, '[^A-Za-z0-9]', '', 'g'), 8));
  IF COALESCE(v_branch_short, '') = '' THEN
    v_branch_short := 'BRANCH';
  END IF;

  LOOP
    v_attempt := v_attempt + 1;
    v_candidate := format('%s-%s-%s-%s', upper(p_prefix), v_branch_short, v_date_part, lpad(v_attempt::TEXT, 4, '0'));

    EXIT WHEN NOT EXISTS (
      SELECT 1
      FROM public.stock_lots
      WHERE company_id = p_company_id
        AND branch_id = p_branch_id
        AND variant_id = p_variant_id
        AND lot_code = v_candidate
    );

    IF v_attempt >= 9999 THEN
      RAISE EXCEPTION 'Unable to generate a unique lot_code for this branch and variant';
    END IF;
  END LOOP;

  RETURN v_candidate;
END;
$$;

COMMENT ON FUNCTION public.generate_inventory_lot_code(UUID, UUID, UUID, TEXT) IS 'Generates LOT-/ADJ-prefixed lot codes using branch slug + date + sequence. Caller retries on unique conflicts. (source: RI5, RI6)';

-- ============================================================
-- RPC: receive_purchase_lot(p JSONB)
-- Creates lot + purchase receipt movement atomically.
-- SECURITY DEFINER, validates caller/company/branch/variant ownership.
-- (source: RI2, RI3, RI5, RI8)
-- ============================================================
CREATE OR REPLACE FUNCTION public.receive_purchase_lot(p JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_company_id       UUID;
  v_branch_id        UUID;
  v_variant_id       UUID;
  v_lot_id           UUID;
  v_movement_id      UUID;
  v_qty              NUMERIC(14, 3);
  v_lot_code         TEXT;
  v_expiration_date  DATE;
  v_cost_per_unit    NUMERIC(12, 2);
  v_reference_id     UUID;
  v_auto_generated   BOOLEAN := FALSE;
BEGIN
  v_company_id := (p->>'company_id')::UUID;
  v_branch_id := (p->>'branch_id')::UUID;
  v_variant_id := (p->>'variant_id')::UUID;
  v_qty := (p->>'qty')::NUMERIC;

  IF v_company_id IS NULL THEN
    RAISE EXCEPTION 'company_id is required';
  END IF;
  IF v_company_id != public.get_company_id() THEN
    RAISE EXCEPTION 'company_id does not match authenticated user company';
  END IF;
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'Only admins can receive purchase lots';
  END IF;
  IF v_branch_id IS NULL THEN
    RAISE EXCEPTION 'branch_id is required';
  END IF;
  IF v_variant_id IS NULL THEN
    RAISE EXCEPTION 'variant_id is required';
  END IF;
  IF v_qty IS NULL OR v_qty <= 0 THEN
    RAISE EXCEPTION 'qty must be greater than zero';
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

  IF NOT EXISTS (
    SELECT 1
    FROM public.product_variants
    WHERE id = v_variant_id
      AND company_id = v_company_id
      AND is_active = TRUE
  ) THEN
    RAISE EXCEPTION 'variant_id not found, inactive, or not owned by your company';
  END IF;

  v_lot_code := NULLIF(btrim(p->>'lot_code'), '');
  v_auto_generated := v_lot_code IS NULL;
  v_expiration_date := (p->>'expiration_date')::DATE;
  v_cost_per_unit := (p->>'cost_per_unit')::NUMERIC;
  v_reference_id := (p->>'reference_id')::UUID;

  LOOP
    IF v_auto_generated THEN
      v_lot_code := public.generate_inventory_lot_code(v_company_id, v_branch_id, v_variant_id, 'LOT');
    END IF;

    BEGIN
      INSERT INTO public.stock_lots (
        company_id,
        branch_id,
        variant_id,
        lot_code,
        expiration_date,
        received_qty,
        remaining_qty,
        cost_per_unit,
        status,
        created_by,
        updated_by
      )
      VALUES (
        v_company_id,
        v_branch_id,
        v_variant_id,
        v_lot_code,
        v_expiration_date,
        v_qty,
        v_qty,
        v_cost_per_unit,
        CASE
          WHEN v_expiration_date IS NOT NULL AND v_expiration_date < current_date THEN 'expired'
          ELSE 'active'
        END,
        auth.uid(),
        auth.uid()
      )
      RETURNING id INTO v_lot_id;

      EXIT;
    EXCEPTION
      WHEN unique_violation THEN
        IF v_auto_generated THEN
          CONTINUE;
        END IF;
        RAISE EXCEPTION 'lot_code already exists for this company, branch, and variant';
    END;
  END LOOP;

  INSERT INTO public.stock_movements (
    company_id,
    branch_id,
    variant_id,
    lot_id,
    movement_type,
    delta_qty,
    reference_type,
    reference_id,
    notes,
    created_by,
    updated_by
  )
  VALUES (
    v_company_id,
    v_branch_id,
    v_variant_id,
    v_lot_id,
    'purchase_receipt',
    v_qty,
    NULLIF(btrim(p->>'reference_type'), ''),
    v_reference_id,
    NULLIF(btrim(p->>'notes'), ''),
    auth.uid(),
    auth.uid()
  )
  RETURNING id INTO v_movement_id;

  RETURN jsonb_build_object(
    'lot_id', v_lot_id,
    'lot_code', v_lot_code,
    'movement_id', v_movement_id,
    'qty', v_qty
  );
END;
$$;

COMMENT ON FUNCTION public.receive_purchase_lot(JSONB) IS 'Creates a stock lot and purchase_receipt movement atomically. Auto-generates LOT lot_code when omitted. (source: RI2, RI3, RI5, RI8)';

-- ============================================================
-- RPC: record_sale_return(p JSONB)
-- Returns stock into a specific lot and records a sale_return movement.
-- (source: RI3, RI8)
-- ============================================================
CREATE OR REPLACE FUNCTION public.record_sale_return(p JSONB)
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
  v_qty             NUMERIC(14, 3);
  v_reference_id    UUID;
  v_movement_id     UUID;
  v_expiration_date DATE;
BEGIN
  v_company_id := (p->>'company_id')::UUID;
  v_branch_id := (p->>'branch_id')::UUID;
  v_variant_id := (p->>'variant_id')::UUID;
  v_lot_id := (p->>'lot_id')::UUID;
  v_qty := (p->>'qty')::NUMERIC;
  v_reference_id := (p->>'reference_id')::UUID;

  IF v_company_id IS NULL THEN
    RAISE EXCEPTION 'company_id is required';
  END IF;
  IF v_company_id != public.get_company_id() THEN
    RAISE EXCEPTION 'company_id does not match authenticated user company';
  END IF;
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'Only admins can record sale returns';
  END IF;
  IF v_branch_id IS NULL THEN
    RAISE EXCEPTION 'branch_id is required';
  END IF;
  IF v_variant_id IS NULL THEN
    RAISE EXCEPTION 'variant_id is required';
  END IF;
  IF v_lot_id IS NULL THEN
    RAISE EXCEPTION 'lot_id is required';
  END IF;
  IF v_qty IS NULL OR v_qty <= 0 THEN
    RAISE EXCEPTION 'qty must be greater than zero';
  END IF;

  IF COALESCE(NULLIF(btrim(p->>'reference_type'), ''), '') IN ('transfer_in', 'transfer_out', 'transfer', 'reservation', 'reserve_stock', 'release_reservation') THEN
    RAISE EXCEPTION 'Transfer and reservation operations are not supported in V1';
  END IF;

  SELECT expiration_date
  INTO v_expiration_date
  FROM public.stock_lots
  WHERE id = v_lot_id
    AND company_id = v_company_id
    AND branch_id = v_branch_id
    AND variant_id = v_variant_id
    AND is_active = TRUE
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'lot_id not found, inactive, or not owned by your company';
  END IF;

  UPDATE public.stock_lots
  SET remaining_qty = remaining_qty + v_qty,
      status = CASE
        WHEN v_expiration_date IS NOT NULL AND v_expiration_date < current_date THEN 'expired'
        ELSE 'active'
      END,
      updated_by = auth.uid()
  WHERE id = v_lot_id;

  INSERT INTO public.stock_movements (
    company_id,
    branch_id,
    variant_id,
    lot_id,
    movement_type,
    delta_qty,
    reference_type,
    reference_id,
    notes,
    created_by,
    updated_by
  )
  VALUES (
    v_company_id,
    v_branch_id,
    v_variant_id,
    v_lot_id,
    'sale_return',
    v_qty,
    NULLIF(btrim(p->>'reference_type'), ''),
    v_reference_id,
    NULLIF(btrim(p->>'notes'), ''),
    auth.uid(),
    auth.uid()
  )
  RETURNING id INTO v_movement_id;

  RETURN jsonb_build_object(
    'lot_id', v_lot_id,
    'movement_id', v_movement_id,
    'qty', v_qty
  );
END;
$$;

COMMENT ON FUNCTION public.record_sale_return(JSONB) IS 'Returns stock into a specific lot and records a sale_return movement. (source: RI3, RI8)';

-- ============================================================
-- RPC: record_waste(p JSONB)
-- Deducts waste from a specific lot and records a waste movement.
-- (source: RI3, RI8)
-- ============================================================
CREATE OR REPLACE FUNCTION public.record_waste(p JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_company_id   UUID;
  v_branch_id    UUID;
  v_variant_id   UUID;
  v_lot_id       UUID;
  v_qty          NUMERIC(14, 3);
  v_reason       TEXT;
  v_movement_id  UUID;
  v_remaining    NUMERIC(14, 3);
BEGIN
  v_company_id := (p->>'company_id')::UUID;
  v_branch_id := (p->>'branch_id')::UUID;
  v_variant_id := (p->>'variant_id')::UUID;
  v_lot_id := (p->>'lot_id')::UUID;
  v_qty := (p->>'qty')::NUMERIC;
  v_reason := NULLIF(btrim(p->>'reason'), '');

  IF v_company_id IS NULL THEN
    RAISE EXCEPTION 'company_id is required';
  END IF;
  IF v_company_id != public.get_company_id() THEN
    RAISE EXCEPTION 'company_id does not match authenticated user company';
  END IF;
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'Only admins can record waste';
  END IF;
  IF v_branch_id IS NULL THEN
    RAISE EXCEPTION 'branch_id is required';
  END IF;
  IF v_variant_id IS NULL THEN
    RAISE EXCEPTION 'variant_id is required';
  END IF;
  IF v_lot_id IS NULL THEN
    RAISE EXCEPTION 'lot_id is required';
  END IF;
  IF v_qty IS NULL OR v_qty <= 0 THEN
    RAISE EXCEPTION 'qty must be greater than zero';
  END IF;
  IF v_reason IS NULL THEN
    RAISE EXCEPTION 'reason is required';
  END IF;

  SELECT remaining_qty
  INTO v_remaining
  FROM public.stock_lots
  WHERE id = v_lot_id
    AND company_id = v_company_id
    AND branch_id = v_branch_id
    AND variant_id = v_variant_id
    AND is_active = TRUE
    AND status = 'active'
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'lot_id not found, inactive, or unavailable for waste';
  END IF;
  IF v_remaining < v_qty THEN
    RAISE EXCEPTION 'Insufficient stock in the selected lot';
  END IF;

  UPDATE public.stock_lots
  SET remaining_qty = remaining_qty - v_qty,
      status = CASE
        WHEN remaining_qty - v_qty = 0 THEN 'depleted'
        ELSE status
      END,
      updated_by = auth.uid()
  WHERE id = v_lot_id;

  INSERT INTO public.stock_movements (
    company_id,
    branch_id,
    variant_id,
    lot_id,
    movement_type,
    delta_qty,
    reason,
    notes,
    created_by,
    updated_by
  )
  VALUES (
    v_company_id,
    v_branch_id,
    v_variant_id,
    v_lot_id,
    'waste',
    -v_qty,
    v_reason,
    NULLIF(btrim(p->>'notes'), ''),
    auth.uid(),
    auth.uid()
  )
  RETURNING id INTO v_movement_id;

  RETURN jsonb_build_object(
    'lot_id', v_lot_id,
    'movement_id', v_movement_id,
    'qty', v_qty
  );
END;
$$;

COMMENT ON FUNCTION public.record_waste(JSONB) IS 'Deducts waste from a specific lot and records a waste movement. (source: RI3, RI8)';

-- ============================================================
-- RPC: record_expiration(p JSONB)
-- Expires one lot or all expired lots in scope, recording negative movements.
-- Drift-safe: fully transactional, no partial expiration persists on failure.
-- (source: RI3, RI8)
-- ============================================================
CREATE OR REPLACE FUNCTION public.record_expiration(p JSONB)
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
  v_movement_id     UUID;
  v_movement_ids    JSONB := '[]'::JSONB;
  v_expired_lots    JSONB := '[]'::JSONB;
  v_expired_count   INTEGER := 0;
  v_lot             RECORD;
BEGIN
  v_company_id := (p->>'company_id')::UUID;
  v_branch_id := (p->>'branch_id')::UUID;
  v_variant_id := (p->>'variant_id')::UUID;
  v_lot_id := (p->>'lot_id')::UUID;

  IF v_company_id IS NULL THEN
    RAISE EXCEPTION 'company_id is required';
  END IF;
  IF v_company_id != public.get_company_id() THEN
    RAISE EXCEPTION 'company_id does not match authenticated user company';
  END IF;
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'Only admins can record expirations';
  END IF;
  IF v_branch_id IS NULL THEN
    RAISE EXCEPTION 'branch_id is required';
  END IF;
  IF v_variant_id IS NULL THEN
    RAISE EXCEPTION 'variant_id is required';
  END IF;

  FOR v_lot IN
    SELECT id, lot_code, remaining_qty, expiration_date
    FROM public.stock_lots
    WHERE company_id = v_company_id
      AND branch_id = v_branch_id
      AND variant_id = v_variant_id
      AND is_active = TRUE
      AND status = 'active'
      AND remaining_qty > 0
      AND expiration_date IS NOT NULL
      AND expiration_date < current_date
      AND (v_lot_id IS NULL OR id = v_lot_id)
    ORDER BY expiration_date ASC, lot_code ASC NULLS LAST, id ASC
    FOR UPDATE
  LOOP
    UPDATE public.stock_lots
    SET remaining_qty = 0,
        status = 'expired',
        updated_by = auth.uid()
    WHERE id = v_lot.id;

    INSERT INTO public.stock_movements (
      company_id,
      branch_id,
      variant_id,
      lot_id,
      movement_type,
      delta_qty,
      notes,
      created_by,
      updated_by
    )
    VALUES (
      v_company_id,
      v_branch_id,
      v_variant_id,
      v_lot.id,
      'expiration',
      -v_lot.remaining_qty,
      NULLIF(btrim(p->>'notes'), ''),
      auth.uid(),
      auth.uid()
    )
    RETURNING id INTO v_movement_id;

    v_expired_count := v_expired_count + 1;
    v_movement_ids := v_movement_ids || jsonb_build_array(v_movement_id);
    v_expired_lots := v_expired_lots || jsonb_build_array(jsonb_build_object(
      'lot_id', v_lot.id,
      'lot_code', v_lot.lot_code,
      'expired_qty', v_lot.remaining_qty
    ));
  END LOOP;

  IF v_expired_count = 0 THEN
    RAISE EXCEPTION 'No expirable stock was found for the requested scope';
  END IF;

  RETURN jsonb_build_object(
    'movement_ids', v_movement_ids,
    'expired_lots', v_expired_lots,
    'expired_count', v_expired_count
  );
END;
$$;

COMMENT ON FUNCTION public.record_expiration(JSONB) IS 'Expires one lot or all expired lots in scope and records expiration movements. (source: RI3, RI8)';

-- ============================================================
-- RPC: record_sale_deduction(p JSONB)
-- FEFO multi-lot deduction with row locks and full rollback on failure.
-- (source: RI4, RI8)
-- ============================================================
CREATE OR REPLACE FUNCTION public.record_sale_deduction(p JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_company_id        UUID;
  v_branch_id         UUID;
  v_variant_id        UUID;
  v_reference_id      UUID;
  v_requested_qty     NUMERIC(14, 3);
  v_remaining_to_take NUMERIC(14, 3);
  v_take_qty          NUMERIC(14, 3);
  v_movement_id       UUID;
  v_movement_ids      JSONB := '[]'::JSONB;
  v_lots_affected     JSONB := '[]'::JSONB;
  v_lot               RECORD;
BEGIN
  v_company_id := (p->>'company_id')::UUID;
  v_branch_id := (p->>'branch_id')::UUID;
  v_variant_id := (p->>'variant_id')::UUID;
  v_reference_id := (p->>'reference_id')::UUID;
  v_requested_qty := (p->>'qty')::NUMERIC;

  IF v_company_id IS NULL THEN
    RAISE EXCEPTION 'company_id is required';
  END IF;
  IF v_company_id != public.get_company_id() THEN
    RAISE EXCEPTION 'company_id does not match authenticated user company';
  END IF;
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'Only admins can record sale deductions';
  END IF;
  IF v_branch_id IS NULL THEN
    RAISE EXCEPTION 'branch_id is required';
  END IF;
  IF v_variant_id IS NULL THEN
    RAISE EXCEPTION 'variant_id is required';
  END IF;
  IF v_requested_qty IS NULL OR v_requested_qty <= 0 THEN
    RAISE EXCEPTION 'qty must be greater than zero';
  END IF;

  IF COALESCE(NULLIF(btrim(p->>'reference_type'), ''), '') IN ('transfer_in', 'transfer_out', 'transfer', 'reservation', 'reserve_stock', 'release_reservation') THEN
    RAISE EXCEPTION 'Transfer and reservation operations are not supported in V1';
  END IF;

  v_remaining_to_take := v_requested_qty;

  FOR v_lot IN
    SELECT id, lot_code, remaining_qty, expiration_date
    FROM public.stock_lots
    WHERE company_id = v_company_id
      AND branch_id = v_branch_id
      AND variant_id = v_variant_id
      AND is_active = TRUE
      AND status = 'active'
      AND remaining_qty > 0
    ORDER BY expiration_date ASC NULLS LAST, lot_code ASC NULLS LAST, id ASC
    FOR UPDATE
  LOOP
    EXIT WHEN v_remaining_to_take <= 0;

    v_take_qty := LEAST(v_lot.remaining_qty, v_remaining_to_take);

    UPDATE public.stock_lots
    SET remaining_qty = remaining_qty - v_take_qty,
        status = CASE
          WHEN remaining_qty - v_take_qty = 0 THEN 'depleted'
          ELSE status
        END,
        updated_by = auth.uid()
    WHERE id = v_lot.id;

    INSERT INTO public.stock_movements (
      company_id,
      branch_id,
      variant_id,
      lot_id,
      movement_type,
      delta_qty,
      reference_type,
      reference_id,
      notes,
      created_by,
      updated_by
    )
    VALUES (
      v_company_id,
      v_branch_id,
      v_variant_id,
      v_lot.id,
      'sale',
      -v_take_qty,
      NULLIF(btrim(p->>'reference_type'), ''),
      v_reference_id,
      NULLIF(btrim(p->>'notes'), ''),
      auth.uid(),
      auth.uid()
    )
    RETURNING id INTO v_movement_id;

    v_movement_ids := v_movement_ids || jsonb_build_array(v_movement_id);
    v_lots_affected := v_lots_affected || jsonb_build_array(jsonb_build_object(
      'lot_id', v_lot.id,
      'lot_code', v_lot.lot_code,
      'deducted_qty', v_take_qty
    ));
    v_remaining_to_take := v_remaining_to_take - v_take_qty;
  END LOOP;

  IF v_remaining_to_take > 0 THEN
    RAISE EXCEPTION 'Insufficient stock for the requested sale deduction';
  END IF;

  RETURN jsonb_build_object(
    'movement_ids', v_movement_ids,
    'lots_affected', v_lots_affected,
    'qty_deducted', v_requested_qty
  );
END;
$$;

COMMENT ON FUNCTION public.record_sale_deduction(JSONB) IS 'FEFO multi-lot sale deduction using row locks and append-only sale movements. (source: RI4, RI8)';

-- ============================================================
-- RPC: adjust_inventory(p JSONB)
-- Positive qty creates a traceable ADJ lot; negative qty uses FEFO.
-- (source: RI6, RI8)
-- ============================================================
CREATE OR REPLACE FUNCTION public.adjust_inventory(p JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_company_id        UUID;
  v_branch_id         UUID;
  v_variant_id        UUID;
  v_qty               NUMERIC(14, 3);
  v_reason            TEXT;
  v_cost_per_unit     NUMERIC(12, 2);
  v_lot_code          TEXT;
  v_lot_id            UUID;
  v_movement_id       UUID;
  v_movement_ids      JSONB := '[]'::JSONB;
  v_lots_affected     JSONB := '[]'::JSONB;
  v_remaining_to_take NUMERIC(14, 3);
  v_take_qty          NUMERIC(14, 3);
  v_lot               RECORD;
BEGIN
  v_company_id := (p->>'company_id')::UUID;
  v_branch_id := (p->>'branch_id')::UUID;
  v_variant_id := (p->>'variant_id')::UUID;
  v_qty := (p->>'qty')::NUMERIC;
  v_reason := NULLIF(btrim(p->>'reason'), '');
  v_cost_per_unit := (p->>'cost_per_unit')::NUMERIC;

  IF v_company_id IS NULL THEN
    RAISE EXCEPTION 'company_id is required';
  END IF;
  IF v_company_id != public.get_company_id() THEN
    RAISE EXCEPTION 'company_id does not match authenticated user company';
  END IF;
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'Only admins can adjust inventory';
  END IF;
  IF v_branch_id IS NULL THEN
    RAISE EXCEPTION 'branch_id is required';
  END IF;
  IF v_variant_id IS NULL THEN
    RAISE EXCEPTION 'variant_id is required';
  END IF;
  IF v_qty IS NULL OR v_qty = 0 THEN
    RAISE EXCEPTION 'qty must be non-zero';
  END IF;
  IF v_reason IS NULL THEN
    RAISE EXCEPTION 'reason is required';
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

  IF NOT EXISTS (
    SELECT 1
    FROM public.product_variants
    WHERE id = v_variant_id
      AND company_id = v_company_id
      AND is_active = TRUE
  ) THEN
    RAISE EXCEPTION 'variant_id not found, inactive, or not owned by your company';
  END IF;

  IF v_qty > 0 THEN
    v_lot_code := NULLIF(btrim(p->>'lot_code'), '');
    IF v_lot_code IS NULL THEN
      v_lot_code := public.generate_inventory_lot_code(v_company_id, v_branch_id, v_variant_id, 'ADJ');
    ELSIF v_lot_code NOT LIKE 'ADJ-%' THEN
      RAISE EXCEPTION 'Adjustment lot_code must start with ADJ-';
    END IF;

    LOOP
      BEGIN
        INSERT INTO public.stock_lots (
          company_id,
          branch_id,
          variant_id,
          lot_code,
          expiration_date,
          received_qty,
          remaining_qty,
          cost_per_unit,
          status,
          created_by,
          updated_by
        )
        VALUES (
          v_company_id,
          v_branch_id,
          v_variant_id,
          v_lot_code,
          (p->>'expiration_date')::DATE,
          v_qty,
          v_qty,
          v_cost_per_unit,
          'active',
          auth.uid(),
          auth.uid()
        )
        RETURNING id INTO v_lot_id;

        EXIT;
      EXCEPTION
        WHEN unique_violation THEN
          IF p ? 'lot_code' THEN
            RAISE EXCEPTION 'Adjustment lot_code already exists for this company, branch, and variant';
          END IF;
          v_lot_code := public.generate_inventory_lot_code(v_company_id, v_branch_id, v_variant_id, 'ADJ');
      END;
    END LOOP;

    INSERT INTO public.stock_movements (
      company_id,
      branch_id,
      variant_id,
      lot_id,
      movement_type,
      delta_qty,
      reason,
      notes,
      created_by,
      updated_by
    )
    VALUES (
      v_company_id,
      v_branch_id,
      v_variant_id,
      v_lot_id,
      'adjustment_increase',
      v_qty,
      v_reason,
      NULLIF(btrim(p->>'notes'), ''),
      auth.uid(),
      auth.uid()
    )
    RETURNING id INTO v_movement_id;

    RETURN jsonb_build_object(
      'lot_id', v_lot_id,
      'lot_code', v_lot_code,
      'movement_id', v_movement_id,
      'qty', v_qty
    );
  END IF;

  v_remaining_to_take := abs(v_qty);

  FOR v_lot IN
    SELECT id, lot_code, remaining_qty, expiration_date
    FROM public.stock_lots
    WHERE company_id = v_company_id
      AND branch_id = v_branch_id
      AND variant_id = v_variant_id
      AND is_active = TRUE
      AND status = 'active'
      AND remaining_qty > 0
    ORDER BY expiration_date ASC NULLS LAST, lot_code ASC NULLS LAST, id ASC
    FOR UPDATE
  LOOP
    EXIT WHEN v_remaining_to_take <= 0;

    v_take_qty := LEAST(v_lot.remaining_qty, v_remaining_to_take);

    UPDATE public.stock_lots
    SET remaining_qty = remaining_qty - v_take_qty,
        status = CASE
          WHEN remaining_qty - v_take_qty = 0 THEN 'depleted'
          ELSE status
        END,
        updated_by = auth.uid()
    WHERE id = v_lot.id;

    INSERT INTO public.stock_movements (
      company_id,
      branch_id,
      variant_id,
      lot_id,
      movement_type,
      delta_qty,
      reason,
      notes,
      created_by,
      updated_by
    )
    VALUES (
      v_company_id,
      v_branch_id,
      v_variant_id,
      v_lot.id,
      'adjustment_decrease',
      -v_take_qty,
      v_reason,
      NULLIF(btrim(p->>'notes'), ''),
      auth.uid(),
      auth.uid()
    )
    RETURNING id INTO v_movement_id;

    v_movement_ids := v_movement_ids || jsonb_build_array(v_movement_id);
    v_lots_affected := v_lots_affected || jsonb_build_array(jsonb_build_object(
      'lot_id', v_lot.id,
      'lot_code', v_lot.lot_code,
      'deducted_qty', v_take_qty
    ));
    v_remaining_to_take := v_remaining_to_take - v_take_qty;
  END LOOP;

  IF v_remaining_to_take > 0 THEN
    RAISE EXCEPTION 'Insufficient stock for the requested inventory adjustment';
  END IF;

  RETURN jsonb_build_object(
    'movement_ids', v_movement_ids,
    'lots_affected', v_lots_affected,
    'qty', v_qty
  );
END;
$$;

COMMENT ON FUNCTION public.adjust_inventory(JSONB) IS 'Adjusts total inventory: positive qty creates an ADJ lot, negative qty deducts FEFO with row locks. (source: RI6, RI8)';

-- ============================================================
-- RPC: reconcile_inventory(p JSONB)
-- Reports drift between movement sums and cached remaining_qty. No auto-fix.
-- (source: RI6, RI10)
-- ============================================================
CREATE OR REPLACE FUNCTION public.reconcile_inventory(p JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_company_id    UUID;
  v_branch_id     UUID;
  v_variant_id    UUID;
  v_drift_rows    JSONB;
BEGIN
  v_company_id := (p->>'company_id')::UUID;
  v_branch_id := (p->>'branch_id')::UUID;
  v_variant_id := (p->>'variant_id')::UUID;

  IF v_company_id IS NULL THEN
    RAISE EXCEPTION 'company_id is required';
  END IF;
  IF v_company_id != public.get_company_id() THEN
    RAISE EXCEPTION 'company_id does not match authenticated user company';
  END IF;
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'Only admins can reconcile inventory';
  END IF;

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'lot_id', drift.lot_id,
        'company_id', drift.company_id,
        'branch_id', drift.branch_id,
        'variant_id', drift.variant_id,
        'expected', drift.expected_remaining,
        'actual', drift.actual_remaining,
        'drift', drift.actual_remaining - drift.expected_remaining
      )
      ORDER BY drift.branch_id, drift.variant_id, drift.lot_id
    ),
    '[]'::JSONB
  )
  INTO v_drift_rows
  FROM (
    SELECT
      l.id AS lot_id,
      l.company_id,
      l.branch_id,
      l.variant_id,
      COALESCE(SUM(m.delta_qty), 0::NUMERIC) AS expected_remaining,
      l.remaining_qty AS actual_remaining
    FROM public.stock_lots l
    LEFT JOIN public.stock_movements m
      ON m.lot_id = l.id
     AND m.company_id = l.company_id
     AND m.branch_id = l.branch_id
     AND m.variant_id = l.variant_id
    WHERE l.company_id = v_company_id
      AND (v_branch_id IS NULL OR l.branch_id = v_branch_id)
      AND (v_variant_id IS NULL OR l.variant_id = v_variant_id)
    GROUP BY l.id, l.company_id, l.branch_id, l.variant_id, l.remaining_qty
    HAVING COALESCE(SUM(m.delta_qty), 0::NUMERIC) <> l.remaining_qty
  ) AS drift;

  RETURN jsonb_build_object(
    'has_drift', jsonb_array_length(v_drift_rows) > 0,
    'drift_rows', v_drift_rows
  );
END;
$$;

COMMENT ON FUNCTION public.reconcile_inventory(JSONB) IS 'Reports drift between stock_movements sums and stock_lots.remaining_qty without auto-fixing in V1. (source: RI6, RI10)';

-- ============================================================
-- RPC stubs: reserve_stock / release_reservation
-- Explicit V1 rejection paths for deferred reservation operations.
-- (source: RI10)
-- ============================================================
CREATE OR REPLACE FUNCTION public.reserve_stock(p JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_company_id UUID;
BEGIN
  v_company_id := (p->>'company_id')::UUID;

  IF v_company_id IS NULL THEN
    RAISE EXCEPTION 'company_id is required';
  END IF;
  IF v_company_id != public.get_company_id() THEN
    RAISE EXCEPTION 'company_id does not match authenticated user company';
  END IF;
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'Only admins can reserve stock';
  END IF;

  RAISE EXCEPTION 'Reservations are not supported in V1';
END;
$$;

COMMENT ON FUNCTION public.reserve_stock(JSONB) IS 'V1 rejection stub for deferred reservation support. (source: RI10)';

CREATE OR REPLACE FUNCTION public.release_reservation(p JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_company_id UUID;
BEGIN
  v_company_id := (p->>'company_id')::UUID;

  IF v_company_id IS NULL THEN
    RAISE EXCEPTION 'company_id is required';
  END IF;
  IF v_company_id != public.get_company_id() THEN
    RAISE EXCEPTION 'company_id does not match authenticated user company';
  END IF;
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'Only admins can release reservations';
  END IF;

  RAISE EXCEPTION 'Reservations are not supported in V1';
END;
$$;

COMMENT ON FUNCTION public.release_reservation(JSONB) IS 'V1 rejection stub for deferred reservation release support. (source: RI10)';

-- ============================================================
-- RPC EXECUTE HARDENING
-- SECURITY DEFINER functions run with definer privileges, so EXECUTE must be
-- restricted explicitly.
-- (source: RI8, RI10)
-- ============================================================
REVOKE ALL ON FUNCTION public.generate_inventory_lot_code(UUID, UUID, UUID, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.generate_inventory_lot_code(UUID, UUID, UUID, TEXT) FROM anon;
REVOKE ALL ON FUNCTION public.generate_inventory_lot_code(UUID, UUID, UUID, TEXT) FROM authenticated;

REVOKE ALL ON FUNCTION public.receive_purchase_lot(JSONB) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.record_sale_return(JSONB) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.record_waste(JSONB) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.record_expiration(JSONB) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.record_sale_deduction(JSONB) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.adjust_inventory(JSONB) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.reconcile_inventory(JSONB) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.reserve_stock(JSONB) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.release_reservation(JSONB) FROM PUBLIC;

REVOKE ALL ON FUNCTION public.receive_purchase_lot(JSONB) FROM anon;
REVOKE ALL ON FUNCTION public.record_sale_return(JSONB) FROM anon;
REVOKE ALL ON FUNCTION public.record_waste(JSONB) FROM anon;
REVOKE ALL ON FUNCTION public.record_expiration(JSONB) FROM anon;
REVOKE ALL ON FUNCTION public.record_sale_deduction(JSONB) FROM anon;
REVOKE ALL ON FUNCTION public.adjust_inventory(JSONB) FROM anon;
REVOKE ALL ON FUNCTION public.reconcile_inventory(JSONB) FROM anon;
REVOKE ALL ON FUNCTION public.reserve_stock(JSONB) FROM anon;
REVOKE ALL ON FUNCTION public.release_reservation(JSONB) FROM anon;

GRANT EXECUTE ON FUNCTION public.receive_purchase_lot(JSONB) TO authenticated;
GRANT EXECUTE ON FUNCTION public.record_sale_return(JSONB) TO authenticated;
GRANT EXECUTE ON FUNCTION public.record_waste(JSONB) TO authenticated;
GRANT EXECUTE ON FUNCTION public.record_expiration(JSONB) TO authenticated;
GRANT EXECUTE ON FUNCTION public.record_sale_deduction(JSONB) TO authenticated;
GRANT EXECUTE ON FUNCTION public.adjust_inventory(JSONB) TO authenticated;
GRANT EXECUTE ON FUNCTION public.reconcile_inventory(JSONB) TO authenticated;
GRANT EXECUTE ON FUNCTION public.reserve_stock(JSONB) TO authenticated;
GRANT EXECUTE ON FUNCTION public.release_reservation(JSONB) TO authenticated;
