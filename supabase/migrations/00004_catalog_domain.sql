-- Migration: 00004_catalog_domain
-- Source: catalog-domain spec (RC1–RC7), design (D10–D13)
-- Requirements: R3 (RLS-first multi-tenant), R5 (traceability + logical deletion),
--               R6 (transactional consistency), SKU case-insensitive unique,
--               barcode nullable partial unique, category depth ≤ 5, temporal prices,
--               variant name NOT NULL, default currency MXN

-- ============================================================
-- BRANDS
-- Company-scoped brand master. Each company manages its own brands.
-- (source: RC1, D10)
-- ============================================================
CREATE TABLE public.brands (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id  UUID NOT NULL REFERENCES public.companies(id),
  name        TEXT NOT NULL,
  slug        TEXT NOT NULL,
  is_active   BOOLEAN NOT NULL DEFAULT TRUE,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_by  UUID,
  updated_by  UUID,
  deleted_at  TIMESTAMPTZ,
  deleted_by  UUID,

  UNIQUE(company_id, slug)
);

COMMENT ON TABLE public.brands IS 'Company-scoped brand master. Logical deletion via is_active/deleted_at. (source: RC1)';
COMMENT ON COLUMN public.brands.company_id IS 'Enforces multi-tenant isolation. (source: R3)';
COMMENT ON COLUMN public.brands.slug IS 'URL-safe identifier, unique per company. (source: RC1)';

CREATE INDEX idx_brands_company_id ON public.brands(company_id);

-- ============================================================
-- CATEGORIES
-- Hierarchical categories with max depth 5. Cycle prevention trigger
-- applied below. (source: RC2, D10)
-- ============================================================
CREATE TABLE public.categories (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id  UUID NOT NULL REFERENCES public.companies(id),
  name        TEXT NOT NULL,
  slug        TEXT NOT NULL,
  parent_id   UUID,
  -- Cross-tenant reference integrity enforced by composite FK fk_categories_parent_same_company below
  is_active   BOOLEAN NOT NULL DEFAULT TRUE,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_by  UUID,
  updated_by  UUID,
  deleted_at  TIMESTAMPTZ,
  deleted_by  UUID,

  UNIQUE(company_id, slug)
);

COMMENT ON TABLE public.categories IS 'Hierarchical categories with max depth 5. Cycle prevention enforced via trigger. (source: RC2)';
COMMENT ON COLUMN public.categories.parent_id IS 'Self-referencing FK for nesting. NULL = root category (depth 1). (source: RC2)';

CREATE INDEX idx_categories_company_id ON public.categories(company_id);
CREATE INDEX idx_categories_parent_id ON public.categories(parent_id);

-- ============================================================
-- UNITS
-- Measurement units. 8 global base units are seeded as read-only templates
-- owned by the global company (00000000-...). Tenants can view them but cannot
-- update or delete them directly. Tenants must copy a global template into their
-- own tenant-owned units row before using it as product_variants.unit_id.
-- The composite FK fk_product_variants_unit_same_company enforces that only
-- tenant-owned unit rows can be referenced by variants.
-- (source: RC3, D10)
-- ============================================================
CREATE TABLE public.units (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id    UUID NOT NULL REFERENCES public.companies(id),
  name          TEXT NOT NULL,
  abbreviation  TEXT,
  is_active     BOOLEAN NOT NULL DEFAULT TRUE,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_by    UUID,
  updated_by    UUID,
  deleted_at    TIMESTAMPTZ,
  deleted_by    UUID,

  UNIQUE(company_id, name)
);

COMMENT ON TABLE public.units IS 'Measurement units. Global base units are read-only templates visible to all authenticated tenants. Tenants must copy them into tenant-owned rows before use in product_variants.unit_id. (source: RC3)';
COMMENT ON COLUMN public.units.abbreviation IS 'Short form (e.g. "kg", "ml"). (source: RC3)';

CREATE INDEX idx_units_company_id ON public.units(company_id);

-- ============================================================
-- PRODUCTS
-- Product master. Belongs to a company, optionally linked to a brand
-- and/or category. (source: RC4, D10)
-- ============================================================
CREATE TABLE public.products (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id   UUID NOT NULL REFERENCES public.companies(id),
  name         TEXT NOT NULL,
  slug         TEXT NOT NULL,
  brand_id     UUID,  -- Cross-tenant FK enforced below
  category_id  UUID,  -- Cross-tenant FK enforced below
  description  TEXT,
  is_active    BOOLEAN NOT NULL DEFAULT TRUE,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_by   UUID,
  updated_by   UUID,
  deleted_at   TIMESTAMPTZ,
  deleted_by   UUID,

  UNIQUE(company_id, slug)
);

COMMENT ON TABLE public.products IS 'Product master. Variants and prices live in child tables. (source: RC4)';
COMMENT ON COLUMN public.products.brand_id IS 'Optional brand link. (source: RC4)';
COMMENT ON COLUMN public.products.category_id IS 'Optional category link. (source: RC4)';

CREATE INDEX idx_products_company_id ON public.products(company_id);
CREATE INDEX idx_products_brand_id ON public.products(brand_id);
CREATE INDEX idx_products_category_id ON public.products(category_id);

-- ============================================================
-- PRODUCT_VARIANTS
-- Variants under a product. SKU is case-insensitive unique per company.
-- Barcode is optional with partial unique index (NULLs do not conflict).
-- (source: RC4, D10, D11)
-- ============================================================
CREATE TABLE public.product_variants (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id   UUID NOT NULL REFERENCES public.companies(id),
  product_id   UUID NOT NULL,  -- Cross-tenant FK enforced below
  sku          TEXT,
  barcode      TEXT,
  name         TEXT NOT NULL,
  unit_id      UUID,  -- Cross-tenant FK enforced below
  is_active    BOOLEAN NOT NULL DEFAULT TRUE,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_by   UUID,
  updated_by   UUID,
  deleted_at   TIMESTAMPTZ,
  deleted_by   UUID
);

COMMENT ON TABLE public.product_variants IS 'Product variants. SKU is case-insensitive unique; barcode is optional. (source: RC4)';
COMMENT ON COLUMN public.product_variants.sku IS 'Case-insensitive unique identifier per company. Auto-generated if null (RPC phase). (source: RC4, D11)';
COMMENT ON COLUMN public.product_variants.barcode IS 'Optional barcode. NULLs do not conflict in uniqueness check. (source: RC4)';
COMMENT ON COLUMN public.product_variants.name IS 'Human-readable label (e.g. "Chocolate 2kg"). NOT NULL. (source: RC4)';

-- SKU: case-insensitive unique per company, NULLs excluded
CREATE UNIQUE INDEX idx_product_variants_company_sku
  ON public.product_variants(company_id, LOWER(sku))
  WHERE sku IS NOT NULL;

-- Barcode: unique per company, NULLs excluded
CREATE UNIQUE INDEX idx_product_variants_company_barcode
  ON public.product_variants(company_id, barcode)
  WHERE barcode IS NOT NULL;

CREATE INDEX idx_product_variants_company_id ON public.product_variants(company_id);
CREATE INDEX idx_product_variants_product_id ON public.product_variants(product_id);

