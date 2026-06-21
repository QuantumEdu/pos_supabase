-- Migration: 00011_returns_domain
-- Source: returns-domain spec (RR1–RR8), design (D1–D7)
-- Phase 1 — SQL foundation only (PR1 slice)
--
-- Creates: returns (header), return_items (line items with destination),
--          return_item_batches (lot traceability);
--          CHECK extensions on stock_movements + cash_movements (additive);
--          return_sale_item_transaction() SECURITY DEFINER RPC;
--          append-only / logical-delete triggers;
--          RLS policies + grants.
-- Mirrors established migration/RPC/RLS patterns from 00005/00008/00009/00010.

-- ============================================================================
-- Tables
-- ============================================================================

-- returns: return header
CREATE TABLE IF NOT EXISTS public.returns (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id      UUID NOT NULL REFERENCES public.companies(id),
  branch_id       UUID NOT NULL,
  sale_id         UUID NOT NULL,
  type            TEXT NOT NULL CHECK (type IN ('total','partial')),
  status          TEXT NOT NULL DEFAULT 'pending'
                  CHECK (status IN ('pending','approved','completed','rejected')),
  total_amount    NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (total_amount >= 0),
  reason          TEXT,
  authorized_by   UUID,
  is_active       BOOLEAN NOT NULL DEFAULT TRUE,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_by      UUID,
  updated_by      UUID,
  deleted_at      TIMESTAMPTZ,
  deleted_by      UUID
);

COMMENT ON TABLE public.returns IS 'Sale-return headers. Item-level returns with destination routing. Logical deletion only; physical DELETE prohibited. (source: RR1)';
COMMENT ON COLUMN public.returns.type IS 'total = whole sale returned; partial = subset of items. (source: RR1)';
COMMENT ON COLUMN public.returns.status IS 'pending → approved → completed | rejected. V1: RPC sets status directly (no trigger-enforced workflow). (source: RR1, design D7 open question)';
COMMENT ON COLUMN public.returns.authorized_by IS 'Admin user that authorized the return. (source: RR1)';

-- return_items: line items per return, each with a destination
CREATE TABLE IF NOT EXISTS public.return_items (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id     UUID NOT NULL REFERENCES public.companies(id),
  return_id      UUID NOT NULL,
  sale_item_id   UUID NOT NULL,
  variant_id     UUID NOT NULL,
  qty            NUMERIC(12,3) NOT NULL CHECK (qty > 0),
  destination    TEXT NOT NULL CHECK (destination IN ('inventario','merma','garantia','desecho')),
  unit_price     NUMERIC(12,2) NOT NULL CHECK (unit_price >= 0),
  subtotal       NUMERIC(12,2) NOT NULL CHECK (subtotal >= 0),
  is_active      BOOLEAN NOT NULL DEFAULT TRUE,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_by     UUID,
  updated_by     UUID,
  deleted_at     TIMESTAMPTZ,
  deleted_by     UUID
);

COMMENT ON TABLE public.return_items IS 'Return line items. destination drives inventory routing. Append-only via RPC. (source: RR1, RR3)';
COMMENT ON COLUMN public.return_items.destination IS 'inventario → restock lot via adjust_inventory_stock; merma/garantia/desecho → single negative stock_movements row. (source: RR3)';

-- return_item_batches: lot traceability per return item (links back to sale_item_batches)
CREATE TABLE IF NOT EXISTS public.return_item_batches (
  id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id          UUID NOT NULL REFERENCES public.companies(id),
  return_item_id      UUID NOT NULL,
  original_batch_id   UUID NOT NULL,
  variant_id          UUID NOT NULL,
  qty                 NUMERIC(12,3) NOT NULL CHECK (qty > 0),
  is_active           BOOLEAN NOT NULL DEFAULT TRUE,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_by          UUID,
  updated_by          UUID,
  deleted_at          TIMESTAMPTZ,
  deleted_by          UUID
);

COMMENT ON TABLE public.return_item_batches IS 'Lot traceability for returned items. Each row references the original sale_item_batches lot. Append-only via RPC. (source: RR1)';

-- ============================================================================
-- Indexes
-- ============================================================================

-- Composite unique (company_id, id) — enables composite FK targets
CREATE UNIQUE INDEX IF NOT EXISTS idx_returns_company_id_id
  ON public.returns(company_id, id);

CREATE UNIQUE INDEX IF NOT EXISTS idx_return_items_company_id_id
  ON public.return_items(company_id, id);

CREATE UNIQUE INDEX IF NOT EXISTS idx_return_item_batches_company_id_id
  ON public.return_item_batches(company_id, id);

