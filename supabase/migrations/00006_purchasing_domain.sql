-- Migration: 00006_purchasing_domain
-- Source: purchasing-domain spec, Phase 1 — Schema + RLS + pgTAP constraints
-- Requirements: R3 (RLS-first multi-tenant), R5 (traceability + logical deletion)

-- ============================================================
-- A) ALTER product_variants: ADD last_cost column (idempotent)
-- ============================================================
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'product_variants'
      AND column_name = 'last_cost'
  ) THEN
    ALTER TABLE public.product_variants ADD COLUMN last_cost NUMERIC(12,2);
  END IF;
END;
$$;

COMMENT ON COLUMN public.product_variants.last_cost IS 'Most recent unit cost from purchase receipts. Updated atomically on receipt.';

-- ============================================================
-- B1) SUPPLIERS
-- ============================================================
CREATE TABLE IF NOT EXISTS public.suppliers (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id  UUID NOT NULL REFERENCES public.companies(id),
  name        TEXT NOT NULL,
  slug        TEXT NOT NULL,
  tax_id      TEXT,
  contact_name TEXT,
  phone       TEXT,
  email       TEXT,
  address     TEXT,
  notes       TEXT,
  is_active   BOOLEAN NOT NULL DEFAULT TRUE,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  deleted_at  TIMESTAMPTZ,
  created_by  UUID,
  updated_by  UUID,
  deleted_by  UUID,

  UNIQUE(company_id, slug)
);

COMMENT ON TABLE public.suppliers IS 'Company-scoped supplier master. Each company manages its own suppliers.';
COMMENT ON COLUMN public.suppliers.slug IS 'URL-safe identifier, unique per company.';

CREATE INDEX idx_suppliers_company_id ON public.suppliers(company_id);
CREATE UNIQUE INDEX idx_suppliers_company_id_id ON public.suppliers(company_id, id);

-- ============================================================
-- B2) PURCHASE_ORDERS
-- ============================================================
CREATE TABLE IF NOT EXISTS public.purchase_orders (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id      UUID NOT NULL REFERENCES public.companies(id),
  branch_id       UUID NOT NULL,
  supplier_id     UUID NOT NULL,
  order_number    TEXT NOT NULL,
  status          TEXT NOT NULL DEFAULT 'draft'
                    CHECK (status IN ('draft', 'sent', 'partial', 'received', 'cancelled')),
  order_date      DATE NOT NULL DEFAULT CURRENT_DATE,
  expected_date   DATE,
  payment_method  TEXT,
  subtotal        NUMERIC(12,2) NOT NULL DEFAULT 0,
  tax_total       NUMERIC(12,2) NOT NULL DEFAULT 0,
  total           NUMERIC(12,2) NOT NULL DEFAULT 0,
  notes           TEXT,
  is_active       BOOLEAN NOT NULL DEFAULT TRUE,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  deleted_at      TIMESTAMPTZ,
  created_by      UUID,
  updated_by      UUID,
  deleted_by      UUID,

  UNIQUE(company_id, order_number)
);

COMMENT ON TABLE public.purchase_orders IS 'Purchase orders with status lifecycle: draft → sent → partial → received → cancelled.';
COMMENT ON COLUMN public.purchase_orders.status IS 'Lifecycle: draft | sent | partial | received | cancelled.';

CREATE INDEX idx_purchase_orders_company_id ON public.purchase_orders(company_id);
CREATE INDEX idx_purchase_orders_branch_id ON public.purchase_orders(branch_id);
CREATE INDEX idx_purchase_orders_supplier_id ON public.purchase_orders(supplier_id);
CREATE UNIQUE INDEX idx_purchase_orders_company_id_id ON public.purchase_orders(company_id, id);

-- ============================================================
-- B3) PURCHASE_ORDER_ITEMS
-- ============================================================
CREATE TABLE IF NOT EXISTS public.purchase_order_items (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id        UUID NOT NULL REFERENCES public.companies(id),
  purchase_order_id UUID NOT NULL,
  variant_id        UUID NOT NULL,
  ordered_qty       NUMERIC(14,3) NOT NULL CHECK (ordered_qty > 0),
  received_qty      NUMERIC(14,3) NOT NULL DEFAULT 0 CHECK (received_qty >= 0),
  unit_cost         NUMERIC(12,2) NOT NULL,
  tax_rate          NUMERIC(6,4) NOT NULL DEFAULT 0,
  tax_amount        NUMERIC(12,2) NOT NULL DEFAULT 0,
  subtotal          NUMERIC(12,2) NOT NULL DEFAULT 0,
  is_active         BOOLEAN NOT NULL DEFAULT TRUE,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  deleted_at        TIMESTAMPTZ,
  created_by        UUID,
  updated_by        UUID,
  deleted_by        UUID,

  CHECK (received_qty <= ordered_qty)
);

COMMENT ON TABLE public.purchase_order_items IS 'Line items on purchase orders. received_qty tracks partial receipt progress.';
COMMENT ON COLUMN public.purchase_order_items.received_qty IS 'Cumulative quantity received. Must not exceed ordered_qty.';

CREATE INDEX idx_purchase_order_items_company_id ON public.purchase_order_items(company_id);
CREATE INDEX idx_purchase_order_items_po_id ON public.purchase_order_items(purchase_order_id);
CREATE INDEX idx_purchase_order_items_variant_id ON public.purchase_order_items(variant_id);
CREATE UNIQUE INDEX idx_purchase_order_items_company_id_id ON public.purchase_order_items(company_id, id);

-- ============================================================
-- B4) PURCHASE_RECEIPTS
-- ============================================================
CREATE TABLE IF NOT EXISTS public.purchase_receipts (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id        UUID NOT NULL REFERENCES public.companies(id),
  branch_id         UUID NOT NULL,
  purchase_order_id UUID NOT NULL,
  receipt_number    TEXT NOT NULL,
  receipt_date      DATE NOT NULL DEFAULT CURRENT_DATE,
  status            TEXT NOT NULL DEFAULT 'completed'
                      CHECK (status IN ('completed', 'cancelled')),
  notes             TEXT,
  is_active         BOOLEAN NOT NULL DEFAULT TRUE,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  deleted_at        TIMESTAMPTZ,
  created_by        UUID,
  updated_by        UUID,
  deleted_by        UUID,

  UNIQUE(company_id, receipt_number)
);