-- ============================================================
-- PRODUCT_PRICES
-- Temporal prices: effective_from → effective_until (nullable end).
-- Only one active price per variant at a time (unique where effective_until IS NULL).
-- New price closes previous at new.effective_from (RPC phase).
-- (source: RC5, D10, D12)
-- ============================================================
CREATE TABLE public.product_prices (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id      UUID NOT NULL REFERENCES public.companies(id),
  variant_id      UUID NOT NULL,  -- Cross-tenant FK enforced below
  price           NUMERIC(12, 2) NOT NULL,
  currency        TEXT NOT NULL DEFAULT 'MXN',
  effective_from  TIMESTAMPTZ NOT NULL DEFAULT now(),
  effective_until TIMESTAMPTZ,
  is_active       BOOLEAN NOT NULL DEFAULT TRUE,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_by      UUID,
  updated_by      UUID,
  deleted_at      TIMESTAMPTZ,
  deleted_by      UUID
);

COMMENT ON TABLE public.product_prices IS 'Temporal prices. Only one active price (effective_until IS NULL) per variant. (source: RC5)';
COMMENT ON COLUMN public.product_prices.price IS 'Unit price with 2 decimal places. (source: RC5)';
COMMENT ON COLUMN public.product_prices.currency IS 'ISO 4217 currency code. Defaults to MXN. (source: RC5)';
COMMENT ON COLUMN public.product_prices.effective_from IS 'Start of validity period. Defaults to now(). (source: RC5)';
COMMENT ON COLUMN public.product_prices.effective_until IS 'End of validity period. NULL means currently active. (source: RC5)';

-- Only one active price per variant at a time
CREATE UNIQUE INDEX idx_product_prices_active
  ON public.product_prices(variant_id)
  WHERE effective_until IS NULL;

CREATE INDEX idx_product_prices_company_id ON public.product_prices(company_id);
CREATE INDEX idx_product_prices_variant_id ON public.product_prices(variant_id);
CREATE INDEX idx_product_prices_effective_from ON public.product_prices(effective_from);

-- ============================================================
-- TRIGGER: prevent_category_cycle()
-- BEFORE INSERT/UPDATE on categories:
-- Walk parent chain; reject if a cycle is detected or depth > 5.
-- (source: RC2, D10)
-- ============================================================
CREATE OR REPLACE FUNCTION public.prevent_category_cycle()
RETURNS TRIGGER AS $$
DECLARE
  current_id UUID;
  depth      INTEGER := 1;
BEGIN
  -- If no parent, depth is 1 (root)
  IF NEW.parent_id IS NULL THEN
    RETURN NEW;
  END IF;

  -- Self-reference check (direct cycle)
  IF NEW.parent_id = NEW.id THEN
    RAISE EXCEPTION 'Category cycle detected: category cannot reference itself';
  END IF;

  -- Walk parent chain to detect cycles and enforce max depth
  current_id := NEW.parent_id;
  WHILE current_id IS NOT NULL LOOP
    depth := depth + 1;

    -- Depth limit check
    IF depth > 5 THEN
      RAISE EXCEPTION 'Category depth exceeds maximum of 5';
    END IF;

    -- Cycle detection: if we reach the row being inserted/updated
    SELECT parent_id INTO current_id
    FROM public.categories
    WHERE id = current_id;

    -- Check for cycle (parent chain loops back to NEW.id)
    IF current_id = NEW.id THEN
      RAISE EXCEPTION 'Category cycle detected: circular parent reference';
    END IF;
  END LOOP;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION public.prevent_category_cycle() IS 'Trigger function: rejects category cycles and depth > 5. (source: RC2)';

CREATE TRIGGER trg_prevent_category_cycle
  BEFORE INSERT OR UPDATE ON public.categories
  FOR EACH ROW EXECUTE FUNCTION public.prevent_category_cycle();

-- ============================================================
-- TRIGGER: set_updated_at on all 6 catalog tables
-- Reuses the existing set_updated_at() function from 00001.
-- (source: R5, D10)
-- ============================================================
DO $$
DECLARE
  t TEXT;
BEGIN
  FOREACH t IN ARRAY ARRAY['brands', 'categories', 'units', 'products', 'product_variants', 'product_prices']
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
-- CROSS-TENANT REFERENCE INTEGRITY: Unique indexes for composite FKs
-- These enable composite foreign keys that enforce same-company references
-- across all catalog relationships. RLS hides rows from other tenants,
-- but does not protect referential integrity — a Company A row could
-- reference a Company B row if the UUID is known. Composite FKs close
-- this gap by requiring (company_id, referenced_id) to match.
-- (source: RC7 cross-tenant integrity remediation)
-- ============================================================
CREATE UNIQUE INDEX idx_brands_company_id_id ON public.brands(company_id, id);
CREATE UNIQUE INDEX idx_categories_company_id_id ON public.categories(company_id, id);
CREATE UNIQUE INDEX idx_units_company_id_id ON public.units(company_id, id);
CREATE UNIQUE INDEX idx_products_company_id_id ON public.products(company_id, id);
CREATE UNIQUE INDEX idx_product_variants_company_id_id ON public.product_variants(company_id, id);

-- ============================================================
-- CROSS-TENANT REFERENCE INTEGRITY: Composite FK constraints
-- Each composite FK enforces that a reference cannot point to a row
-- in a different company. NULLable references (brand_id, category_id,
-- unit_id, parent_id) are handled naturally: PostgreSQL skips FK
-- validation when any referencing column is NULL.
-- (source: RC7 security remediation)
-- ============================================================
ALTER TABLE public.categories
  ADD CONSTRAINT fk_categories_parent_same_company
  FOREIGN KEY (company_id, parent_id) REFERENCES public.categories(company_id, id);

ALTER TABLE public.products
  ADD CONSTRAINT fk_products_brand_same_company
  FOREIGN KEY (company_id, brand_id) REFERENCES public.brands(company_id, id);

ALTER TABLE public.products
  ADD CONSTRAINT fk_products_category_same_company
  FOREIGN KEY (company_id, category_id) REFERENCES public.categories(company_id, id);

ALTER TABLE public.product_variants
  ADD CONSTRAINT fk_product_variants_product_same_company
  FOREIGN KEY (company_id, product_id) REFERENCES public.products(company_id, id);

ALTER TABLE public.product_variants
  ADD CONSTRAINT fk_product_variants_unit_same_company
  FOREIGN KEY (company_id, unit_id) REFERENCES public.units(company_id, id);

ALTER TABLE public.product_prices
  ADD CONSTRAINT fk_product_prices_variant_same_company
  FOREIGN KEY (company_id, variant_id) REFERENCES public.product_variants(company_id, id);

-- ============================================================
-- TRIGGER: prevent_global_unit_deletion()
-- Prevents physical deletion of seed base units owned by the global
-- company (00000000-...). These are templates that must never be
-- removed by any role including service_role. Logical deletion
-- (is_active=false) via a future RPC is acceptable.
-- (source: RC3 base unit protection)
-- ============================================================
CREATE OR REPLACE FUNCTION public.prevent_global_unit_deletion()
RETURNS TRIGGER AS $$
BEGIN
  IF OLD.company_id = '00000000-0000-0000-0000-000000000000' THEN
    RAISE EXCEPTION 'Cannot physically delete global base unit templates';
  END IF;
  RETURN OLD;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION public.prevent_global_unit_deletion() IS 'Trigger function: prevents physical deletion of global base units. Logical deletion via is_active is acceptable. (source: RC3)';