-- Lookup indexes
CREATE INDEX IF NOT EXISTS idx_returns_company_sale
  ON public.returns(company_id, sale_id);

CREATE INDEX IF NOT EXISTS idx_returns_company_branch_status
  ON public.returns(company_id, branch_id, status);

CREATE INDEX IF NOT EXISTS idx_return_items_company_return
  ON public.return_items(company_id, return_id);

CREATE INDEX IF NOT EXISTS idx_return_items_company_sale_item
  ON public.return_items(company_id, sale_item_id);

CREATE INDEX IF NOT EXISTS idx_return_item_batches_company_return_item
  ON public.return_item_batches(company_id, return_item_id);

CREATE INDEX IF NOT EXISTS idx_return_item_batches_company_orig_batch
  ON public.return_item_batches(company_id, original_batch_id);

-- ============================================================================
-- Composite Foreign Keys (enforce same-company reference integrity)
-- ============================================================================

-- returns → sales (composite FK on (company_id, sale_id))
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'fk_returns_sale_same_company'
  ) THEN
    ALTER TABLE public.returns
      ADD CONSTRAINT fk_returns_sale_same_company
      FOREIGN KEY (company_id, sale_id) REFERENCES public.sales(company_id, id);
  END IF;
END;
$$;

-- returns → branches (composite FK on (company_id, branch_id))
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'fk_returns_branch_same_company'
  ) THEN
    ALTER TABLE public.returns
      ADD CONSTRAINT fk_returns_branch_same_company
      FOREIGN KEY (company_id, branch_id) REFERENCES public.branches(company_id, id);
  END IF;
END;
$$;

-- return_items → returns (composite FK on (company_id, return_id))
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'fk_return_items_return_same_company'
  ) THEN
    ALTER TABLE public.return_items
      ADD CONSTRAINT fk_return_items_return_same_company
      FOREIGN KEY (company_id, return_id) REFERENCES public.returns(company_id, id);
  END IF;
END;
$$;

-- return_items → sale_items (composite FK on (company_id, sale_item_id))
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'fk_return_items_sale_item_same_company'
  ) THEN
    ALTER TABLE public.return_items
      ADD CONSTRAINT fk_return_items_sale_item_same_company
      FOREIGN KEY (company_id, sale_item_id) REFERENCES public.sale_items(company_id, id);
  END IF;
END;
$$;

-- return_item_batches → return_items (composite FK on (company_id, return_item_id))
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'fk_return_item_batches_return_item_same_company'
  ) THEN
    ALTER TABLE public.return_item_batches
      ADD CONSTRAINT fk_return_item_batches_return_item_same_company
      FOREIGN KEY (company_id, return_item_id) REFERENCES public.return_items(company_id, id);
  END IF;
END;
$$;

-- return_item_batches → sale_item_batches (composite FK on (company_id, original_batch_id))
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'fk_return_item_batches_orig_batch_same_company'
  ) THEN
    ALTER TABLE public.return_item_batches
      ADD CONSTRAINT fk_return_item_batches_orig_batch_same_company
      FOREIGN KEY (company_id, original_batch_id) REFERENCES public.sale_item_batches(company_id, id);
  END IF;
END;
$$;

-- ============================================================================
-- CHECK Constraint Extensions (RR7, D5) — additive, idempotent DO blocks
-- ============================================================================

-- stock_movements.movement_type: add waste_return, warranty_return, disposal_return
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'stock_movements_movement_type_check'
  ) THEN
    ALTER TABLE public.stock_movements
      DROP CONSTRAINT stock_movements_movement_type_check;
  END IF;
  ALTER TABLE public.stock_movements
    ADD CONSTRAINT stock_movements_movement_type_check
    CHECK (movement_type IN (
      'purchase_receipt','sale','sale_return','adjustment_increase',
      'adjustment_decrease','waste','expiration','transfer_in','transfer_out',
      'waste_return','warranty_return','disposal_return'
    ));
END;
$$;