COMMENT ON TABLE public.purchase_receipts IS 'Goods received against purchase orders.';
COMMENT ON COLUMN public.purchase_receipts.status IS 'completed | cancelled.';

CREATE INDEX idx_purchase_receipts_company_id ON public.purchase_receipts(company_id);
CREATE INDEX idx_purchase_receipts_branch_id ON public.purchase_receipts(branch_id);
CREATE INDEX idx_purchase_receipts_po_id ON public.purchase_receipts(purchase_order_id);
CREATE UNIQUE INDEX idx_purchase_receipts_company_id_id ON public.purchase_receipts(company_id, id);

-- ============================================================
-- B5) PURCHASE_RECEIPT_ITEMS
-- ============================================================
CREATE TABLE IF NOT EXISTS public.purchase_receipt_items (
  id                   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id           UUID NOT NULL REFERENCES public.companies(id),
  purchase_receipt_id  UUID NOT NULL,
  purchase_order_item_id UUID NOT NULL,
  variant_id           UUID NOT NULL,
  received_qty         NUMERIC(14,3) NOT NULL CHECK (received_qty > 0),
  unit_cost            NUMERIC(12,2) NOT NULL,
  tax_rate             NUMERIC(6,4) NOT NULL DEFAULT 0,
  tax_amount           NUMERIC(12,2) NOT NULL DEFAULT 0,
  subtotal             NUMERIC(12,2) NOT NULL DEFAULT 0,
  lot_code             TEXT,
  expiration_date      DATE,
  is_active            BOOLEAN NOT NULL DEFAULT TRUE,
  created_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
  deleted_at           TIMESTAMPTZ,
  created_by           UUID,
  updated_by           UUID,
  deleted_by           UUID
);

COMMENT ON TABLE public.purchase_receipt_items IS 'Line items on purchase receipts. Each line corresponds to a purchase order item.';
COMMENT ON COLUMN public.purchase_receipt_items.lot_code IS 'Supplier lot code for traceability.';
COMMENT ON COLUMN public.purchase_receipt_items.expiration_date IS 'Expiration date from the supplier batch.';

CREATE INDEX idx_purchase_receipt_items_company_id ON public.purchase_receipt_items(company_id);
CREATE INDEX idx_purchase_receipt_items_receipt_id ON public.purchase_receipt_items(purchase_receipt_id);
CREATE INDEX idx_purchase_receipt_items_po_item_id ON public.purchase_receipt_items(purchase_order_item_id);
CREATE INDEX idx_purchase_receipt_items_variant_id ON public.purchase_receipt_items(variant_id);
CREATE UNIQUE INDEX idx_purchase_receipt_items_company_id_id ON public.purchase_receipt_items(company_id, id);

-- Ensure subtotal DEFAULT 0 on existing tables (idempotent)
DO $$
BEGIN
  ALTER TABLE public.purchase_receipt_items ALTER COLUMN subtotal SET DEFAULT 0;
EXCEPTION WHEN undefined_table THEN NULL;
END;
$$;

-- ============================================================
-- D) COMPOSITE FK CONSTRAINTS
-- Enforce same-company reference integrity across all relationships.
-- ============================================================

-- purchase_orders → branches
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'fk_purchase_orders_branch_same_company'
  ) THEN
    ALTER TABLE public.purchase_orders
      ADD CONSTRAINT fk_purchase_orders_branch_same_company
      FOREIGN KEY (company_id, branch_id) REFERENCES public.branches(company_id, id);
  END IF;
END;
$$;

-- purchase_orders → suppliers
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'fk_purchase_orders_supplier_same_company'
  ) THEN
    ALTER TABLE public.purchase_orders
      ADD CONSTRAINT fk_purchase_orders_supplier_same_company
      FOREIGN KEY (company_id, supplier_id) REFERENCES public.suppliers(company_id, id);
  END IF;
END;
$$;

-- purchase_order_items → purchase_orders
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'fk_purchase_order_items_po_same_company'
  ) THEN
    ALTER TABLE public.purchase_order_items
      ADD CONSTRAINT fk_purchase_order_items_po_same_company
      FOREIGN KEY (company_id, purchase_order_id) REFERENCES public.purchase_orders(company_id, id);
  END IF;
END;
$$;

-- purchase_order_items → product_variants
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'fk_purchase_order_items_variant_same_company'
  ) THEN
    ALTER TABLE public.purchase_order_items
      ADD CONSTRAINT fk_purchase_order_items_variant_same_company
      FOREIGN KEY (company_id, variant_id) REFERENCES public.product_variants(company_id, id);
  END IF;
END;
$$;

-- purchase_receipts → purchase_orders
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'fk_purchase_receipts_po_same_company'
  ) THEN
    ALTER TABLE public.purchase_receipts
      ADD CONSTRAINT fk_purchase_receipts_po_same_company
      FOREIGN KEY (company_id, purchase_order_id) REFERENCES public.purchase_orders(company_id, id);
  END IF;
END;
$$;

-- purchase_receipts → branches
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'fk_purchase_receipts_branch_same_company'
  ) THEN
    ALTER TABLE public.purchase_receipts
      ADD CONSTRAINT fk_purchase_receipts_branch_same_company
      FOREIGN KEY (company_id, branch_id) REFERENCES public.branches(company_id, id);
  END IF;
END;
$$;

-- purchase_receipt_items → purchase_receipts
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'fk_purchase_receipt_items_receipt_same_company'
  ) THEN
    ALTER TABLE public.purchase_receipt_items
      ADD CONSTRAINT fk_purchase_receipt_items_receipt_same_company
      FOREIGN KEY (company_id, purchase_receipt_id) REFERENCES public.purchase_receipts(company_id, id);
  END IF;