CREATE TRIGGER trg_prevent_global_unit_deletion
  BEFORE DELETE ON public.units
  FOR EACH ROW EXECUTE FUNCTION public.prevent_global_unit_deletion();

-- ============================================================
-- SEED DATA: Global base company + 8 base units
-- Global base units are read-only templates owned by the global company.
-- Tenants can view them but cannot update or delete them directly.
-- Tenants must copy a global template into their own tenant-owned units row
-- before referencing it in product_variants.unit_id.
-- (source: RC3, D10)
-- ============================================================
INSERT INTO public.companies (id, name, slug)
VALUES ('00000000-0000-0000-0000-000000000000', 'Global Base Units', 'global-base-units')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.units (company_id, name, abbreviation) VALUES
  ('00000000-0000-0000-0000-000000000000', 'Unidad',      'Ud'),
  ('00000000-0000-0000-0000-000000000000', 'Cápsulas',    'Cáp'),
  ('00000000-0000-0000-0000-000000000000', 'Tabletas',    'Tab'),
  ('00000000-0000-0000-0000-000000000000', 'Mililitros',  'ml'),
  ('00000000-0000-0000-0000-000000000000', 'Gramos',      'g'),
  ('00000000-0000-0000-0000-000000000000', 'Kilogramos',  'kg'),
  ('00000000-0000-0000-0000-000000000000', 'Litros',      'L'),
  ('00000000-0000-0000-0000-000000000000', 'Miligramos',  'mg');

-- ============================================================
-- RLS: Enable and define policies for all 6 catalog tables
-- Pattern: SELECT own company, INSERT/UPDATE admin own company,
--          service_role full bypass. No DELETE policies.
-- (source: R3, D5, D10)
-- ============================================================

-- Brands RLS
ALTER TABLE public.brands ENABLE ROW LEVEL SECURITY;

CREATE POLICY "brands_select_own"
  ON public.brands FOR SELECT
  TO authenticated
  USING (company_id = public.get_company_id());

CREATE POLICY "brands_insert_admin"
  ON public.brands FOR INSERT
  TO authenticated
  WITH CHECK (company_id = public.get_company_id() AND public.is_admin());

CREATE POLICY "brands_update_admin"
  ON public.brands FOR UPDATE
  TO authenticated
  USING (company_id = public.get_company_id() AND public.is_admin());

CREATE POLICY "brands_service_all"
  ON public.brands FOR ALL
  TO service_role
  USING (TRUE) WITH CHECK (TRUE);

-- Categories RLS
ALTER TABLE public.categories ENABLE ROW LEVEL SECURITY;

CREATE POLICY "categories_select_own"
  ON public.categories FOR SELECT
  TO authenticated
  USING (company_id = public.get_company_id());

CREATE POLICY "categories_insert_admin"
  ON public.categories FOR INSERT
  TO authenticated
  WITH CHECK (company_id = public.get_company_id() AND public.is_admin());

CREATE POLICY "categories_update_admin"
  ON public.categories FOR UPDATE
  TO authenticated
  USING (company_id = public.get_company_id() AND public.is_admin());

CREATE POLICY "categories_service_all"
  ON public.categories FOR ALL
  TO service_role
  USING (TRUE) WITH CHECK (TRUE);

-- Units RLS
ALTER TABLE public.units ENABLE ROW LEVEL SECURITY;

CREATE POLICY "units_select_own"
  ON public.units FOR SELECT
  TO authenticated
  USING (company_id = public.get_company_id());

CREATE POLICY "units_insert_admin"
  ON public.units FOR INSERT
  TO authenticated
  WITH CHECK (company_id = public.get_company_id() AND public.is_admin());

CREATE POLICY "units_update_admin"
  ON public.units FOR UPDATE
  TO authenticated
  USING (company_id = public.get_company_id() AND public.is_admin());

CREATE POLICY "units_service_all"
  ON public.units FOR ALL
  TO service_role
  USING (TRUE) WITH CHECK (TRUE);

-- Global base units: readable by all authenticated users as templates.
-- They MUST NOT be used as product_variants.unit_id by tenants (enforced by
-- composite FK fk_product_variants_unit_same_company) and MUST NOT be
-- directly updated or deleted by tenants (enforced by RLS + trigger).
-- Tenants copy these templates into their own unit rows for use in variants.
CREATE POLICY "units_select_global_templates"
  ON public.units FOR SELECT
  TO authenticated
  USING (company_id = '00000000-0000-0000-0000-000000000000');

-- Products RLS
ALTER TABLE public.products ENABLE ROW LEVEL SECURITY;

CREATE POLICY "products_select_own"
  ON public.products FOR SELECT
  TO authenticated
  USING (company_id = public.get_company_id());

CREATE POLICY "products_insert_admin"
  ON public.products FOR INSERT
  TO authenticated
  WITH CHECK (company_id = public.get_company_id() AND public.is_admin());

CREATE POLICY "products_update_admin"
  ON public.products FOR UPDATE
  TO authenticated
  USING (company_id = public.get_company_id() AND public.is_admin());

CREATE POLICY "products_service_all"
  ON public.products FOR ALL
  TO service_role
  USING (TRUE) WITH CHECK (TRUE);

-- Product Variants RLS
ALTER TABLE public.product_variants ENABLE ROW LEVEL SECURITY;

CREATE POLICY "product_variants_select_own"
  ON public.product_variants FOR SELECT
  TO authenticated
  USING (company_id = public.get_company_id());

CREATE POLICY "product_variants_insert_admin"
  ON public.product_variants FOR INSERT
  TO authenticated
  WITH CHECK (company_id = public.get_company_id() AND public.is_admin());

CREATE POLICY "product_variants_update_admin"
  ON public.product_variants FOR UPDATE
  TO authenticated
  USING (company_id = public.get_company_id() AND public.is_admin());

CREATE POLICY "product_variants_service_all"
  ON public.product_variants FOR ALL
  TO service_role
  USING (TRUE) WITH CHECK (TRUE);

-- Product Prices RLS
ALTER TABLE public.product_prices ENABLE ROW LEVEL SECURITY;

CREATE POLICY "product_prices_select_own"
  ON public.product_prices FOR SELECT
  TO authenticated
  USING (company_id = public.get_company_id());

CREATE POLICY "product_prices_insert_admin"
  ON public.product_prices FOR INSERT
  TO authenticated
  WITH CHECK (company_id = public.get_company_id() AND public.is_admin());

CREATE POLICY "product_prices_update_admin"
  ON public.product_prices FOR UPDATE
  TO authenticated
  USING (company_id = public.get_company_id() AND public.is_admin());

CREATE POLICY "product_prices_service_all"
  ON public.product_prices FOR ALL
  TO service_role
  USING (TRUE) WITH CHECK (TRUE);