-- stock_movements.delta_qty sign constraint:
-- waste_return/warranty_return/disposal_return are NEGATIVE (item leaves stock
-- permanently, no lot restock). sale_return stays positive (inventario restock).
-- NOTE: migration 00005 defined this as an INLINE CHECK, which Postgres auto-named
-- 'stock_movements_check'. We must DROP that legacy constraint so the expanded
-- 'stock_movements_delta_qty_check' below is the single source of truth; otherwise
-- both constraints would have to pass and the legacy one would reject the new
-- movement types. Idempotent.
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'stock_movements_check'
  ) THEN
    ALTER TABLE public.stock_movements
      DROP CONSTRAINT stock_movements_check;
  END IF;
  IF EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'stock_movements_delta_qty_check'
  ) THEN
    ALTER TABLE public.stock_movements
      DROP CONSTRAINT stock_movements_delta_qty_check;
  END IF;
  ALTER TABLE public.stock_movements
    ADD CONSTRAINT stock_movements_delta_qty_check
    CHECK (
      delta_qty <> 0
      AND (
        (movement_type IN ('purchase_receipt','sale_return','adjustment_increase','transfer_in')
         AND delta_qty > 0)
        OR
        (movement_type IN ('sale','adjustment_decrease','waste','expiration','transfer_out',
                           'waste_return','warranty_return','disposal_return')
         AND delta_qty < 0)
      )
    );
END;
$$;

-- cash_movements.movement_type: add sale_return_refund
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'cash_movements_movement_type_check'
  ) THEN
    ALTER TABLE public.cash_movements
      DROP CONSTRAINT cash_movements_movement_type_check;
  END IF;
  ALTER TABLE public.cash_movements
    ADD CONSTRAINT cash_movements_movement_type_check
    CHECK (movement_type IN ('opening_float','manual_cash_in','manual_cash_out','sale_return_refund'));
END;
$$;

-- cash_movements.amount: sale_return_refund follows the same rule as manual_cash_out
-- (positive amount, interpreted as a cash outflow).
-- NOTE: migration 00008 defined this as an INLINE CHECK, which Postgres auto-named
-- 'cash_movements_check'. We must DROP that legacy constraint so the expanded
-- 'cash_movements_amount_check' below is the single source of truth; otherwise
-- both constraints would have to pass and the legacy one would reject
-- 'sale_return_refund'. Idempotent.
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'cash_movements_check'
  ) THEN
    ALTER TABLE public.cash_movements
      DROP CONSTRAINT cash_movements_check;
  END IF;
  IF EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'cash_movements_amount_check'
  ) THEN
    ALTER TABLE public.cash_movements
      DROP CONSTRAINT cash_movements_amount_check;
  END IF;
  ALTER TABLE public.cash_movements
    ADD CONSTRAINT cash_movements_amount_check
    CHECK (
      amount >= 0
      AND (
        movement_type = 'opening_float'
        OR (movement_type IN ('manual_cash_in','manual_cash_out','sale_return_refund') AND amount > 0)
      )
    );
END;
$$;

-- ============================================================================
-- Append-only / logical-delete protection triggers
-- (source: RR1, D7)
--   returns:             physical DELETE blocked; UPDATE allowed (status transitions)
--   return_items:        append-only (UPDATE + DELETE blocked)
--   return_item_batches: append-only (UPDATE + DELETE blocked)
-- ============================================================================

CREATE OR REPLACE FUNCTION public.prevent_returns_delete()
RETURNS TRIGGER AS $$
BEGIN
  RAISE EXCEPTION 'returns uses logical deletion only';
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION public.prevent_return_items_mutation()
RETURNS TRIGGER AS $$
BEGIN
  RAISE EXCEPTION 'return_items is append-only via RPC';
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION public.prevent_return_item_batches_mutation()
RETURNS TRIGGER AS $$
BEGIN
  RAISE EXCEPTION 'return_item_batches is append-only via RPC';
END;
$$ LANGUAGE plpgsql;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger WHERE tgname = 'trg_returns_no_delete'
  ) THEN
    CREATE TRIGGER trg_returns_no_delete
      BEFORE DELETE ON public.returns
      FOR EACH ROW EXECUTE FUNCTION public.prevent_returns_delete();
  END IF;
END;
$$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger WHERE tgname = 'trg_return_items_no_update'
  ) THEN
    CREATE TRIGGER trg_return_items_no_update
      BEFORE UPDATE ON public.return_items
      FOR EACH ROW EXECUTE FUNCTION public.prevent_return_items_mutation();
  END IF;
END;
$$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger WHERE tgname = 'trg_return_items_no_delete'
  ) THEN
    CREATE TRIGGER trg_return_items_no_delete
      BEFORE DELETE ON public.return_items
      FOR EACH ROW EXECUTE FUNCTION public.prevent_return_items_mutation();
  END IF;
END;
$$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger WHERE tgname = 'trg_return_item_batches_no_update'
  ) THEN
    CREATE TRIGGER trg_return_item_batches_no_update
      BEFORE UPDATE ON public.return_item_batches
      FOR EACH ROW EXECUTE FUNCTION public.prevent_return_item_batches_mutation();
  END IF;