END;
$$;

-- purchase_receipt_items → purchase_order_items (composite FK to enforce same-company)
-- Drop old simple FK if it exists from earlier migration runs
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'fk_purchase_receipt_items_po_item'
  ) THEN
    ALTER TABLE public.purchase_receipt_items DROP CONSTRAINT fk_purchase_receipt_items_po_item;
  END IF;
END;
$$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'fk_pri_poi_same_company'
  ) THEN
    ALTER TABLE public.purchase_receipt_items
      ADD CONSTRAINT fk_pri_poi_same_company
      FOREIGN KEY (company_id, purchase_order_item_id) REFERENCES public.purchase_order_items(company_id, id);
  END IF;
END;
$$;

-- purchase_receipt_items → product_variants
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'fk_purchase_receipt_items_variant_same_company'
  ) THEN
    ALTER TABLE public.purchase_receipt_items
      ADD CONSTRAINT fk_purchase_receipt_items_variant_same_company
      FOREIGN KEY (company_id, variant_id) REFERENCES public.product_variants(company_id, id);
  END IF;
END;
$$;

-- ============================================================
-- E) set_updated_at TRIGGERS on all 5 tables
-- ============================================================
DO $$
DECLARE
  t TEXT;
BEGIN
  FOREACH t IN ARRAY ARRAY['suppliers', 'purchase_orders', 'purchase_order_items', 'purchase_receipts', 'purchase_receipt_items']
  LOOP
    EXECUTE format(
      'CREATE TRIGGER set_updated_at BEFORE UPDATE ON public.%I
       FOR EACH ROW EXECUTE FUNCTION public.set_updated_at()',
      t
    );
  END LOOP;
END;
$$;

-- ============================================================
-- F) RLS: Enable and define policies for all 5 purchasing tables
-- Pattern: SELECT own company, INSERT/UPDATE admin own company,
--          service_role full bypass. No DELETE policies.
-- ============================================================

-- Suppliers RLS
ALTER TABLE public.suppliers ENABLE ROW LEVEL SECURITY;

CREATE POLICY "suppliers_select_own"
  ON public.suppliers FOR SELECT
  TO authenticated
  USING (company_id = public.get_company_id());

CREATE POLICY "suppliers_insert_admin"
  ON public.suppliers FOR INSERT
  TO authenticated
  WITH CHECK (company_id = public.get_company_id() AND public.is_admin());

CREATE POLICY "suppliers_update_admin"
  ON public.suppliers FOR UPDATE
  TO authenticated
  USING (company_id = public.get_company_id() AND public.is_admin())
  WITH CHECK (company_id = public.get_company_id() AND public.is_admin());

CREATE POLICY "suppliers_service_all"
  ON public.suppliers FOR ALL
  TO service_role
  USING (TRUE) WITH CHECK (TRUE);

-- Purchase Orders RLS
ALTER TABLE public.purchase_orders ENABLE ROW LEVEL SECURITY;

CREATE POLICY "purchase_orders_select_own"
  ON public.purchase_orders FOR SELECT
  TO authenticated
  USING (company_id = public.get_company_id());

CREATE POLICY "purchase_orders_insert_admin"
  ON public.purchase_orders FOR INSERT
  TO authenticated
  WITH CHECK (company_id = public.get_company_id() AND public.is_admin());

CREATE POLICY "purchase_orders_update_admin"
  ON public.purchase_orders FOR UPDATE
  TO authenticated
  USING (company_id = public.get_company_id() AND public.is_admin())
  WITH CHECK (company_id = public.get_company_id() AND public.is_admin());

CREATE POLICY "purchase_orders_service_all"
  ON public.purchase_orders FOR ALL
  TO service_role
  USING (TRUE) WITH CHECK (TRUE);

-- Purchase Order Items RLS
ALTER TABLE public.purchase_order_items ENABLE ROW LEVEL SECURITY;

CREATE POLICY "purchase_order_items_select_own"
  ON public.purchase_order_items FOR SELECT
  TO authenticated
  USING (company_id = public.get_company_id());

CREATE POLICY "purchase_order_items_insert_admin"
  ON public.purchase_order_items FOR INSERT
  TO authenticated
  WITH CHECK (company_id = public.get_company_id() AND public.is_admin());

CREATE POLICY "purchase_order_items_update_admin"
  ON public.purchase_order_items FOR UPDATE
  TO authenticated
  USING (company_id = public.get_company_id() AND public.is_admin())
  WITH CHECK (company_id = public.get_company_id() AND public.is_admin());

CREATE POLICY "purchase_order_items_service_all"
  ON public.purchase_order_items FOR ALL
  TO service_role
  USING (TRUE) WITH CHECK (TRUE);

-- Purchase Receipts RLS
ALTER TABLE public.purchase_receipts ENABLE ROW LEVEL SECURITY;

CREATE POLICY "purchase_receipts_select_own"
  ON public.purchase_receipts FOR SELECT
  TO authenticated
  USING (company_id = public.get_company_id());

CREATE POLICY "purchase_receipts_insert_admin"
  ON public.purchase_receipts FOR INSERT
  TO authenticated
  WITH CHECK (company_id = public.get_company_id() AND public.is_admin());

CREATE POLICY "purchase_receipts_update_admin"
  ON public.purchase_receipts FOR UPDATE
  TO authenticated
  USING (company_id = public.get_company_id() AND public.is_admin())
  WITH CHECK (company_id = public.get_company_id() AND public.is_admin());

CREATE POLICY "purchase_receipts_service_all"
  ON public.purchase_receipts FOR ALL
  TO service_role
  USING (TRUE) WITH CHECK (TRUE);

-- Purchase Receipt Items RLS
ALTER TABLE public.purchase_receipt_items ENABLE ROW LEVEL SECURITY;

CREATE POLICY "purchase_receipt_items_select_own"
  ON public.purchase_receipt_items FOR SELECT
  TO authenticated
  USING (company_id = public.get_company_id());

