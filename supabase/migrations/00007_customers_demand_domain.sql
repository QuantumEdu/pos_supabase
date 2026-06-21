-- Migration: 00007_customers_demand_domain
-- Source: customers-demand-domain spec (RCD1–RCD17), design (D1–D5)
-- Requirements: R3 (RLS-first multi-tenant), R5 (traceability + logical deletion),
--               SDK + RLS only for V1 (no RPCs, no Edge Functions)

-- ============================================================
-- CUSTOMERS
-- Company-scoped customer master. Logical deletion only.
-- (source: RCD1, RCD2)
-- ============================================================
CREATE TABLE IF NOT EXISTS public.customers (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id  UUID NOT NULL REFERENCES public.companies(id),
  name        TEXT NOT NULL,
  slug        TEXT NOT NULL,
  tax_id      TEXT,
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

COMMENT ON TABLE public.customers IS 'Company-scoped customer master. Logical deletion via is_active/deleted_at. (source: RCD1, RCD2)';
COMMENT ON COLUMN public.customers.slug IS 'URL-safe identifier, unique per company.';
COMMENT ON COLUMN public.customers.tax_id IS 'Optional tax identifier (RFC, NIT, etc.).';
COMMENT ON COLUMN public.customers.is_active IS 'Logical deletion flag. Physical DELETE prohibited.';

CREATE INDEX idx_customers_company_id ON public.customers(company_id);

-- ============================================================
-- CUSTOMER_REQUESTS
-- Demand signals: customer asks for product (may be uncatalogued).
-- variant_id is nullable for uncatalogued product requests.
-- (source: RCD3, RCD4)
-- ============================================================
CREATE TABLE IF NOT EXISTS public.customer_requests (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id    UUID NOT NULL REFERENCES public.companies(id),
  customer_id   UUID NOT NULL,
  variant_id    UUID,
  requested_qty NUMERIC(14,3) NOT NULL CHECK (requested_qty > 0),
  status        TEXT NOT NULL DEFAULT 'pending'
                  CHECK (status IN ('pending', 'resolved', 'cancelled')),
  notes         TEXT,
  is_active     BOOLEAN NOT NULL DEFAULT TRUE,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  deleted_at    TIMESTAMPTZ,
  created_by    UUID,
  updated_by    UUID,
  deleted_by    UUID
);

COMMENT ON TABLE public.customer_requests IS 'Customer demand signals. variant_id is nullable for uncatalogued product requests. (source: RCD3, RCD4)';
COMMENT ON COLUMN public.customer_requests.variant_id IS 'NULL means product not yet catalogued. Non-NULL references product_variants via composite FK.';
COMMENT ON COLUMN public.customer_requests.status IS 'pending | resolved | cancelled. V1 enforcement is CHECK constraint only; no state machine.';

CREATE INDEX idx_customer_requests_company_id ON public.customer_requests(company_id);
CREATE INDEX idx_customer_requests_customer_id ON public.customer_requests(customer_id);
CREATE INDEX idx_customer_requests_variant_id ON public.customer_requests(variant_id) WHERE variant_id IS NOT NULL;
CREATE INDEX idx_customer_requests_status ON public.customer_requests(status);

-- ============================================================
-- PREORDERS
-- Customer intent-to-buy at a specific branch. No stock commitment
-- in V1. Status lifecycle: draft → confirmed → fulfilled | cancelled.
-- (source: RCD5, RCD12)
-- ============================================================
CREATE TABLE IF NOT EXISTS public.preorders (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id      UUID NOT NULL REFERENCES public.companies(id),
  branch_id       UUID NOT NULL,
  customer_id     UUID NOT NULL,
  preorder_number TEXT NOT NULL,
  status          TEXT NOT NULL DEFAULT 'draft'
                    CHECK (status IN ('draft', 'confirmed', 'fulfilled', 'cancelled')),
  notes           TEXT,
  is_active       BOOLEAN NOT NULL DEFAULT TRUE,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  deleted_at      TIMESTAMPTZ,
  created_by      UUID,
  updated_by      UUID,
  deleted_by      UUID,

  UNIQUE(company_id, preorder_number)
);

COMMENT ON TABLE public.preorders IS 'Preorder headers. Demand signals only in V1 — no stock commitment. (source: RCD5)';
COMMENT ON COLUMN public.preorders.preorder_number IS 'Human-readable identifier, unique per company. Client-supplied in V1.';
COMMENT ON COLUMN public.preorders.status IS 'draft | confirmed | fulfilled | cancelled. V1 enforcement is CHECK constraint only.';

CREATE INDEX idx_preorders_company_id ON public.preorders(company_id);
CREATE INDEX idx_preorders_branch_id ON public.preorders(branch_id);
CREATE INDEX idx_preorders_customer_id ON public.preorders(customer_id);
CREATE INDEX idx_preorders_status ON public.preorders(status);

-- ============================================================
-- PREORDER_ITEMS
-- Line items on preorders. variant_id is NOT NULL unlike
-- customer_requests — every preorder item must reference a catalog
-- variant. unit_price is nullable: price may be unknown at preorder
-- time. Follows purchase_order_items pattern with independent
-- logical deletion columns.
-- (source: RCD6, D3)
-- ============================================================
CREATE TABLE IF NOT EXISTS public.preorder_items (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id    UUID NOT NULL REFERENCES public.companies(id),
  preorder_id   UUID NOT NULL,
  variant_id    UUID NOT NULL,
  qty           NUMERIC(14,3) NOT NULL CHECK (qty > 0),
  unit_price    NUMERIC(12,2),
  is_active     BOOLEAN NOT NULL DEFAULT TRUE,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  deleted_at    TIMESTAMPTZ,
  created_by    UUID,
  updated_by    UUID,
  deleted_by    UUID
);

COMMENT ON TABLE public.preorder_items IS 'Line items on preorders. unit_price is nullable (price may be unknown at preorder time). (source: RCD6)';
COMMENT ON COLUMN public.preorder_items.unit_price IS 'Nullable — price may be deferred to sale time (pos-sales-domain).';
COMMENT ON COLUMN public.preorder_items.variant_id IS 'NOT NULL — every preorder item must reference a catalog variant.';

CREATE INDEX idx_preorder_items_company_id ON public.preorder_items(company_id);
CREATE INDEX idx_preorder_items_preorder_id ON public.preorder_items(preorder_id);
CREATE INDEX idx_preorder_items_variant_id ON public.preorder_items(variant_id);

-- ============================================================
-- COMPOSITE UNIQUE INDEXES (company_id, id)
-- Enablers for composite FK constraints. These ensure that
-- (company_id, id) is unique on each table, allowing composite
-- FKs to enforce same-company references at the DDL level.
-- (source: RCD7)
-- ============================================================
CREATE UNIQUE INDEX IF NOT EXISTS idx_customers_company_id_id ON public.customers(company_id, id);
CREATE UNIQUE INDEX IF NOT EXISTS idx_customer_requests_company_id_id ON public.customer_requests(company_id, id);
CREATE UNIQUE INDEX IF NOT EXISTS idx_preorders_company_id_id ON public.preorders(company_id, id);
CREATE UNIQUE INDEX IF NOT EXISTS idx_preorder_items_company_id_id ON public.preorder_items(company_id, id);

-- ============================================================
-- COMPOSITE FOREIGN KEY CONSTRAINTS
-- Enforce same-company reference integrity across all 6 FK paths.
-- Each composite FK uses (company_id, target_id) matching the
-- prerequisite unique indexes above.
-- (source: RCD7, D2)
-- ============================================================

-- customer_requests → customers
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'fk_customer_requests_customer_same_company'
  ) THEN
    ALTER TABLE public.customer_requests
      ADD CONSTRAINT fk_customer_requests_customer_same_company
      FOREIGN KEY (company_id, customer_id) REFERENCES public.customers(company_id, id);
  END IF;