END;
$$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger WHERE tgname = 'trg_return_item_batches_no_delete'
  ) THEN
    CREATE TRIGGER trg_return_item_batches_no_delete
      BEFORE DELETE ON public.return_item_batches
      FOR EACH ROW EXECUTE FUNCTION public.prevent_return_item_batches_mutation();
  END IF;
END;
$$;

-- updated_at triggers
DO $$
DECLARE
  t TEXT;
BEGIN
  FOREACH t IN ARRAY ARRAY['returns', 'return_items', 'return_item_batches']
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
-- RPC: return_sale_item_transaction(p JSONB) → JSONB
-- SECURITY DEFINER. Atomically creates a return (header + items + batches),
-- reverses inventory per destination, and appends a cash refund movement for
-- the cash-paid portion when the return is completed.
-- (source: RR2, RR3, RR4, D4)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.return_sale_item_transaction(p JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_company_id      UUID;
  v_branch_id       UUID;
  v_actor_user_id   UUID;
  v_sale_id         UUID;
  v_type            TEXT;
  v_reason           TEXT;
  v_status          TEXT;
  v_items           JSONB;

  v_sale_status     TEXT;
  v_sale_branch_id  UUID;

  v_item            JSONB;
  v_batch           JSONB;
  v_batches         JSONB;
  v_sale_item_id    UUID;
  v_variant_id      UUID;
  v_qty             NUMERIC(12,3);
  v_destination     TEXT;
  v_unit_price      NUMERIC(12,2);
  v_subtotal        NUMERIC(12,2);
  v_original_batch_id UUID;
  v_batch_qty       NUMERIC(12,3);

  v_prev_returned   NUMERIC(12,3);
  v_available       NUMERIC(12,3);
  v_lot_id          UUID;
  v_batch_variant   UUID;

  v_total_amount    NUMERIC(12,2) := 0;
  v_return_id       UUID;
  v_return_item_id  UUID;

  v_cash_paid       NUMERIC(12,2) := 0;
  v_open_session_id UUID;
  v_refund_amount   NUMERIC(12,2);
  v_cash_movement_id UUID;
  v_adj_result      JSONB;
  v_neg_movement_type TEXT;
BEGIN
  v_company_id    := (p->>'company_id')::UUID;
  v_branch_id     := (p->>'branch_id')::UUID;
  v_actor_user_id := (p->>'actor_user_id')::UUID;
  v_sale_id       := (p->>'sale_id')::UUID;
  v_type          := p->>'type';
  v_reason        := NULLIF(btrim(p->>'reason'), '');
  v_status        := COALESCE(NULLIF(btrim(p->>'status'), ''), 'completed');
  v_items         := p->'items';

  -- Set JWT auth context so nested RPCs (adjust_inventory_stock) see the actor
  PERFORM set_config('request.jwt.claims', json_build_object(
    'sub', v_actor_user_id,
    'role', 'service_role',
    'app_metadata', json_build_object(
      'company_id', v_company_id,
      'role', 'admin'
    )
  )::text, true);

  -- ---- Required-field validation (pre-write; return clean JSON) -------------
  IF v_company_id IS NULL OR v_actor_user_id IS NULL
     OR v_sale_id IS NULL OR v_branch_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'code', 'VALIDATION_ERROR',
      'message', 'company_id, branch_id, actor_user_id, sale_id are required');
  END IF;
  IF v_type IS NULL OR v_type NOT IN ('total','partial') THEN
    RETURN jsonb_build_object('success', false, 'code', 'VALIDATION_ERROR',
      'message', 'type must be total or partial');
  END IF;
  IF v_status NOT IN ('pending','approved','completed','rejected') THEN
    RETURN jsonb_build_object('success', false, 'code', 'VALIDATION_ERROR',
      'message', 'status must be pending, approved, completed, or rejected');
  END IF;
  IF v_items IS NULL OR jsonb_typeof(v_items) <> 'array' OR jsonb_array_length(v_items) = 0 THEN
    RETURN jsonb_build_object('success', false, 'code', 'VALIDATION_ERROR',
      'message', 'items must be a non-empty array');
  END IF;

  -- ---- Authorization: admin-only -------------------------------------------
  IF NOT public.has_role(v_company_id, v_actor_user_id, 'admin') THEN
    RETURN jsonb_build_object('success', false, 'code', 'FORBIDDEN',
      'message', 'Only admins can process returns');
  END IF;

  -- ---- Read sale (must exist, not cancelled, return branch = sale branch) ---
  SELECT status, branch_id
    INTO v_sale_status, v_sale_branch_id
    FROM public.sales
   WHERE id = v_sale_id AND company_id = v_company_id AND is_active;

  IF v_sale_status IS NULL THEN
    RETURN jsonb_build_object('success', false, 'code', 'NOT_FOUND',
      'message', 'Sale not found');
  END IF;
  IF v_sale_status = 'cancelled' THEN
    RETURN jsonb_build_object('success', false, 'code', 'VALIDATION_ERROR',
      'message', 'Cannot return a cancelled sale');
  END IF;
  IF v_branch_id <> v_sale_branch_id THEN
    RETURN jsonb_build_object('success', false, 'code', 'VALIDATION_ERROR',
      'message', 'branch_id must match the sale branch');
  END IF;

  -- ---- Pre-validate cash session BEFORE any writes (RR4) --------------------
  -- A cash refund is only required when the sale had cash payments and the
  -- return is being completed. Credit-only sales never need a cash movement.
  SELECT COALESCE(SUM(amount), 0)
    INTO v_cash_paid
    FROM public.payments
   WHERE company_id = v_company_id
     AND sale_id = v_sale_id
     AND payment_method = 'cash'
     AND is_active = TRUE;

  IF v_cash_paid > 0 AND v_status = 'completed' THEN
    SELECT id INTO v_open_session_id
      FROM public.cash_sessions
     WHERE company_id = v_company_id
       AND branch_id = v_sale_branch_id
       AND status = 'open'
       AND is_active = TRUE
     ORDER BY opened_at DESC
     LIMIT 1;

    IF v_open_session_id IS NULL THEN
      RETURN jsonb_build_object('success', false, 'code', 'VALIDATION_ERROR',
        'message', 'No open cash session for this branch; cannot refund cash');
    END IF;
  END IF;

  -- ---- Validation pass: per item + per batch (all reads, no writes) ---------
  FOR v_item IN SELECT * FROM jsonb_array_elements(v_items) LOOP
    v_sale_item_id := (v_item->>'sale_item_id')::UUID;
    v_variant_id   := (v_item->>'variant_id')::UUID;
    v_qty          := (v_item->>'qty')::NUMERIC;
    v_destination  := v_item->>'destination';
    v_unit_price   := COALESCE((v_item->>'unit_price')::NUMERIC, 0);
    v_batches      := v_item->'batches';

    IF v_sale_item_id IS NULL OR v_variant_id IS NULL THEN
      RETURN jsonb_build_object('success', false, 'code', 'VALIDATION_ERROR',
        'message', 'sale_item_id and variant_id are required per item');
    END IF;
    IF v_qty IS NULL OR v_qty <= 0 THEN
      RETURN jsonb_build_object('success', false, 'code', 'VALIDATION_ERROR',
        'message', 'qty must be greater than zero');
    END IF;
    IF v_destination IS NULL OR v_destination NOT IN ('inventario','merma','garantia','desecho') THEN
      RETURN jsonb_build_object('success', false, 'code', 'VALIDATION_ERROR',
        'message', 'destination must be inventario, merma, garantia, or desecho');
    END IF;
    IF v_batches IS NULL OR jsonb_typeof(v_batches) <> 'array' OR jsonb_array_length(v_batches) = 0 THEN
      RETURN jsonb_build_object('success', false, 'code', 'VALIDATION_ERROR',
        'message', 'batches must be a non-empty array per item');
    END IF;

    -- sale_item must belong to this sale and match the variant
    IF NOT EXISTS (
      SELECT 1 FROM public.sale_items si
       WHERE si.id = v_sale_item_id
         AND si.company_id = v_company_id
         AND si.sale_id = v_sale_id
         AND si.variant_id = v_variant_id
         AND si.is_active = TRUE
    ) THEN
      RETURN jsonb_build_object('success', false, 'code', 'VALIDATION_ERROR',
        'message', 'sale_item_id does not belong to this sale or variant mismatch');
    END IF;

    -- qty available = sale_item.quantity - SUM(previously returned, non-rejected)
    SELECT si.quantity INTO v_available
      FROM public.sale_items si
     WHERE si.id = v_sale_item_id AND si.company_id = v_company_id;

    SELECT COALESCE(SUM(ri.qty), 0)
      INTO v_prev_returned
      FROM public.return_items ri
      JOIN public.returns r
        ON r.id = ri.return_id AND r.company_id = ri.company_id
     WHERE ri.sale_item_id = v_sale_item_id
       AND ri.company_id = v_company_id
       AND ri.is_active = TRUE
       AND r.is_active = TRUE
       AND r.status <> 'rejected';

    v_available := v_available - v_prev_returned;
    IF v_qty > v_available THEN
      RETURN jsonb_build_object('success', false, 'code', 'VALIDATION_ERROR',
        'message', 'Return qty exceeds available (sold - previously returned)');
    END IF;

    -- validate each batch references a real sale_item_batches row for this sale_item
    FOR v_batch IN SELECT * FROM jsonb_array_elements(v_batches) LOOP
      v_original_batch_id := (v_batch->>'original_batch_id')::UUID;
      v_batch_qty         := (v_batch->>'qty')::NUMERIC;

      IF v_original_batch_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'code', 'VALIDATION_ERROR',
          'message', 'original_batch_id is required per batch');
      END IF;
      IF v_batch_qty IS NULL OR v_batch_qty <= 0 THEN
        RETURN jsonb_build_object('success', false, 'code', 'VALIDATION_ERROR',
          'message', 'batch qty must be greater than zero');
      END IF;

      SELECT sib.lot_id, si.variant_id
        INTO v_lot_id, v_batch_variant
        FROM public.sale_item_batches sib
        JOIN public.sale_items si
          ON si.id = sib.sale_item_id AND si.company_id = sib.company_id
       WHERE sib.id = v_original_batch_id
         AND sib.company_id = v_company_id
         AND sib.sale_item_id = v_sale_item_id
         AND sib.is_active = TRUE;

      IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'code', 'VALIDATION_ERROR',
          'message', 'original_batch_id not found for this sale item');
      END IF;
      IF v_batch_variant <> v_variant_id THEN
        RETURN jsonb_build_object('success', false, 'code', 'VALIDATION_ERROR',
          'message', 'batch variant_id does not match the sale item variant');
      END IF;
    END LOOP;
  END LOOP;

  -- ---- Write pass: any failure here RAISEs → full rollback ------------------

  -- Insert return header
  INSERT INTO public.returns (
    company_id, branch_id, sale_id, type, status, total_amount,
    reason, authorized_by, created_by, updated_by
  ) VALUES (
    v_company_id, v_branch_id, v_sale_id, v_type, v_status, 0,
    v_reason, v_actor_user_id, v_actor_user_id, v_actor_user_id
  )
  RETURNING id INTO v_return_id;

  -- Process each item
  FOR v_item IN SELECT * FROM jsonb_array_elements(v_items) LOOP
    v_sale_item_id := (v_item->>'sale_item_id')::UUID;
    v_variant_id   := (v_item->>'variant_id')::UUID;
    v_qty          := (v_item->>'qty')::NUMERIC;
    v_destination  := v_item->>'destination';
    v_unit_price   := COALESCE((v_item->>'unit_price')::NUMERIC, 0);
    v_batches      := v_item->'batches';
    v_subtotal     := ROUND(v_qty * v_unit_price, 2);
    v_total_amount := v_total_amount + v_subtotal;

    INSERT INTO public.return_items (
      company_id, return_id, sale_item_id, variant_id, qty,
      destination, unit_price, subtotal, created_by, updated_by
    ) VALUES (
      v_company_id, v_return_id, v_sale_item_id, v_variant_id, v_qty,
      v_destination, v_unit_price, v_subtotal, v_actor_user_id, v_actor_user_id
    )
    RETURNING id INTO v_return_item_id;

    -- Persist batch traceability + route inventory
    FOR v_batch IN SELECT * FROM jsonb_array_elements(v_batches) LOOP
      v_original_batch_id := (v_batch->>'original_batch_id')::UUID;
      v_batch_qty         := (v_batch->>'qty')::NUMERIC;

      SELECT sib.lot_id INTO v_lot_id
        FROM public.sale_item_batches sib
       WHERE sib.id = v_original_batch_id
         AND sib.company_id = v_company_id;

      INSERT INTO public.return_item_batches (
        company_id, return_item_id, original_batch_id, variant_id, qty,
        created_by, updated_by
      ) VALUES (
        v_company_id, v_return_item_id, v_original_batch_id, v_variant_id, v_batch_qty,
        v_actor_user_id, v_actor_user_id
      );

      IF v_destination = 'inventario' THEN
        -- Restock the original lot with a positive sale_return movement
        v_adj_result := public.adjust_inventory_stock(jsonb_build_object(
          'company_id', v_company_id,
          'branch_id', v_sale_branch_id,
          'variant_id', v_variant_id,
          'lot_id', v_lot_id,
          'quantity', v_batch_qty,
          'movement_type', 'sale_return',
          'reference_type', 'return',
          'reference_id', v_return_id,
          'actor_user_id', v_actor_user_id
        ));

        IF (v_adj_result->>'success') IS DISTINCT FROM 'true' THEN
          RAISE EXCEPTION 'Inventory restock failed for lot %: %',
            v_lot_id, v_adj_result->>'message';
        END IF;
      END IF;
    END LOOP;

    -- Non-inventario destinations: a SINGLE negative stock_movements row per
    -- return_item (no lot restock). lot_id is taken from the first batch for
    -- FK traceability; remaining_qty is NOT changed. (source: RR3, D2)
    IF v_destination <> 'inventario' THEN
      v_neg_movement_type := CASE v_destination
        WHEN 'merma'    THEN 'waste_return'
        WHEN 'garantia' THEN 'warranty_return'
        WHEN 'desecho'  THEN 'disposal_return'
      END;

      -- (re)fetch a valid lot_id for the composite FK on stock_movements
      SELECT sib.lot_id INTO v_lot_id
        FROM public.sale_item_batches sib
        JOIN public.sale_items si
          ON si.id = sib.sale_item_id AND si.company_id = sib.company_id
       WHERE sib.id = ((v_batches->0)->>'original_batch_id')::UUID
         AND sib.company_id = v_company_id;

      INSERT INTO public.stock_movements (
        company_id, branch_id, variant_id, lot_id, movement_type,
        delta_qty, reference_type, reference_id, reason, created_by, updated_by
      ) VALUES (
        v_company_id, v_sale_branch_id, v_variant_id, v_lot_id, v_neg_movement_type,
        -v_qty, 'return', v_return_id, v_reason,
        v_actor_user_id, v_actor_user_id
      );
    END IF;
  END LOOP;

  -- Update header total now that all subtotals are known
  UPDATE public.returns
     SET total_amount = v_total_amount,
         updated_by = v_actor_user_id
   WHERE id = v_return_id;

  -- ---- Cash reversal (RR4) -------------------------------------------------
  IF v_cash_paid > 0 AND v_status = 'completed' THEN
    -- Refund is limited to the cash-paid portion of the returned subtotal.
    v_refund_amount := LEAST(v_total_amount, v_cash_paid);

    IF v_refund_amount > 0 THEN
      INSERT INTO public.cash_movements (
        company_id, branch_id, cash_session_id, movement_type, amount,
        reference_type, reference_id, reason, created_by, updated_by
      ) VALUES (
        v_company_id, v_sale_branch_id, v_open_session_id, 'sale_return_refund',
        v_refund_amount, 'return', v_return_id, v_reason,
        v_actor_user_id, v_actor_user_id
      )
      RETURNING id INTO v_cash_movement_id;

      -- Refund is a cash outflow: decrement expected_cash_amount
      UPDATE public.cash_sessions
         SET expected_cash_amount = expected_cash_amount - v_refund_amount,
             updated_by = v_actor_user_id
       WHERE id = v_open_session_id;
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'data', jsonb_build_object(
      'return_id', v_return_id,
      'sale_id', v_sale_id,
      'status', v_status,
      'total_amount', v_total_amount,
      'cash_refund', COALESCE(v_refund_amount, 0),
      'cash_movement_id', v_cash_movement_id
    )
  );