-- ============================================================
-- GRANTs: Allow authenticated role to access catalog tables
-- RLS policies enforce tenant isolation; these GRANTs enable the
-- role-based access that RLS evaluates.
-- anon gets SELECT only (read-only catalog browsing) on non-mutation
-- tables; mutation tables (no table-level DELETE grant) are restricted.
-- Mutation RPCs are the only write path for catalog data.
-- (source: Supabase convention, required for pgTAP RLS testing, RC7 hardening)
-- ============================================================
GRANT SELECT, INSERT, UPDATE ON public.brands TO authenticated;
GRANT SELECT ON public.brands TO anon;

GRANT SELECT, INSERT, UPDATE ON public.categories TO authenticated;
GRANT SELECT ON public.categories TO anon;

GRANT SELECT, INSERT, UPDATE ON public.units TO authenticated;
GRANT SELECT ON public.units TO anon;

GRANT SELECT, INSERT, UPDATE ON public.products TO authenticated;
GRANT SELECT ON public.products TO anon;

GRANT SELECT, INSERT, UPDATE ON public.product_variants TO authenticated;
GRANT SELECT ON public.product_variants TO anon;

GRANT SELECT, INSERT, UPDATE ON public.product_prices TO authenticated;
GRANT SELECT ON public.product_prices TO anon;

-- ============================================================
-- GRANTs: Allow service_role to SELECT on catalog tables for pgTAP testing
-- ============================================================
GRANT SELECT ON public.brands TO service_role;
GRANT SELECT ON public.categories TO service_role;
GRANT SELECT ON public.units TO service_role;
GRANT SELECT ON public.products TO service_role;
GRANT SELECT ON public.product_variants TO service_role;
GRANT SELECT ON public.product_prices TO service_role;