CREATE POLICY "purchase_receipt_items_insert_admin"
  ON public.purchase_receipt_items FOR INSERT
  TO authenticated
  WITH CHECK (company_id = public.get_company_id() AND public.is_admin());

CREATE POLICY "purchase_receipt_items_update_admin"
  ON public.purchase_receipt_items FOR UPDATE
  TO authenticated
  USING (company_id = public.get_company_id() AND public.is_admin())
  WITH CHECK (company_id = public.get_company_id() AND public.is_admin());

CREATE POLICY "purchase_receipt_items_service_all"
  ON public.purchase_receipt_items FOR ALL
  TO service_role
  USING (TRUE) WITH CHECK (TRUE);

-- ============================================================
-- G) CRITICAL COLUMN PROTECTION TRIGGER
-- Blocks direct authenticated changes to status and received_qty.
-- SECURITY DEFINER RPCs running as postgres/service_role are allowed.
-- ============================================================
CREATE OR REPLACE FUNCTION public.prevent_purchasing_critical_col_direct_edit()
RETURNS TRIGGER AS $$
BEGIN
  IF current_user NOT IN ('postgres', 'service_role') THEN
    -- purchase_orders: protect status
    IF TG_TABLE_NAME = 'purchase_orders' THEN
      IF NEW.status IS DISTINCT FROM OLD.status THEN
        RAISE EXCEPTION 'Direct status edits on purchase_orders are prohibited; use purchasing RPCs';
      END IF;
    END IF;

    -- purchase_order_items: protect received_qty
    IF TG_TABLE_NAME = 'purchase_order_items' THEN
      IF NEW.received_qty IS DISTINCT FROM OLD.received_qty THEN
        RAISE EXCEPTION 'Direct received_qty edits on purchase_order_items are prohibited; use purchasing RPCs';
      END IF;
    END IF;
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION public.prevent_purchasing_critical_col_direct_edit() IS 'Trigger function: blocks direct authenticated changes to purchase_orders.status and purchase_order_items.received_qty. SECURITY DEFINER RPCs are allowed.';

CREATE TRIGGER trg_purchase_orders_block_critical
  BEFORE UPDATE ON public.purchase_orders
  FOR EACH ROW EXECUTE FUNCTION public.prevent_purchasing_critical_col_direct_edit();

CREATE TRIGGER trg_purchase_order_items_block_critical
  BEFORE UPDATE ON public.purchase_order_items
  FOR EACH ROW EXECUTE FUNCTION public.prevent_purchasing_critical_col_direct_edit();

-- ============================================================
-- H) GRANTS
-- ============================================================
GRANT SELECT, INSERT, UPDATE ON public.suppliers TO authenticated;
GRANT SELECT ON public.suppliers TO anon;
GRANT SELECT, INSERT ON public.suppliers TO service_role;

GRANT SELECT, INSERT, UPDATE ON public.purchase_orders TO authenticated;
GRANT SELECT ON public.purchase_orders TO anon;
GRANT SELECT ON public.purchase_orders TO service_role;

GRANT SELECT, INSERT, UPDATE ON public.purchase_order_items TO authenticated;
GRANT SELECT ON public.purchase_order_items TO anon;
GRANT SELECT, INSERT ON public.purchase_order_items TO service_role;

GRANT SELECT, INSERT, UPDATE ON public.purchase_receipts TO authenticated;
GRANT SELECT ON public.purchase_receipts TO anon;
GRANT SELECT ON public.purchase_receipts TO service_role;

GRANT SELECT, INSERT, UPDATE ON public.purchase_receipt_items TO authenticated;
GRANT SELECT ON public.purchase_receipt_items TO anon;
GRANT SELECT ON public.purchase_receipt_items TO service_role;