END;
$$;

COMMENT ON FUNCTION public.return_sale_item_transaction(JSONB) IS 'SECURITY DEFINER return RPC. Atomically creates returns + reverses inventory per destination + appends a cash refund for the cash-paid portion. (source: RR2, RR3, RR4, D4)';

-- ============================================================================
-- RLS Policies + Grants
-- (source: RR5, D7)
-- Pattern: SELECT own company (admin all branches, others own branch) for
--          authenticated; admin-only INSERT/UPDATE via is_admin() policy;
--          no DELETE policy (logical deletion only); service_role full bypass.
-- ============================================================================

ALTER TABLE public.returns ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.return_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.return_item_batches ENABLE ROW LEVEL SECURITY;

-- returns: company-scoped SELECT
DROP POLICY IF EXISTS "returns_select_company_scope" ON public.returns;
CREATE POLICY "returns_select_company_scope"
  ON public.returns FOR SELECT
  TO authenticated
  USING (
    company_id = public.get_company_id()
    AND (
      public.is_admin()
      OR branch_id = public.get_user_branch_id()
      OR EXISTS (
        SELECT 1 FROM public.branch_users bu
        WHERE bu.user_id = auth.uid()
          AND bu.branch_id = returns.branch_id
          AND bu.company_id = public.get_company_id()
          AND bu.is_active = TRUE
      )
    )
  );