-- ============================================================
-- RPC: create_product_with_variant(p JSONB)
-- Atomic insert product + variant + initial price.
-- Auto-generates SKU if null, retries on collision.
-- SECURITY DEFINER: independently verifies company ownership.
-- (source: RC4, RC5, D10, D11, D12)
-- ============================================================
CREATE OR REPLACE FUNCTION public.create_product_with_variant(p JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_company_id  UUID;
  v_product_id  UUID;
  v_variant_id  UUID;
  v_price_id    UUID;
  v_sku         TEXT;
  v_product_slug TEXT;
  v_effective_from TIMESTAMPTZ;
  v_currency    TEXT;
  v_brand_id    UUID;
  v_category_id UUID;
  v_unit_id     UUID;
  v_count       INTEGER;
BEGIN
  -- Independently verify caller's company matches the requested company_id
  v_company_id := p->>'company_id';
  IF v_company_id IS NULL THEN
    RAISE EXCEPTION 'company_id is required';
  END IF;
  IF v_company_id != public.get_company_id() THEN
    RAISE EXCEPTION 'company_id does not match authenticated user company';
  END IF;

  -- Verify caller is admin
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'Only admins can create products';
  END IF;

  -- Validate required fields
  IF p->>'name' IS NULL THEN
    RAISE EXCEPTION 'product name is required';
  END IF;
  IF p->>'slug' IS NULL THEN
    RAISE EXCEPTION 'product slug is required';
  END IF;
  IF p->>'variant_name' IS NULL THEN
    RAISE EXCEPTION 'variant name is required';
  END IF;
  IF (p->>'price')::NUMERIC IS NULL THEN
    RAISE EXCEPTION 'price is required';
  END IF;

  -- Explicitly validate referenced brand ownership and active status
  v_brand_id := (p->>'brand_id')::UUID;
  IF v_brand_id IS NOT NULL THEN
    SELECT count(*) INTO v_count
    FROM public.brands
    WHERE id = v_brand_id AND company_id = v_company_id AND is_active = TRUE;
    IF v_count = 0 THEN
      RAISE EXCEPTION 'brand_id not found, not active, or not owned by your company';
    END IF;
  END IF;

  -- Explicitly validate referenced category ownership and active status
  v_category_id := (p->>'category_id')::UUID;
  IF v_category_id IS NOT NULL THEN
    SELECT count(*) INTO v_count
    FROM public.categories
    WHERE id = v_category_id AND company_id = v_company_id AND is_active = TRUE;
    IF v_count = 0 THEN
      RAISE EXCEPTION 'category_id not found, not active, or not owned by your company';
    END IF;
  END IF;

  -- Explicitly validate unit_id: must be tenant-owned and active (global base units are NOT allowed)
  v_unit_id := (p->>'unit_id')::UUID;
  IF v_unit_id IS NOT NULL THEN
    IF v_unit_id IN (SELECT id FROM public.units WHERE company_id = '00000000-0000-0000-0000-000000000000') THEN
      RAISE EXCEPTION 'global base units cannot be used directly as variant units; create a tenant-owned copy first';
    END IF;
    SELECT count(*) INTO v_count
    FROM public.units
    WHERE id = v_unit_id AND company_id = v_company_id AND is_active = TRUE;
    IF v_count = 0 THEN
      RAISE EXCEPTION 'unit_id not found, not active, or not owned by your company';
    END IF;
  END IF;

  -- Insert product
  INSERT INTO public.products (company_id, name, slug, brand_id, category_id, description, created_by)
  VALUES (
    v_company_id,
    p->>'name',
    p->>'slug',
    v_brand_id,
    v_category_id,
    p->>'description',
    auth.uid()
  )
  RETURNING id INTO v_product_id;

  -- Determine SKU: use provided value or auto-generate from product slug
  v_product_slug := p->>'slug';
  IF p->>'sku' IS NOT NULL AND p->>'sku' != '' THEN
    v_sku := p->>'sku';
  ELSE
    -- Auto-generate: {product_slug}-{random4}
    v_sku := v_product_slug || '-' || lower(substring(md5(random()::text) FROM 1 FOR 4));
  END IF;

  -- Retry loop for SKU collision (case-insensitive)
  BEGIN
    INSERT INTO public.product_variants (company_id, product_id, sku, barcode, name, unit_id, created_by)
    VALUES (
      v_company_id,
      v_product_id,
      v_sku,
      p->>'barcode',
      p->>'variant_name',
      v_unit_id,
      auth.uid()
    )
    RETURNING id INTO v_variant_id;
  EXCEPTION
    WHEN unique_violation THEN
      -- Retry with new random suffix
      v_sku := v_product_slug || '-' || lower(substring(md5(random()::text) FROM 1 FOR 4));
      INSERT INTO public.product_variants (company_id, product_id, sku, barcode, name, unit_id, created_by)
      VALUES (
        v_company_id,
        v_product_id,
        v_sku,
        p->>'barcode',
        p->>'variant_name',
        v_unit_id,
        auth.uid()
      )
      RETURNING id INTO v_variant_id;
  END;

  -- Determine effective_from and currency for initial price
  v_effective_from := COALESCE((p->>'effective_from')::TIMESTAMPTZ, now());
  v_currency := COALESCE(p->>'currency', 'MXN');

  -- Insert initial price
  INSERT INTO public.product_prices (company_id, variant_id, price, currency, effective_from, created_by)
  VALUES (
    v_company_id,
    v_variant_id,
    (p->>'price')::NUMERIC,
    v_currency,
    v_effective_from,
    auth.uid()
  )
  RETURNING id INTO v_price_id;

  RETURN jsonb_build_object(
    'product_id', v_product_id,
    'variant_id', v_variant_id,
    'price_id', v_price_id,
    'sku', v_sku
  );
END;
$$;

COMMENT ON FUNCTION public.create_product_with_variant(JSONB) IS 'Atomic insert product + variant + initial price. SECURITY DEFINER independently verifies company ownership. Auto-generates SKU if null, retries on collision. (source: RC4, RC5, D11, D12)';

-- ============================================================
-- RPC: deactivate_product(p JSONB)
-- Sets is_active=false, deleted_at=now(), deleted_by=auth.uid()
-- on product and all its variants. Verifies company ownership.
-- SECURITY DEFINER: independently verifies company ownership.
-- (source: RC4, D10)
-- ============================================================
CREATE OR REPLACE FUNCTION public.deactivate_product(p JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_company_id UUID;
  v_product_id UUID;
  v_count      INTEGER;
BEGIN
  -- Independently verify caller's company matches the requested company_id
  v_company_id := p->>'company_id';
  IF v_company_id IS NULL THEN
    RAISE EXCEPTION 'company_id is required';
  END IF;
  IF v_company_id != public.get_company_id() THEN
    RAISE EXCEPTION 'company_id does not match authenticated user company';
  END IF;

  -- Verify caller is admin
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'Only admins can deactivate products';
  END IF;

  v_product_id := (p->>'product_id')::UUID;
  IF v_product_id IS NULL THEN
    RAISE EXCEPTION 'product_id is required';
  END IF;

  -- Verify the product belongs to the caller's company
  SELECT count(*) INTO v_count
  FROM public.products
  WHERE id = v_product_id AND company_id = v_company_id AND is_active = TRUE;

  IF v_count = 0 THEN
    RAISE EXCEPTION 'Product not found or not owned by your company';
  END IF;

  -- Deactivate product
  UPDATE public.products
  SET is_active = FALSE,
      deleted_at = now(),
      deleted_by = auth.uid()
  WHERE id = v_product_id AND company_id = v_company_id;

  -- Deactivate all variants of this product
  UPDATE public.product_variants
  SET is_active = FALSE,
      deleted_at = now(),
      deleted_by = auth.uid()
  WHERE product_id = v_product_id AND company_id = v_company_id;

  RETURN jsonb_build_object(
    'product_id', v_product_id,
    'deactivated', TRUE
  );
END;
$$;

COMMENT ON FUNCTION public.deactivate_product(JSONB) IS 'Logical deletion: sets is_active=false on product and all its variants. SECURITY DEFINER independently verifies company ownership. (source: RC4, D10)';

-- ============================================================
-- RPC: update_product(p JSONB)
-- Updates allowed product fields (name, slug, brand_id, category_id, description).
-- SECURITY DEFINER: independently verifies company ownership.
-- Validates brand_id, category_id references if supplied (same company, active).
-- (source: RC4, PR3 corrective follow-up)
-- ============================================================
CREATE OR REPLACE FUNCTION public.update_product(p JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_company_id   UUID;
  v_product_id   UUID;
  v_count        INTEGER;
  v_brand_id     UUID;
  v_category_id  UUID;
BEGIN
  -- Independently verify caller's company matches the requested company_id
  v_company_id := p->>'company_id';
  IF v_company_id IS NULL THEN
    RAISE EXCEPTION 'company_id is required';
  END IF;
  IF v_company_id != public.get_company_id() THEN
    RAISE EXCEPTION 'company_id does not match authenticated user company';
  END IF;

  -- Verify caller is admin
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'Only admins can update products';
  END IF;

  v_product_id := (p->>'product_id')::UUID;
  IF v_product_id IS NULL THEN
    RAISE EXCEPTION 'product_id is required';
  END IF;

  -- Verify the product belongs to the caller's company and is active
  SELECT count(*) INTO v_count
  FROM public.products
  WHERE id = v_product_id AND company_id = v_company_id AND is_active = TRUE;

  IF v_count = 0 THEN
    RAISE EXCEPTION 'Product not found or not owned by your company';
  END IF;

  -- Explicitly validate referenced brand ownership and active status if supplied
  v_brand_id := (p->>'brand_id')::UUID;
  IF p ? 'brand_id' AND v_brand_id IS NOT NULL THEN
    SELECT count(*) INTO v_count
    FROM public.brands
    WHERE id = v_brand_id AND company_id = v_company_id AND is_active = TRUE;
    IF v_count = 0 THEN
      RAISE EXCEPTION 'brand_id not found, not active, or not owned by your company';
    END IF;
  END IF;

  -- Handle explicit null for brand_id (clear the reference)
  -- COALESCE skips NULL fields; we need to distinguish between
  -- "not provided" (left alone) and "explicitly null" (clear reference).
  -- For brand_id: if 'brand_id' key is in JSONB and value is null, clear it.

  -- Explicitly validate referenced category ownership and active status if supplied
  v_category_id := (p->>'category_id')::UUID;
  IF p ? 'category_id' AND v_category_id IS NOT NULL THEN
    SELECT count(*) INTO v_count
    FROM public.categories
    WHERE id = v_category_id AND company_id = v_company_id AND is_active = TRUE;
    IF v_count = 0 THEN
      RAISE EXCEPTION 'category_id not found, not active, or not owned by your company';
    END IF;
  END IF;

  -- Update product fields
  -- Use COALESCE for simple fields (name, slug, description):
  -- omitting a key leaves the current value unchanged.
  -- For nullable FKs (brand_id, category_id), distinguish between
  -- "not provided" (keep current) and "explicitly null" (clear reference).
  UPDATE public.products
  SET name = COALESCE(p->>'name', name),
      slug = COALESCE(p->>'slug', slug),
      brand_id = CASE
        WHEN p ? 'brand_id' AND (p->>'brand_id') IS NULL THEN NULL
        WHEN p ? 'brand_id' THEN (p->>'brand_id')::UUID
        ELSE brand_id
      END,
      category_id = CASE
        WHEN p ? 'category_id' AND (p->>'category_id') IS NULL THEN NULL
        WHEN p ? 'category_id' THEN (p->>'category_id')::UUID
        ELSE category_id
      END,
      description = COALESCE(p->>'description', description),
      updated_by = auth.uid()
  WHERE id = v_product_id AND company_id = v_company_id;

  RETURN jsonb_build_object('product_id', v_product_id, 'updated', TRUE);
END;
$$;

COMMENT ON FUNCTION public.update_product(JSONB) IS 'Update product fields (name, slug, brand_id, category_id, description). SECURITY DEFINER independently verifies company ownership and validates FK references. (source: RC4, PR3 corrective follow-up)';

-- ============================================================
-- RPC: set_variant_price(p JSONB)
-- Closes previous active price at effective_from, inserts new price.
-- Uses SELECT FOR UPDATE on current active price for concurrency.
-- SECURITY DEFINER: independently verifies company ownership.
-- Defaults: effective_from=now(), currency='MXN'.
-- (source: RC5, D10, D12)
-- ============================================================
CREATE OR REPLACE FUNCTION public.set_variant_price(p JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_company_id     UUID;
  v_variant_id     UUID;
  v_price          NUMERIC;
  v_currency       TEXT;
  v_effective_from TIMESTAMPTZ;
  v_new_price_id   UUID;
  v_closed_rows    INTEGER;
  v_active_from    TIMESTAMPTZ;
BEGIN
  -- Independently verify caller's company matches the requested company_id
  v_company_id := p->>'company_id';
  IF v_company_id IS NULL THEN
    RAISE EXCEPTION 'company_id is required';
  END IF;
  IF v_company_id != public.get_company_id() THEN
    RAISE EXCEPTION 'company_id does not match authenticated user company';
  END IF;

  -- Verify caller is admin
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'Only admins can set prices';
  END IF;

  v_variant_id := (p->>'variant_id')::UUID;
  IF v_variant_id IS NULL THEN
    RAISE EXCEPTION 'variant_id is required';
  END IF;

  -- Verify variant belongs to caller's company and is active
  IF NOT EXISTS (
    SELECT 1 FROM public.product_variants
    WHERE id = v_variant_id AND company_id = v_company_id AND is_active = TRUE
  ) THEN
    RAISE EXCEPTION 'Variant not found or not owned by your company';
  END IF;

  v_price := (p->>'price')::NUMERIC;
  IF v_price IS NULL THEN
    RAISE EXCEPTION 'price is required';
  END IF;

  v_currency := COALESCE(p->>'currency', 'MXN');
  v_effective_from := COALESCE((p->>'effective_from')::TIMESTAMPTZ, now());

  -- Harden: verify new effective_from does not overlap existing closed intervals
  -- An overlap occurs when the new effective_from falls inside an existing interval:
  --   existing.effective_from < v_effective_from AND existing.effective_until > v_effective_from
  -- This ensures temporal continuity: prices form a non-overlapping chain.
  IF EXISTS (
    SELECT 1 FROM public.product_prices
    WHERE variant_id = v_variant_id
      AND effective_until IS NOT NULL
      AND effective_from < v_effective_from
      AND effective_until > v_effective_from
  ) THEN
    RAISE EXCEPTION 'New price effective_from would overlap with an existing price interval';
  END IF;

  -- Close previous active price: SELECT FOR UPDATE serializes concurrent calls
  UPDATE public.product_prices
  SET effective_until = v_effective_from
  WHERE id IN (
    SELECT id FROM public.product_prices
    WHERE variant_id = v_variant_id
      AND effective_until IS NULL
    FOR UPDATE
  );

  GET DIAGNOSTICS v_closed_rows = ROW_COUNT;

  -- Harden: verify the new effective_from is not before the closed active price's effective_from
  -- This prevents creating invalid intervals where effective_until < effective_from
  IF v_closed_rows > 0 THEN
    SELECT effective_from INTO v_active_from
    FROM public.product_prices
    WHERE variant_id = v_variant_id
      AND effective_until = v_effective_from
    LIMIT 1;

    IF v_active_from IS NOT NULL AND v_effective_from < v_active_from THEN
      RAISE EXCEPTION 'New price effective_from cannot be earlier than current active price effective_from (%)', v_active_from;
    END IF;
  END IF;

  -- Insert new price
  INSERT INTO public.product_prices (company_id, variant_id, price, currency, effective_from, created_by)
  VALUES (v_company_id, v_variant_id, v_price, v_currency, v_effective_from, auth.uid())
  RETURNING id INTO v_new_price_id;

  RETURN jsonb_build_object(
    'price_id', v_new_price_id,
    'variant_id', v_variant_id,
    'price', v_price,
    'currency', v_currency,
    'effective_from', v_effective_from,
    'previous_price_closed', v_closed_rows > 0
  );
END;
$$;

COMMENT ON FUNCTION public.set_variant_price(JSONB) IS 'Closes previous active price at effective_from and inserts new price. Uses SELECT FOR UPDATE for concurrency. SECURITY DEFINER independently verifies company ownership. (source: RC5, D12)';

-- ============================================================
-- RPC: create_brand(p JSONB)
-- SECURITY DEFINER: independently verifies company_id.
-- (source: RC1, D10)
-- ============================================================
CREATE OR REPLACE FUNCTION public.create_brand(p JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_company_id UUID;
  v_id         UUID;
BEGIN
  v_company_id := p->>'company_id';
  IF v_company_id IS NULL THEN
    RAISE EXCEPTION 'company_id is required';
  END IF;
  IF v_company_id != public.get_company_id() THEN
    RAISE EXCEPTION 'company_id does not match authenticated user company';
  END IF;
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'Only admins can create brands';
  END IF;

  INSERT INTO public.brands (company_id, name, slug, created_by)
  VALUES (v_company_id, p->>'name', p->>'slug', auth.uid())
  RETURNING id INTO v_id;

  RETURN jsonb_build_object('id', v_id, 'company_id', v_company_id);
END;
$$;

COMMENT ON FUNCTION public.create_brand(JSONB) IS 'Create a brand. SECURITY DEFINER independently verifies company ownership. (source: RC1)';

-- ============================================================
-- RPC: update_brand(p JSONB)
-- SECURITY DEFINER: independently verifies company ownership.
-- (source: RC1, D10)
-- ============================================================
CREATE OR REPLACE FUNCTION public.update_brand(p JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_company_id UUID;
  v_id         UUID;
  v_count      INTEGER;
BEGIN
  v_company_id := p->>'company_id';
  IF v_company_id IS NULL THEN
    RAISE EXCEPTION 'company_id is required';
  END IF;
  IF v_company_id != public.get_company_id() THEN
    RAISE EXCEPTION 'company_id does not match authenticated user company';
  END IF;
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'Only admins can update brands';
  END IF;

  v_id := (p->>'id')::UUID;
  IF v_id IS NULL THEN
    RAISE EXCEPTION 'brand id is required';
  END IF;

  -- Verify ownership
  SELECT count(*) INTO v_count
  FROM public.brands
  WHERE id = v_id AND company_id = v_company_id AND is_active = TRUE;

  IF v_count = 0 THEN
    RAISE EXCEPTION 'Brand not found or not owned by your company';
  END IF;

  UPDATE public.brands
  SET name = COALESCE(p->>'name', name),
      slug = COALESCE(p->>'slug', slug),
      updated_by = auth.uid()
  WHERE id = v_id AND company_id = v_company_id;

  RETURN jsonb_build_object('id', v_id, 'updated', TRUE);
END;
$$;

COMMENT ON FUNCTION public.update_brand(JSONB) IS 'Update brand name/slug. SECURITY DEFINER independently verifies company ownership. (source: RC1)';

-- ============================================================
-- RPC: deactivate_brand(p JSONB)
-- Logical deletion. SECURITY DEFINER: independently verifies company ownership.
-- (source: RC1, D10)
-- ============================================================
CREATE OR REPLACE FUNCTION public.deactivate_brand(p JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_company_id UUID;
  v_id         UUID;
  v_count      INTEGER;
BEGIN
  v_company_id := p->>'company_id';
  IF v_company_id IS NULL THEN
    RAISE EXCEPTION 'company_id is required';
  END IF;
  IF v_company_id != public.get_company_id() THEN
    RAISE EXCEPTION 'company_id does not match authenticated user company';
  END IF;
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'Only admins can deactivate brands';
  END IF;

  v_id := (p->>'id')::UUID;
  IF v_id IS NULL THEN
    RAISE EXCEPTION 'brand id is required';
  END IF;

  -- Verify ownership
  SELECT count(*) INTO v_count
  FROM public.brands
  WHERE id = v_id AND company_id = v_company_id AND is_active = TRUE;

  IF v_count = 0 THEN
    RAISE EXCEPTION 'Brand not found or not owned by your company';
  END IF;

  UPDATE public.brands
  SET is_active = FALSE,
      deleted_at = now(),
      deleted_by = auth.uid()
  WHERE id = v_id AND company_id = v_company_id;

  RETURN jsonb_build_object('id', v_id, 'deactivated', TRUE);
END;
$$;

COMMENT ON FUNCTION public.deactivate_brand(JSONB) IS 'Logical deletion: sets is_active=false on brand. SECURITY DEFINER independently verifies company ownership. (source: RC1)';

-- ============================================================
-- RPC: create_category(p JSONB)
-- SECURITY DEFINER: independently verifies company_id.
-- Category cycle/depth trigger enforces invariants.
-- (source: RC2, D10)
-- ============================================================
CREATE OR REPLACE FUNCTION public.create_category(p JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_company_id UUID;
  v_id         UUID;
  v_parent_id  UUID;
  v_count      INTEGER;
BEGIN
  v_company_id := p->>'company_id';
  IF v_company_id IS NULL THEN
    RAISE EXCEPTION 'company_id is required';
  END IF;
  IF v_company_id != public.get_company_id() THEN
    RAISE EXCEPTION 'company_id does not match authenticated user company';
  END IF;
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'Only admins can create categories';
  END IF;

  -- Explicitly validate parent_id: must be same company and active
  v_parent_id := (p->>'parent_id')::UUID;
  IF v_parent_id IS NOT NULL THEN
    SELECT count(*) INTO v_count
    FROM public.categories
    WHERE id = v_parent_id AND company_id = v_company_id AND is_active = TRUE;
    IF v_count = 0 THEN
      RAISE EXCEPTION 'parent_id not found, not active, or not owned by your company';
    END IF;
  END IF;

  INSERT INTO public.categories (company_id, name, slug, parent_id, created_by)
  VALUES (
    v_company_id,
    p->>'name',
    p->>'slug',
    v_parent_id,
    auth.uid()
  )
  RETURNING id INTO v_id;

  RETURN jsonb_build_object('id', v_id, 'company_id', v_company_id);
END;
$$;

COMMENT ON FUNCTION public.create_category(JSONB) IS 'Create a category. Cycle/depth trigger enforces invariants. SECURITY DEFINER independently verifies company ownership. (source: RC2)';

-- ============================================================
-- RPC: update_category(p JSONB)
-- SECURITY DEFINER: independently verifies company ownership.
-- Category cycle/depth trigger enforces invariants on update.
-- (source: RC2, D10)
-- ============================================================
CREATE OR REPLACE FUNCTION public.update_category(p JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_company_id UUID;
  v_id         UUID;
  v_parent_id  UUID;
  v_count      INTEGER;
BEGIN
  v_company_id := p->>'company_id';
  IF v_company_id IS NULL THEN
    RAISE EXCEPTION 'company_id is required';
  END IF;
  IF v_company_id != public.get_company_id() THEN
    RAISE EXCEPTION 'company_id does not match authenticated user company';
  END IF;
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'Only admins can update categories';
  END IF;

  v_id := (p->>'id')::UUID;
  IF v_id IS NULL THEN
    RAISE EXCEPTION 'category id is required';
  END IF;

  -- Verify ownership
  SELECT count(*) INTO v_count
  FROM public.categories
  WHERE id = v_id AND company_id = v_company_id AND is_active = TRUE;

  IF v_count = 0 THEN
    RAISE EXCEPTION 'Category not found or not owned by your company';
  END IF;

  -- Explicitly validate parent_id when supplied:
  -- must be same company, active, and not the row itself
  v_parent_id := (p->>'parent_id')::UUID;
  IF p ? 'parent_id' AND v_parent_id IS NOT NULL THEN
    -- Self-reference check (direct cycle)
    IF v_parent_id = v_id THEN
      RAISE EXCEPTION 'parent_id cannot reference itself';
    END IF;

    SELECT count(*) INTO v_count
    FROM public.categories
    WHERE id = v_parent_id AND company_id = v_company_id AND is_active = TRUE;
    IF v_count = 0 THEN
      RAISE EXCEPTION 'parent_id not found, not active, or not owned by your company';
    END IF;
  END IF;

  UPDATE public.categories
  SET name = COALESCE(p->>'name', name),
      slug = COALESCE(p->>'slug', slug),
      parent_id = CASE WHEN p ? 'parent_id' THEN (p->>'parent_id')::UUID ELSE parent_id END,
      updated_by = auth.uid()
  WHERE id = v_id AND company_id = v_company_id;

  RETURN jsonb_build_object('id', v_id, 'updated', TRUE);
END;
$$;

COMMENT ON FUNCTION public.update_category(JSONB) IS 'Update category name/slug/parent_id. Security DEFINER independently verifies company ownership. Cycle/depth trigger enforces invariants. (source: RC2)';

-- ============================================================
-- RPC: deactivate_category(p JSONB)
-- Logical deletion. SECURITY DEFINER: independently verifies company ownership.
-- Children remain active (no cascading deactivation).
-- (source: RC2, D10)
-- ============================================================
CREATE OR REPLACE FUNCTION public.deactivate_category(p JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_company_id UUID;
  v_id         UUID;
  v_count      INTEGER;
BEGIN
  v_company_id := p->>'company_id';
  IF v_company_id IS NULL THEN
    RAISE EXCEPTION 'company_id is required';
  END IF;
  IF v_company_id != public.get_company_id() THEN
    RAISE EXCEPTION 'company_id does not match authenticated user company';
  END IF;
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'Only admins can deactivate categories';
  END IF;

  v_id := (p->>'id')::UUID;
  IF v_id IS NULL THEN
    RAISE EXCEPTION 'category id is required';
  END IF;

  -- Verify ownership
  SELECT count(*) INTO v_count
  FROM public.categories
  WHERE id = v_id AND company_id = v_company_id AND is_active = TRUE;

  IF v_count = 0 THEN
    RAISE EXCEPTION 'Category not found or not owned by your company';
  END IF;

  UPDATE public.categories
  SET is_active = FALSE,
      deleted_at = now(),
      deleted_by = auth.uid()
  WHERE id = v_id AND company_id = v_company_id;

  RETURN jsonb_build_object('id', v_id, 'deactivated', TRUE);
END;
$$;

COMMENT ON FUNCTION public.deactivate_category(JSONB) IS 'Logical deletion: sets is_active=false on category. Children remain active. SECURITY DEFINER independently verifies company ownership. (source: RC2)';

-- ============================================================
-- RPC: create_unit(p JSONB)
-- SECURITY DEFINER: independently verifies company_id.
-- Tenants create their own tenant-owned unit rows (copies of global templates).
-- (source: RC3, D10)
-- ============================================================
CREATE OR REPLACE FUNCTION public.create_unit(p JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_company_id UUID;
  v_id         UUID;
BEGIN
  v_company_id := p->>'company_id';
  IF v_company_id IS NULL THEN
    RAISE EXCEPTION 'company_id is required';
  END IF;
  IF v_company_id != public.get_company_id() THEN
    RAISE EXCEPTION 'company_id does not match authenticated user company';
  END IF;
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'Only admins can create units';
  END IF;

  INSERT INTO public.units (company_id, name, abbreviation, created_by)
  VALUES (v_company_id, p->>'name', p->>'abbreviation', auth.uid())
  RETURNING id INTO v_id;

  RETURN jsonb_build_object('id', v_id, 'company_id', v_company_id);
END;
$$;

COMMENT ON FUNCTION public.create_unit(JSONB) IS 'Create a tenant-owned unit. SECURITY DEFINER independently verifies company ownership. Tenants copy global templates into their own rows. (source: RC3)';

-- ============================================================
-- RPC: update_unit(p JSONB)
-- SECURITY DEFINER: independently verifies company ownership.
-- (source: RC3, D10)
-- ============================================================
CREATE OR REPLACE FUNCTION public.update_unit(p JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_company_id UUID;
  v_id         UUID;
  v_count      INTEGER;
BEGIN
  v_company_id := p->>'company_id';
  IF v_company_id IS NULL THEN
    RAISE EXCEPTION 'company_id is required';
  END IF;
  IF v_company_id != public.get_company_id() THEN
    RAISE EXCEPTION 'company_id does not match authenticated user company';
  END IF;
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'Only admins can update units';
  END IF;

  v_id := (p->>'id')::UUID;
  IF v_id IS NULL THEN
    RAISE EXCEPTION 'unit id is required';
  END IF;

  -- Verify ownership AND that unit belongs to the tenant (not global)
  SELECT count(*) INTO v_count
  FROM public.units
  WHERE id = v_id AND company_id = v_company_id AND is_active = TRUE;

  IF v_count = 0 THEN
    RAISE EXCEPTION 'Unit not found or not owned by your company';
  END IF;

  -- Reject updates to global base unit templates
  IF v_company_id = '00000000-0000-0000-0000-000000000000' THEN
    RAISE EXCEPTION 'Cannot update global base unit templates';
  END IF;

  UPDATE public.units
  SET name = COALESCE(p->>'name', name),
      abbreviation = COALESCE(p->>'abbreviation', abbreviation),
      updated_by = auth.uid()
  WHERE id = v_id AND company_id = v_company_id;

  RETURN jsonb_build_object('id', v_id, 'updated', TRUE);
END;
$$;

COMMENT ON FUNCTION public.update_unit(JSONB) IS 'Update tenant-owned unit name/abbreviation. SECURITY DEFINER independently verifies company ownership. Global base units cannot be updated through this RPC. (source: RC3)';

-- ============================================================
-- RPC: deactivate_unit(p JSONB)
-- Logical deletion. SECURITY DEFINER: independently verifies company ownership.
-- Global base units cannot be deactivated through this RPC.
-- (source: RC3, D10)
-- ============================================================
CREATE OR REPLACE FUNCTION public.deactivate_unit(p JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_company_id UUID;
  v_id         UUID;
  v_count      INTEGER;
BEGIN
  v_company_id := p->>'company_id';
  IF v_company_id IS NULL THEN
    RAISE EXCEPTION 'company_id is required';
  END IF;
  IF v_company_id != public.get_company_id() THEN
    RAISE EXCEPTION 'company_id does not match authenticated user company';
  END IF;
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'Only admins can deactivate units';
  END IF;

  v_id := (p->>'id')::UUID;
  IF v_id IS NULL THEN
    RAISE EXCEPTION 'unit id is required';
  END IF;

  -- Reject deactivation of global base unit templates
  IF v_company_id = '00000000-0000-0000-0000-000000000000' THEN
    RAISE EXCEPTION 'Cannot deactivate global base unit templates';
  END IF;

  -- Verify ownership
  SELECT count(*) INTO v_count
  FROM public.units
  WHERE id = v_id AND company_id = v_company_id AND is_active = TRUE;

  IF v_count = 0 THEN
    RAISE EXCEPTION 'Unit not found or not owned by your company';
  END IF;

  UPDATE public.units
  SET is_active = FALSE,
      deleted_at = now(),
      deleted_by = auth.uid()
  WHERE id = v_id AND company_id = v_company_id;

  RETURN jsonb_build_object('id', v_id, 'deactivated', TRUE);
END;
$$;

COMMENT ON FUNCTION public.deactivate_unit(JSONB) IS 'Logical deletion: sets is_active=false on tenant-owned unit. Global base units cannot be deactivated through this RPC. SECURITY DEFINER independently verifies company ownership. (source: RC3)';

-- ============================================================
-- GRANTs: Allow authenticated role to execute catalog RPCs
-- SECURITY DEFINER functions run with definer privileges,
-- but the caller still needs EXECUTE permission.
-- Revoke default PUBLIC and anon EXECUTE to prevent unauthenticated
-- or unintended role access to mutation RPCs.
-- (source: RC1–RC5, D10, PR2 hardening)
-- ============================================================
REVOKE ALL ON FUNCTION public.create_product_with_variant(JSONB) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.deactivate_product(JSONB) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.update_product(JSONB) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.set_variant_price(JSONB) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.create_brand(JSONB) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.update_brand(JSONB) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.deactivate_brand(JSONB) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.create_category(JSONB) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.update_category(JSONB) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.deactivate_category(JSONB) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.create_unit(JSONB) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.update_unit(JSONB) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.deactivate_unit(JSONB) FROM PUBLIC;

REVOKE ALL ON FUNCTION public.create_product_with_variant(JSONB) FROM anon;
REVOKE ALL ON FUNCTION public.deactivate_product(JSONB) FROM anon;
REVOKE ALL ON FUNCTION public.update_product(JSONB) FROM anon;
REVOKE ALL ON FUNCTION public.set_variant_price(JSONB) FROM anon;
REVOKE ALL ON FUNCTION public.create_brand(JSONB) FROM anon;
REVOKE ALL ON FUNCTION public.update_brand(JSONB) FROM anon;
REVOKE ALL ON FUNCTION public.deactivate_brand(JSONB) FROM anon;
REVOKE ALL ON FUNCTION public.create_category(JSONB) FROM anon;
REVOKE ALL ON FUNCTION public.update_category(JSONB) FROM anon;
REVOKE ALL ON FUNCTION public.deactivate_category(JSONB) FROM anon;
REVOKE ALL ON FUNCTION public.create_unit(JSONB) FROM anon;
REVOKE ALL ON FUNCTION public.update_unit(JSONB) FROM anon;
REVOKE ALL ON FUNCTION public.deactivate_unit(JSONB) FROM anon;

GRANT EXECUTE ON FUNCTION public.create_product_with_variant(JSONB) TO authenticated;
GRANT EXECUTE ON FUNCTION public.deactivate_product(JSONB) TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_product(JSONB) TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_variant_price(JSONB) TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_brand(JSONB) TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_brand(JSONB) TO authenticated;
GRANT EXECUTE ON FUNCTION public.deactivate_brand(JSONB) TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_category(JSONB) TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_category(JSONB) TO authenticated;
GRANT EXECUTE ON FUNCTION public.deactivate_category(JSONB) TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_unit(JSONB) TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_unit(JSONB) TO authenticated;
GRANT EXECUTE ON FUNCTION public.deactivate_unit(JSONB) TO authenticated;