END;
$$;

-- customer_requests → product_variants (nullable)
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'fk_customer_requests_variant_same_company'
  ) THEN
    ALTER TABLE public.customer_requests
      ADD CONSTRAINT fk_customer_requests_variant_same_company
      FOREIGN KEY (company_id, variant_id) REFERENCES public.product_variants(company_id, id);
  END IF;
END;
$$;

-- preorders → branches
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'fk_preorders_branch_same_company'
  ) THEN
    ALTER TABLE public.preorders
      ADD CONSTRAINT fk_preorders_branch_same_company
      FOREIGN KEY (company_id, branch_id) REFERENCES public.branches(company_id, id);
  END IF;
END;
$$;

-- preorders → customers
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'fk_preorders_customer_same_company'
  ) THEN
    ALTER TABLE public.preorders
      ADD CONSTRAINT fk_preorders_customer_same_company
      FOREIGN KEY (company_id, customer_id) REFERENCES public.customers(company_id, id);
  END IF;
END;
$$;

-- preorder_items → preorders
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'fk_preorder_items_preorder_same_company'
  ) THEN
    ALTER TABLE public.preorder_items
      ADD CONSTRAINT fk_preorder_items_preorder_same_company
      FOREIGN KEY (company_id, preorder_id) REFERENCES public.preorders(company_id, id);
  END IF;