-- returns: admin-only INSERT
DROP POLICY IF EXISTS "returns_insert_admin" ON public.returns;
CREATE POLICY "returns_insert_admin"
  ON public.returns FOR INSERT
  TO authenticated
  WITH CHECK (company_id = public.get_company_id() AND public.is_admin());

-- returns: admin-only UPDATE (status transitions)
DROP POLICY IF EXISTS "returns_update_admin" ON public.returns;
CREATE POLICY "returns_update_admin"
  ON public.returns FOR UPDATE
  TO authenticated
  USING (company_id = public.get_company_id() AND public.is_admin())
  WITH CHECK (company_id = public.get_company_id() AND public.is_admin());

-- returns: service_role full bypass
DROP POLICY IF EXISTS "returns_service_all" ON public.returns;
CREATE POLICY "returns_service_all"
  ON public.returns FOR ALL
  TO service_role
  USING (TRUE)
  WITH CHECK (TRUE);

-- return_items: company-scoped SELECT
DROP POLICY IF EXISTS "return_items_select_company_scope" ON public.return_items;
CREATE POLICY "return_items_select_company_scope"
  ON public.return_items FOR SELECT
  TO authenticated
  USING (
    company_id = public.get_company_id()
    AND (
      public.is_admin()
      OR EXISTS (
        SELECT 1 FROM public.branch_users bu
        WHERE bu.user_id = auth.uid()
          AND bu.branch_id IN (SELECT r.branch_id FROM public.returns r
                                WHERE r.id = return_items.return_id
                                  AND r.company_id = return_items.company_id)
          AND bu.company_id = public.get_company_id()
          AND bu.is_active = TRUE
      )
    )
  );