-- ============================================================
-- I) RPC: create_purchase_order(p JSONB)
-- Atomically inserts PO header + all items. Computes subtotal,
-- tax_total, total server-side. Sets status 'draft'.
-- SECURITY DEFINER, validates company/role/branch/supplier/variants.
-- ============================================================
CREATE OR REPLACE FUNCTION public.create_purchase_order(p JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_company_id    UUID;
  v_branch_id     UUID;
  v_supplier_id   UUID;
  v_order_number  TEXT;
  v_order_date    DATE;
  v_expected_date DATE;
  v_payment_method TEXT;
  v_notes         TEXT;
  v_items         JSONB;
  v_item          JSONB;
  v_po_id         UUID;
  v_variant_id    UUID;
  v_ordered_qty   NUMERIC(14,3);
  v_unit_cost     NUMERIC(12,2);
  v_tax_rate      NUMERIC(6,4);
  v_item_subtotal NUMERIC(12,2);
  v_item_tax_amt  NUMERIC(12,2);
  v_po_subtotal   NUMERIC(12,2) := 0;
  v_po_tax_total  NUMERIC(12,2) := 0;
  v_po_total      NUMERIC(12,2) := 0;
  v_items_count   INT := 0;
  v_item_idx      INT;
BEGIN
  v_company_id := (p->>'company_id')::UUID;
  v_branch_id := (p->>'branch_id')::UUID;
  v_supplier_id := (p->>'supplier_id')::UUID;
  v_order_number := btrim(p->>'order_number');
  v_order_date := COALESCE((p->>'order_date')::DATE, CURRENT_DATE);
  v_expected_date := (p->>'expected_date')::DATE;
  v_payment_method := NULLIF(btrim(p->>'payment_method'), '');
  v_notes := NULLIF(btrim(p->>'notes'), '');
  v_items := p->'items';

  -- Security: verify company and admin
  IF v_company_id IS NULL THEN
    RAISE EXCEPTION 'company_id is required';
  END IF;
  IF v_company_id != public.get_company_id() THEN
    RAISE EXCEPTION 'company_id does not match authenticated user company';
  END IF;
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'Only admins can create purchase orders';
  END IF;

  IF v_order_number IS NULL OR length(v_order_number) = 0 THEN
    RAISE EXCEPTION 'order_number is required';
  END IF;

  -- Items validation (checks before supplier/branch for correct error ordering)
  IF v_items IS NULL OR jsonb_array_length(v_items) = 0 THEN
    RAISE EXCEPTION 'At least one item is required';
  END IF;

  -- Validate branch exists, active, and belongs to company
  IF NOT EXISTS (
    SELECT 1 FROM public.branches
    WHERE id = v_branch_id AND company_id = v_company_id AND is_active = TRUE
  ) THEN
    RAISE EXCEPTION 'branch_id not found, inactive, or not owned by your company';
  END IF;

  -- Validate supplier exists, active, and belongs to company
  IF NOT EXISTS (
    SELECT 1 FROM public.suppliers
    WHERE id = v_supplier_id AND company_id = v_company_id AND is_active = TRUE
  ) THEN
    RAISE EXCEPTION 'supplier_id not found, inactive, or not owned by your company';
  END IF;

  -- First pass: validate all items and compute totals
  FOR v_item_idx IN 0..jsonb_array_length(v_items) - 1 LOOP
    v_item := v_items->v_item_idx;
    v_variant_id := (v_item->>'variant_id')::UUID;
    v_ordered_qty := (v_item->>'ordered_qty')::NUMERIC;

    IF v_ordered_qty IS NULL OR v_ordered_qty <= 0 THEN
      RAISE EXCEPTION 'ordered_qty must be greater than zero for item index %', v_item_idx;
    END IF;

    -- Validate variant exists, active, and belongs to company
    IF NOT EXISTS (
      SELECT 1 FROM public.product_variants
      WHERE id = v_variant_id AND company_id = v_company_id AND is_active = TRUE
    ) THEN
      RAISE EXCEPTION 'variant_id not found, inactive, or not owned by your company for item index %', v_item_idx;
    END IF;

    v_unit_cost := COALESCE((v_item->>'unit_cost')::NUMERIC, 0);
    v_tax_rate := COALESCE((v_item->>'tax_rate')::NUMERIC, 0);

    -- Server-computed item totals (client-supplied values ignored per spec RP2)
    v_item_subtotal := ROUND(v_ordered_qty * v_unit_cost, 2);
    v_item_tax_amt := ROUND(v_item_subtotal * v_tax_rate, 2);

    v_po_subtotal := v_po_subtotal + v_item_subtotal;
    v_po_tax_total := v_po_tax_total + v_item_tax_amt;
    v_items_count := v_items_count + 1;
  END LOOP;

  v_po_total := v_po_subtotal + v_po_tax_total;

  -- Insert PO header
  INSERT INTO public.purchase_orders (
    company_id, branch_id, supplier_id, order_number,
    status, order_date, expected_date, payment_method,
    subtotal, tax_total, total, notes, created_by
  ) VALUES (
    v_company_id, v_branch_id, v_supplier_id, v_order_number,
    'draft', v_order_date, v_expected_date, v_payment_method,
    v_po_subtotal, v_po_tax_total, v_po_total, v_notes, auth.uid()
  )
  RETURNING id INTO v_po_id;

  -- Insert PO items
  FOR v_item_idx IN 0..jsonb_array_length(v_items) - 1 LOOP
    v_item := v_items->v_item_idx;
    v_variant_id := (v_item->>'variant_id')::UUID;
    v_ordered_qty := (v_item->>'ordered_qty')::NUMERIC;
    v_unit_cost := COALESCE((v_item->>'unit_cost')::NUMERIC, 0);
    v_tax_rate := COALESCE((v_item->>'tax_rate')::NUMERIC, 0);
    v_item_subtotal := ROUND(v_ordered_qty * v_unit_cost, 2);
    v_item_tax_amt := ROUND(v_item_subtotal * v_tax_rate, 2);

    INSERT INTO public.purchase_order_items (
      company_id, purchase_order_id, variant_id,
      ordered_qty, received_qty, unit_cost,
      tax_rate, tax_amount, subtotal, created_by
    ) VALUES (
      v_company_id, v_po_id, v_variant_id,
      v_ordered_qty, 0, v_unit_cost,
      v_tax_rate, v_item_tax_amt, v_item_subtotal, auth.uid()
    );
  END LOOP;

  RETURN jsonb_build_object(
    'purchase_order_id', v_po_id,
    'order_number', v_order_number,
    'status', 'draft',
    'items_count', v_items_count,
    'total', v_po_total
  );
END;
$$;

COMMENT ON FUNCTION public.create_purchase_order(JSONB) IS 'Atomically creates a purchase order header + items with server-computed totals. Sets status draft. Validates branch, supplier, and variant ownership. (source: RP2, RP3, RP10)';

-- ============================================================
-- I) RPC: receive_purchase_transaction(p JSONB)
-- Master receipt RPC. In a single transaction: validates PO,
-- inserts receipt + receipt items, calls receive_purchase_lot
-- per item, updates received_qty on PO items, transitions PO
-- status. Uses SELECT FOR UPDATE for concurrency safety.
-- ============================================================
CREATE OR REPLACE FUNCTION public.receive_purchase_transaction(p JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_company_id     UUID;
  v_branch_id      UUID;
  v_po_id          UUID;
  v_receipt_number TEXT;
  v_receipt_date   DATE;
  v_notes          TEXT;
  v_items          JSONB;
  v_item           JSONB;
  v_po_status      TEXT;
  v_po_row         RECORD;
  v_po_item_row    RECORD;
  v_receipt_id     UUID;
  v_po_item_id     UUID;
  v_variant_id     UUID;
  v_received_qty   NUMERIC(14,3);
  v_lot_code       TEXT;
  v_expiration_date DATE;
  v_unit_cost      NUMERIC(12,2);
  v_tax_rate       NUMERIC(6,4);
  v_item_subtotal  NUMERIC(12,2);
  v_item_tax_amt   NUMERIC(12,2);
  v_lot_result     JSONB;
  v_lot_results    JSONB := '[]'::JSONB;
  v_items_processed INT := 0;
  v_item_idx       INT;
  v_all_received   BOOLEAN;
  v_new_qty        NUMERIC(14,3);
  v_po_item_rows   purchase_order_items[];
  v_existing_status TEXT;
  v_item_count     INT;
BEGIN
  v_company_id := (p->>'company_id')::UUID;
  v_branch_id := (p->>'branch_id')::UUID;
  v_po_id := (p->>'purchase_order_id')::UUID;
  v_receipt_number := btrim(p->>'receipt_number');
  v_receipt_date := COALESCE((p->>'receipt_date')::DATE, CURRENT_DATE);
  v_notes := NULLIF(btrim(p->>'notes'), '');
  v_items := p->'items';

  -- Security: verify company and admin
  IF v_company_id IS NULL THEN
    RAISE EXCEPTION 'company_id is required';
  END IF;
  IF v_company_id != public.get_company_id() THEN
    RAISE EXCEPTION 'company_id does not match authenticated user company';
  END IF;
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'Only admins can receive purchase orders';
  END IF;

  IF v_receipt_number IS NULL OR length(v_receipt_number) = 0 THEN
    RAISE EXCEPTION 'receipt_number is required';
  END IF;

  -- Validate branch exists and active
  IF NOT EXISTS (
    SELECT 1 FROM public.branches
    WHERE id = v_branch_id AND company_id = v_company_id AND is_active = TRUE
  ) THEN
    RAISE EXCEPTION 'branch_id not found, inactive, or not owned by your company';
  END IF;

  IF v_items IS NULL OR jsonb_array_length(v_items) = 0 THEN
    RAISE EXCEPTION 'At least one receipt item is required';
  END IF;

  -- Lock and validate PO header (must be in receivable state)
  SELECT id, status INTO v_po_row
  FROM public.purchase_orders
  WHERE id = v_po_id
    AND company_id = v_company_id
    AND is_active = TRUE
    AND status IN ('sent', 'partial')
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Purchase order not found, inactive, not owned by your company, or not in receivable state (must be sent or partial)';
  END IF;

  v_existing_status := v_po_row.status;

  -- Batch lock all target purchase_order_items in deterministic order.
  -- The PO header FOR UPDATE above acts as the primary mutex serializing
  -- concurrent receipts on the same PO. Item-level FOR UPDATE here ensures
  -- each item row is valid and its current received_qty is visible.
  -- Items are locked in ORDER BY id to prevent deadlocks.
  FOR v_po_item_row IN
    SELECT poi.id, poi.variant_id, poi.ordered_qty, poi.received_qty, poi.unit_cost, poi.tax_rate
    FROM public.purchase_order_items poi
    WHERE poi.id IN (
      SELECT (item->>'purchase_order_item_id')::UUID
      FROM jsonb_array_elements(v_items) AS item
    )
      AND poi.company_id = v_company_id
      AND poi.purchase_order_id = v_po_id
      AND poi.is_active = TRUE
    ORDER BY poi.id
    FOR UPDATE
  LOOP
    -- Sum received_qty from all input entries for this PO item (handles duplicates)
    SELECT COALESCE(SUM((item->>'received_qty')::NUMERIC), 0)
    INTO v_received_qty
    FROM jsonb_array_elements(v_items) AS item
    WHERE (item->>'purchase_order_item_id')::UUID = v_po_item_row.id;

    IF v_received_qty <= 0 THEN
      RAISE EXCEPTION 'received_qty must be greater than zero for purchase_order_item %', v_po_item_row.id;
    END IF;

    -- Validate: requested qty + already received <= ordered
    v_new_qty := v_po_item_row.received_qty + v_received_qty;
    IF v_new_qty > v_po_item_row.ordered_qty THEN
      RAISE EXCEPTION 'Received quantity (%) would exceed ordered quantity (%) for PO item %', v_new_qty, v_po_item_row.ordered_qty, v_po_item_row.id;
    END IF;
  END LOOP;

  -- Verify all distinct requested items were found and locked
  IF (
    SELECT count(DISTINCT (item->>'purchase_order_item_id')::UUID)
    FROM jsonb_array_elements(v_items) AS item
  ) != (
    SELECT count(*)
    FROM public.purchase_order_items poi
    WHERE poi.id IN (
      SELECT (item->>'purchase_order_item_id')::UUID
      FROM jsonb_array_elements(v_items) AS item
    )
      AND poi.company_id = v_company_id
      AND poi.purchase_order_id = v_po_id
      AND poi.is_active = TRUE
  ) THEN
    RAISE EXCEPTION 'One or more purchase_order_items not found, inactive, not owned by your company, or do not belong to this PO';
  END IF;

  -- Insert receipt header
  INSERT INTO public.purchase_receipts (
    company_id, branch_id, purchase_order_id, receipt_number,
    receipt_date, status, notes, created_by
  ) VALUES (
    v_company_id, v_branch_id, v_po_id, v_receipt_number,
    v_receipt_date, 'completed', v_notes, auth.uid()
  )
  RETURNING id INTO v_receipt_id;

  -- Process each receipt item
  v_item_count := jsonb_array_length(v_items);
  FOR v_item_idx IN 0..v_item_count - 1 LOOP
    v_item := v_items->v_item_idx;
    v_po_item_id := (v_item->>'purchase_order_item_id')::UUID;
    v_received_qty := (v_item->>'received_qty')::NUMERIC;
    v_lot_code := NULLIF(btrim(v_item->>'lot_code'), '');
    v_expiration_date := (v_item->>'expiration_date')::DATE;

    -- Get PO item data for cost defaults (we already locked it above, but re-read)
    SELECT variant_id, unit_cost, tax_rate INTO v_po_item_row
    FROM public.purchase_order_items
    WHERE id = v_po_item_id AND company_id = v_company_id;

    v_variant_id := v_po_item_row.variant_id;

    -- Use receipt-level unit_cost if provided, else default to PO item unit_cost
    v_unit_cost := COALESCE((v_item->>'unit_cost')::NUMERIC, v_po_item_row.unit_cost);
    v_tax_rate := COALESCE((v_item->>'tax_rate')::NUMERIC, v_po_item_row.tax_rate);

    v_item_subtotal := ROUND(v_received_qty * v_unit_cost, 2);
    v_item_tax_amt := ROUND(v_item_subtotal * v_tax_rate, 2);

    -- Insert receipt item
    INSERT INTO public.purchase_receipt_items (
      company_id, purchase_receipt_id, purchase_order_item_id,
      variant_id, received_qty, unit_cost, tax_rate,
      tax_amount, subtotal, lot_code, expiration_date, created_by
    ) VALUES (
      v_company_id, v_receipt_id, v_po_item_id,
      v_variant_id, v_received_qty, v_unit_cost, v_tax_rate,
      v_item_tax_amt, v_item_subtotal, v_lot_code, v_expiration_date, auth.uid()
    );

    -- Call inventory RPC: receive_purchase_lot
    v_lot_result := public.receive_purchase_lot(
      jsonb_build_object(
        'company_id', v_company_id,
        'branch_id', v_branch_id,
        'variant_id', v_variant_id,
        'qty', v_received_qty,
        'lot_code', v_lot_code,
        'expiration_date', v_expiration_date,
        'cost_per_unit', v_unit_cost,
        'reference_type', 'purchase_receipt',
        'reference_id', v_receipt_id,
        'notes', v_notes
      )::JSONB
    );

    v_lot_results := v_lot_results || v_lot_result;

    -- Update PO item received_qty
    UPDATE public.purchase_order_items
    SET received_qty = received_qty + v_received_qty,
        updated_by = auth.uid()
    WHERE id = v_po_item_id
      AND company_id = v_company_id;

    -- Update product_variants.last_cost atomically
    IF v_unit_cost IS NOT NULL THEN
      UPDATE public.product_variants
      SET last_cost = v_unit_cost,
          updated_at = now()
      WHERE id = v_variant_id
        AND company_id = v_company_id;
    END IF;

    v_items_processed := v_items_processed + 1;
  END LOOP;

  -- Determine PO status transition
  SELECT COUNT(*) = 0 INTO v_all_received
  FROM public.purchase_order_items
  WHERE purchase_order_id = v_po_id
    AND company_id = v_company_id
    AND is_active = TRUE
    AND received_qty < ordered_qty;

  IF v_all_received THEN
    UPDATE public.purchase_orders
    SET status = 'received', updated_by = auth.uid()
    WHERE id = v_po_id AND company_id = v_company_id;
    v_po_status := 'received';
  ELSE
    UPDATE public.purchase_orders
    SET status = 'partial', updated_by = auth.uid()
    WHERE id = v_po_id AND company_id = v_company_id;
    v_po_status := 'partial';
  END IF;

  RETURN jsonb_build_object(
    'receipt_id', v_receipt_id,
    'purchase_order_id', v_po_id,
    'po_status', v_po_status,
    'lot_results', v_lot_results,
    'items_processed', v_items_processed
  );
END;
$$;

COMMENT ON FUNCTION public.receive_purchase_transaction(JSONB) IS 'Master receipt RPC: validates PO, inserts receipt + items, calls receive_purchase_lot per item, updates received_qty, transitions PO status. All in one atomic transaction with batched SELECT FOR UPDATE on PO items. (source: RP4, RP5, RP6, RP7, RP10)';

-- ============================================================
-- I) RPC: cancel_purchase_order(p JSONB)
-- Cancels a PO in draft/sent/partial status. Rejects received
-- and already cancelled POs. Does NOT reverse inventory or receipts.
-- ============================================================
CREATE OR REPLACE FUNCTION public.cancel_purchase_order(p JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_company_id    UUID;
  v_po_id         UUID;
  v_reason        TEXT;
  v_previous_status TEXT;
  v_po_row        RECORD;
BEGIN
  v_company_id := (p->>'company_id')::UUID;
  v_po_id := (p->>'purchase_order_id')::UUID;
  v_reason := NULLIF(btrim(p->>'reason'), '');

  -- Security: verify company and admin
  IF v_company_id IS NULL THEN
    RAISE EXCEPTION 'company_id is required';
  END IF;
  IF v_company_id != public.get_company_id() THEN
    RAISE EXCEPTION 'company_id does not match authenticated user company';
  END IF;
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'Only admins can cancel purchase orders';
  END IF;

  -- Lock and validate PO
  SELECT id, status INTO v_po_row
  FROM public.purchase_orders
  WHERE id = v_po_id
    AND company_id = v_company_id
    AND is_active = TRUE
    AND status IN ('draft', 'sent', 'partial')
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Purchase order cannot be cancelled. It must be in draft, sent, or partial status.';
  END IF;

  v_previous_status := v_po_row.status;

  -- Mark as cancelled
  UPDATE public.purchase_orders
  SET status = 'cancelled',
      updated_by = auth.uid()
  WHERE id = v_po_id
    AND company_id = v_company_id;

  RETURN jsonb_build_object(
    'purchase_order_id', v_po_id,
    'previous_status', v_previous_status,
    'cancelled', TRUE
  );
END;
$$;

COMMENT ON FUNCTION public.cancel_purchase_order(JSONB) IS 'Cancels a purchase order in draft, sent, or partial status. Rejects received and already cancelled POs. Does not reverse receipts or inventory. (source: RP9, RP10)';

-- ============================================================
-- I) RPC: manage_supplier(p JSONB)
-- Unified CRUD for suppliers: create, update, deactivate.
-- Cross-tenant validation on all actions. Logical deletion via
-- deactivate action.
-- ============================================================
CREATE OR REPLACE FUNCTION public.manage_supplier(p JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_action        TEXT;
  v_company_id    UUID;
  v_supplier_id   UUID;
  v_name          TEXT;
  v_slug          TEXT;
  v_tax_id        TEXT;
  v_contact_name  TEXT;
  v_phone         TEXT;
  v_email         TEXT;
  v_address       TEXT;
  v_note          TEXT;
  v_existing      RECORD;
  v_result_id     UUID;
BEGIN
  v_action := btrim(p->>'action');
  v_company_id := (p->>'company_id')::UUID;
  v_supplier_id := (p->>'supplier_id')::UUID;
  v_name := NULLIF(btrim(p->>'name'), '');
  v_slug := NULLIF(btrim(p->>'slug'), '');
  v_tax_id := NULLIF(btrim(p->>'tax_id'), '');
  v_contact_name := NULLIF(btrim(p->>'contact_name'), '');
  v_phone := NULLIF(btrim(p->>'phone'), '');
  v_email := NULLIF(btrim(p->>'email'), '');
  v_address := NULLIF(btrim(p->>'address'), '');
  v_note := NULLIF(btrim(p->>'notes'), '');

  -- Security: verify company and admin
  IF v_company_id IS NULL THEN
    RAISE EXCEPTION 'company_id is required';
  END IF;
  IF v_company_id != public.get_company_id() THEN
    RAISE EXCEPTION 'company_id does not match authenticated user company';
  END IF;
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'Only admins can manage suppliers';
  END IF;

  IF v_action IS NULL OR v_action NOT IN ('create', 'update', 'deactivate') THEN
    RAISE EXCEPTION 'action must be one of: create, update, deactivate';
  END IF;

  IF v_action = 'create' THEN
    -- Validate required fields
    IF v_name IS NULL THEN
      RAISE EXCEPTION 'name is required for create';
    END IF;
    IF v_slug IS NULL THEN
      RAISE EXCEPTION 'slug is required for create';
    END IF;

    -- Check slug uniqueness per company
    IF EXISTS (
      SELECT 1 FROM public.suppliers
      WHERE company_id = v_company_id AND slug = v_slug
    ) THEN
      RAISE EXCEPTION 'A supplier with this slug already exists in your company';
    END IF;

    INSERT INTO public.suppliers (
      company_id, name, slug, tax_id, contact_name,
      phone, email, address, notes, created_by
    ) VALUES (
      v_company_id, v_name, v_slug, v_tax_id, v_contact_name,
      v_phone, v_email, v_address, v_note, auth.uid()
    )
    RETURNING id INTO v_result_id;

    RETURN jsonb_build_object(
      'supplier_id', v_result_id,
      'company_id', v_company_id,
      'action', 'create'
    );

  ELSIF v_action = 'update' THEN
    IF v_supplier_id IS NULL THEN
      RAISE EXCEPTION 'supplier_id is required for update';
    END IF;

    -- Validate supplier exists and belongs to company
    SELECT id, company_id INTO v_existing
    FROM public.suppliers
    WHERE id = v_supplier_id AND company_id = v_company_id;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Supplier not found or not owned by your company';
    END IF;

    -- Update only provided fields
    UPDATE public.suppliers
    SET name = COALESCE(v_name, name),
        slug = COALESCE(v_slug, slug),
        tax_id = COALESCE(v_tax_id, tax_id),
        contact_name = COALESCE(v_contact_name, contact_name),
        phone = COALESCE(v_phone, phone),
        email = COALESCE(v_email, email),
        address = COALESCE(v_address, address),
        notes = COALESCE(v_note, notes),
        updated_by = auth.uid()
    WHERE id = v_supplier_id AND company_id = v_company_id;

    RETURN jsonb_build_object(
      'supplier_id', v_supplier_id,
      'company_id', v_company_id,
      'action', 'update'
    );

  ELSIF v_action = 'deactivate' THEN
    IF v_supplier_id IS NULL THEN
      RAISE EXCEPTION 'supplier_id is required for deactivate';
    END IF;

    -- Validate supplier exists and belongs to company
    SELECT id, company_id, is_active INTO v_existing
    FROM public.suppliers
    WHERE id = v_supplier_id AND company_id = v_company_id;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Supplier not found or not owned by your company';
    END IF;

    IF NOT v_existing.is_active THEN
      RAISE EXCEPTION 'Supplier is already deactivated';
    END IF;

    -- Logical deletion
    UPDATE public.suppliers
    SET is_active = FALSE,
        deleted_at = now(),
        deleted_by = auth.uid()
    WHERE id = v_supplier_id AND company_id = v_company_id;

    RETURN jsonb_build_object(
      'supplier_id', v_supplier_id,
      'company_id', v_company_id,
      'deactivated', TRUE,
      'action', 'deactivate'
    );
  END IF;
END;
$$;

COMMENT ON FUNCTION public.manage_supplier(JSONB) IS 'Unified supplier CRUD: create, update, deactivate (logical deletion). Cross-tenant validation on all actions. (source: RP1, RP10)';

-- ============================================================
-- J) RPC EXECUTE HARDENING
-- SECURITY DEFINER functions run with definer privileges.
-- EXECUTE must be restricted explicitly.
-- ============================================================
REVOKE ALL ON FUNCTION public.create_purchase_order(JSONB) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.receive_purchase_transaction(JSONB) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.cancel_purchase_order(JSONB) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.manage_supplier(JSONB) FROM PUBLIC;

REVOKE ALL ON FUNCTION public.create_purchase_order(JSONB) FROM anon;
REVOKE ALL ON FUNCTION public.receive_purchase_transaction(JSONB) FROM anon;
REVOKE ALL ON FUNCTION public.cancel_purchase_order(JSONB) FROM anon;
REVOKE ALL ON FUNCTION public.manage_supplier(JSONB) FROM anon;

GRANT EXECUTE ON FUNCTION public.create_purchase_order(JSONB) TO authenticated;
GRANT EXECUTE ON FUNCTION public.receive_purchase_transaction(JSONB) TO authenticated;
GRANT EXECUTE ON FUNCTION public.cancel_purchase_order(JSONB) TO authenticated;
GRANT EXECUTE ON FUNCTION public.manage_supplier(JSONB) TO authenticated;