END;
$$;

-- preorder_items → product_variants (NOT NULL)
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'fk_preorder_items_variant_same_company'
  ) THEN
    ALTER TABLE public.preorder_items
      ADD CONSTRAINT fk_preorder_items_variant_same_company
      FOREIGN KEY (company_id, variant_id) REFERENCES public.product_variants(company_id, id);
  END IF;
END;
$$;

-- ============================================================
-- set_updated_at TRIGGERS on all 4 tables
-- Reuses the existing set_updated_at() function from migration 00001.
-- (source: RCD14)
-- ============================================================
DO $$
DECLARE
  t TEXT;
BEGIN
  FOREACH t IN ARRAY ARRAY['customers', 'customer_requests', 'preorders', 'preorder_items']
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
-- RLS: Enable and define policies for all 4 tables
-- Pattern: SELECT own company (preorders branch-scoped for cashier),
--          INSERT/UPDATE admin own company, service_role full bypass.
--          No DELETE policies — logical deletion only.
-- (source: RCD8, RCD9, RCD10)
-- ============================================================

-- Customers RLS
ALTER TABLE public.customers ENABLE ROW LEVEL SECURITY;

CREATE POLICY "customers_select_own"
  ON public.customers FOR SELECT
  TO authenticated
  USING (company_id = public.get_company_id());

CREATE POLICY "customers_insert_admin"
  ON public.customers FOR INSERT
  TO authenticated
  WITH CHECK (company_id = public.get_company_id() AND public.is_admin());

CREATE POLICY "customers_update_admin"
  ON public.customers FOR UPDATE
  TO authenticated
  USING (company_id = public.get_company_id() AND public.is_admin());

CREATE POLICY "customers_service_all"
  ON public.customers FOR ALL
  TO service_role
  USING (TRUE) WITH CHECK (TRUE);

-- Customer Requests RLS
ALTER TABLE public.customer_requests ENABLE ROW LEVEL SECURITY;

CREATE POLICY "customer_requests_select_own"
  ON public.customer_requests FOR SELECT
  TO authenticated
  USING (company_id = public.get_company_id());

CREATE POLICY "customer_requests_insert_admin"
  ON public.customer_requests FOR INSERT
  TO authenticated
  WITH CHECK (company_id = public.get_company_id() AND public.is_admin());

CREATE POLICY "customer_requests_update_admin"
  ON public.customer_requests FOR UPDATE
  TO authenticated
  USING (company_id = public.get_company_id() AND public.is_admin());