DROP POLICY IF EXISTS "return_items_insert_admin" ON public.return_items;
CREATE POLICY "return_items_insert_admin"
  ON public.return_items FOR INSERT
  TO authenticated
  WITH CHECK (company_id = public.get_company_id() AND public.is_admin());

DROP POLICY IF EXISTS "return_items_update_admin" ON public.return_items;
CREATE POLICY "return_items_update_admin"
  ON public.return_items FOR UPDATE
  TO authenticated
  USING (company_id = public.get_company_id() AND public.is_admin())
  WITH CHECK (company_id = public.get_company_id() AND public.is_admin());

DROP POLICY IF EXISTS "return_items_service_all" ON public.return_items;
CREATE POLICY "return_items_service_all"
  ON public.return_items FOR ALL
  TO service_role
  USING (TRUE)
  WITH CHECK (TRUE);

-- return_item_batches: company-scoped SELECT
DROP POLICY IF EXISTS "return_item_batches_select_company_scope" ON public.return_item_batches;
CREATE POLICY "return_item_batches_select_company_scope"
  ON public.return_item_batches FOR SELECT
  TO authenticated
  USING (company_id = public.get_company_id());

DROP POLICY IF EXISTS "return_item_batches_insert_admin" ON public.return_item_batches;
CREATE POLICY "return_item_batches_insert_admin"
  ON public.return_item_batches FOR INSERT
  TO authenticated
  WITH CHECK (company_id = public.get_company_id() AND public.is_admin());

DROP POLICY IF EXISTS "return_item_batches_update_admin" ON public.return_item_batches;
CREATE POLICY "return_item_batches_update_admin"
  ON public.return_item_batches FOR UPDATE
  TO authenticated
  USING (company_id = public.get_company_id() AND public.is_admin())
  WITH CHECK (company_id = public.get_company_id() AND public.is_admin());

DROP POLICY IF EXISTS "return_item_batches_service_all" ON public.return_item_batches;
CREATE POLICY "return_item_batches_service_all"
  ON public.return_item_batches FOR ALL
  TO service_role
  USING (TRUE)
  WITH CHECK (TRUE);

-- ============================================================================
-- Grants
-- (source: RR5, task 1.4)
--   anon/authenticated/service_role: SELECT
--   authenticated/service_role: INSERT/UPDATE (admin writes gated by is_admin())
--   No DELETE grants — logical deletion only.
-- ============================================================================
GRANT SELECT ON public.returns TO anon, authenticated, service_role;
GRANT INSERT, UPDATE ON public.returns TO authenticated, service_role;

GRANT SELECT ON public.return_items TO anon, authenticated, service_role;
GRANT INSERT, UPDATE ON public.return_items TO authenticated, service_role;

GRANT SELECT ON public.return_item_batches TO anon, authenticated, service_role;
GRANT INSERT, UPDATE ON public.return_item_batches TO authenticated, service_role;

-- ============================================================================
-- RPC EXECUTE hardening
-- ============================================================================
REVOKE ALL ON FUNCTION public.return_sale_item_transaction(JSONB) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.return_sale_item_transaction(JSONB) TO authenticated, service_role;