CREATE POLICY "customer_requests_service_all"
  ON public.customer_requests FOR ALL
  TO service_role
  USING (TRUE) WITH CHECK (TRUE);

-- Preorders RLS (cashier branch-scoped SELECT via branch_users join)
ALTER TABLE public.preorders ENABLE ROW LEVEL SECURITY;

CREATE POLICY "preorders_select_own"
  ON public.preorders FOR SELECT
  TO authenticated
  USING (
    company_id = public.get_company_id()
    AND (
      public.is_admin()
      OR branch_id = public.get_user_branch_id()
      OR EXISTS (
        SELECT 1 FROM public.branch_users bu
        WHERE bu.user_id = auth.uid()
          AND bu.branch_id = preorders.branch_id
          AND bu.company_id = public.get_company_id()
          AND bu.is_active = TRUE
      )
    )
  );

CREATE POLICY "preorders_insert_admin"
  ON public.preorders FOR INSERT
  TO authenticated
  WITH CHECK (company_id = public.get_company_id() AND public.is_admin());

CREATE POLICY "preorders_update_admin"
  ON public.preorders FOR UPDATE
  TO authenticated
  USING (company_id = public.get_company_id() AND public.is_admin());

CREATE POLICY "preorders_service_all"
  ON public.preorders FOR ALL
  TO service_role
  USING (TRUE) WITH CHECK (TRUE);

-- Preorder Items RLS
ALTER TABLE public.preorder_items ENABLE ROW LEVEL SECURITY;

CREATE POLICY "preorder_items_select_own"
  ON public.preorder_items FOR SELECT
  TO authenticated
  USING (
    company_id = public.get_company_id()
    AND (
      public.is_admin()
      OR EXISTS (
        SELECT 1 FROM public.preorders po
        WHERE po.id = preorder_items.preorder_id
          AND po.company_id = public.get_company_id()
          AND (
            po.branch_id = public.get_user_branch_id()
            OR EXISTS (
              SELECT 1 FROM public.branch_users bu
              WHERE bu.user_id = auth.uid()
                AND bu.branch_id = po.branch_id
                AND bu.company_id = public.get_company_id()
                AND bu.is_active = TRUE
            )
          )
      )
    )
  );

CREATE POLICY "preorder_items_insert_admin"
  ON public.preorder_items FOR INSERT
  TO authenticated
  WITH CHECK (company_id = public.get_company_id() AND public.is_admin());

CREATE POLICY "preorder_items_update_admin"
  ON public.preorder_items FOR UPDATE
  TO authenticated
  USING (company_id = public.get_company_id() AND public.is_admin());

CREATE POLICY "preorder_items_service_all"
  ON public.preorder_items FOR ALL
  TO service_role
  USING (TRUE) WITH CHECK (TRUE);

-- ============================================================
-- GRANTS
-- authenticated: SELECT + INSERT + UPDATE (mutations via SDK + RLS).
-- anon: SELECT only (read-only browsing).
-- service_role: SELECT only (no RPCs in V1 need INSERT/UPDATE).
-- No DELETE grants — logical deletion only.
-- (source: RCD8, RCD10, D1)
-- ============================================================
GRANT SELECT, INSERT, UPDATE ON public.customers TO authenticated;
GRANT SELECT ON public.customers TO anon;
GRANT SELECT ON public.customers TO service_role;

GRANT SELECT, INSERT, UPDATE ON public.customer_requests TO authenticated;
GRANT SELECT ON public.customer_requests TO anon;
GRANT SELECT ON public.customer_requests TO service_role;

GRANT SELECT, INSERT, UPDATE ON public.preorders TO authenticated;
GRANT SELECT ON public.preorders TO anon;
GRANT SELECT ON public.preorders TO service_role;

GRANT SELECT, INSERT, UPDATE ON public.preorder_items TO authenticated;
GRANT SELECT ON public.preorder_items TO anon;
GRANT SELECT ON public.preorder_items TO service_role;
