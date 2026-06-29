-- =============================================================================
-- Supabase POS — Local development seed data
-- Company: Farmacia Salud (pharmacy / supplement store)
--
-- Executed automatically after migrations via `supabase db reset`.
-- Runs as the `postgres` superuser, so RLS is bypassed and the
-- `prevent_inventory_quantity_direct_edit` / `prevent_purchasing_critical_col`
-- BEFORE-UPDATE guards evaluate `current_user NOT IN ('postgres','service_role')`
-- to FALSE → they permit the sale-time stock decrement below.
--
-- Notes:
--   * A single DO block carries DECLARE variables for every UUID so they can be
--     referenced across inserts (psql \set variables do not survive DO blocks).
--   * `sales.customer_id` has a composite FK to public.customers(company_id, id).
--     Seeded cashier sales still use customer_id = NULL, but the two pharmacy
--     customers are now attachable directly to POS sales and credit balances.
--   * A `purchase_receipt` stock_movement is created for every lot so that
--     reconcile_inventory reports NO drift (SUM(movements) == remaining_qty).
--   * Insert order follows FK dependencies strictly.
-- =============================================================================

DO $$
DECLARE
  -- Tenants / users
  v_company_id    UUID  := 'a1b2c3d4-0001-0001-0001-000000000001';  -- fixed, predictable
  v_admin_id      UUID;
  v_cashier_id    UUID;
  v_branch_centro UUID;
  v_branch_norte  UUID;

  -- Catalog: categories
  v_cat_meds  UUID;
  v_cat_vits  UUID;
  v_cat_cuid  UUID;
  v_cat_beb   UUID;

  -- Catalog: brands
  v_brand_gen UUID;
  v_brand_bay UUID;
  v_brand_pfi UUID;
  v_brand_jnj UUID;

  -- Catalog: tenant-owned units
  v_unit_pza   UUID;
  v_unit_caja  UUID;
  v_unit_blis  UUID;
  v_unit_ml    UUID;

  -- Products
  v_prod_para  UUID;
  v_prod_vitc  UUID;
  v_prod_ibu   UUID;
  v_prod_pan   UUID;
  v_prod_jab   UUID;
  v_prod_mult  UUID;

  -- Variants (9)
  v_v1 UUID;  -- Paracetamol 500mg blister x10
  v_v2 UUID;  -- Paracetamol 500mg caja x20
  v_v3 UUID;  -- Vitamina C 1000mg blister x10
  v_v4 UUID;  -- Vitamina C 1000mg caja x30
  v_v5 UUID;  -- Ibuprofeno 400mg blister x10
  v_v6 UUID;  -- Pañales Etapa 1 caja x30
  v_v7 UUID;  -- Pañales Etapa 1 caja x60
  v_v8 UUID;  -- Jabón de manos 200ml
  v_v9 UUID;  -- Multivitamínico caja x30

  -- Suppliers
  v_sup1 UUID;  -- Distribuidora Farmacéutica S.A.
  v_sup2 UUID;  -- VitaminLab México
  v_sup3 UUID;  -- CuidadoTotal

  -- Purchasing
  v_po_id      UUID;

  -- Customers / demand
  v_customer1  UUID;  -- Juan Pérez
  v_customer2  UUID;  -- María García
  v_preorder_id UUID;

  -- Cash + sales
  v_cash_session_id UUID;
  v_sale_id      UUID;
  v_sale_item_id UUID;
  v_sale_lot_id  UUID;  -- lot used for the cashier sale deduction

  -- Lot loop
  v_lots        JSONB;
  v_lot         JSONB;
  v_lot_id      UUID;
  v_lot_branch  UUID;
  v_lot_exp     DATE;
  v_lot_qty     NUMERIC(14,3);
  v_lot_cost    NUMERIC(12,2);
  v_mv_id       UUID;
BEGIN
  -- =========================================================================
  -- 1. AUTH USERS (encrypted with bcrypt)
  -- =========================================================================
  INSERT INTO auth.users (
    id, instance_id, aud, role, email, encrypted_password,
    email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data,
    created_at, updated_at
  )
  VALUES (
    gen_random_uuid(), '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated',
    'admin@farmacia.com',
    crypt('admin123', gen_salt('bf')),
    now(),
    jsonb_build_object('company_id', v_company_id, 'role', 'admin'),
    jsonb_build_object('full_name', 'Administrador Farmacia Salud'),
    now(), now()
  )
  RETURNING id INTO v_admin_id;

  INSERT INTO auth.users (
    id, instance_id, aud, role, email, encrypted_password,
    email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data,
    created_at, updated_at
  )
  VALUES (
    gen_random_uuid(), '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated',
    'cashier@farmacia.com',
    crypt('cashier123', gen_salt('bf')),
    now(),
    jsonb_build_object('company_id', v_company_id, 'role', 'cashier'),
    jsonb_build_object('full_name', 'Cajero Sucursal Centro'),
    now(), now()
  )
  RETURNING id INTO v_cashier_id;

  -- =========================================================================
  -- 2. PROFILES + COMPANY_USERS + BRANCH_USERS + BRANCHES
  -- =========================================================================
  INSERT INTO public.profiles (id, full_name, avatar_url) VALUES
    (v_admin_id,    'Administrador Farmacia Salud', NULL),
    (v_cashier_id,  'Cajero Sucursal Centro',       NULL);

  INSERT INTO public.companies (id, name, slug, tax_id, address, phone, email, is_active)
  VALUES (
    v_company_id, 'Farmacia Salud', 'farmacia-salud',
    'FARM123456789', 'Av. Centro 100, CDMX', '55-1234-5678',
    'contacto@farmacia-salud.com', TRUE
  );

  INSERT INTO public.branches (company_id, name, slug, address, phone, is_active) VALUES
    (v_company_id, 'Sucursal Centro', 'sucursal-centro',
     'Av. Centro 100, CDMX', '55-1234-5678', TRUE)
    RETURNING id INTO v_branch_centro;

  INSERT INTO public.branches (company_id, name, slug, address, phone, is_active) VALUES
    (v_company_id, 'Sucursal Norte', 'sucursal-norte',
     'Blvd. Norte 500, CDMX', '55-8765-4321', TRUE)
    RETURNING id INTO v_branch_norte;

  INSERT INTO public.company_users (user_id, company_id, role, is_active) VALUES
    (v_admin_id,    v_company_id, 'admin',    TRUE),
    (v_cashier_id,  v_company_id, 'cashier', TRUE);

  -- Cashier is assigned to Sucursal Centro.
  INSERT INTO public.branch_users (user_id, branch_id, company_id, is_active) VALUES
    (v_cashier_id, v_branch_centro, v_company_id, TRUE);

  -- =========================================================================
  -- 3. CATALOG — Categories (4)
  -- =========================================================================
  INSERT INTO public.categories (company_id, name, slug, parent_id, is_active)
  VALUES (v_company_id, 'Medicamentos',            'medicamentos',           NULL, TRUE)
    RETURNING id INTO v_cat_meds;
  INSERT INTO public.categories (company_id, name, slug, parent_id, is_active)
  VALUES (v_company_id, 'Vitaminas y Suplementos', 'vitaminas-y-suplementos', NULL, TRUE)
    RETURNING id INTO v_cat_vits;
  INSERT INTO public.categories (company_id, name, slug, parent_id, is_active)
  VALUES (v_company_id, 'Cuidado Personal',       'cuidado-personal',        NULL, TRUE)
    RETURNING id INTO v_cat_cuid;
  INSERT INTO public.categories (company_id, name, slug, parent_id, is_active)
  VALUES (v_company_id, 'Bebés y Maternidad',      'bebes-y-maternidad',      NULL, TRUE)
    RETURNING id INTO v_cat_beb;

  -- =========================================================================
  -- 4. CATALOG — Brands (4)
  -- =========================================================================
  INSERT INTO public.brands (company_id, name, slug, is_active)
  VALUES (v_company_id, 'Genérico', 'generico', TRUE) RETURNING id INTO v_brand_gen;
  INSERT INTO public.brands (company_id, name, slug, is_active)
  VALUES (v_company_id, 'Bayer', 'bayer', TRUE) RETURNING id INTO v_brand_bay;
  INSERT INTO public.brands (company_id, name, slug, is_active)
  VALUES (v_company_id, 'Pfizer', 'pfizer', TRUE) RETURNING id INTO v_brand_pfi;
  INSERT INTO public.brands (company_id, name, slug, is_active)
  VALUES (v_company_id, 'Johnson & Johnson', 'johnson-johnson', TRUE) RETURNING id INTO v_brand_jnj;

  -- =========================================================================
  -- 5. CATALOG — Tenant-owned Units (4)
  -- (Global base units in 00004 cannot be used by tenants due to the
  --  fk_product_variants_unit_same_company composite FK.)
  -- =========================================================================
  INSERT INTO public.units (company_id, name, abbreviation, is_active)
  VALUES (v_company_id, 'pieza', 'pza', TRUE) RETURNING id INTO v_unit_pza;
  INSERT INTO public.units (company_id, name, abbreviation, is_active)
  VALUES (v_company_id, 'caja', 'caja', TRUE) RETURNING id INTO v_unit_caja;
  INSERT INTO public.units (company_id, name, abbreviation, is_active)
  VALUES (v_company_id, 'blister', 'blis', TRUE) RETURNING id INTO v_unit_blis;
  INSERT INTO public.units (company_id, name, abbreviation, is_active)
  VALUES (v_company_id, 'ml', 'ml', TRUE) RETURNING id INTO v_unit_ml;

  -- =========================================================================
  -- 6. CATALOG — Products (6) + Variants (9) + Active prices (9)
  -- =========================================================================
  -- Paracetamol 500mg (2 variants)
  INSERT INTO public.products (company_id, name, slug, brand_id, category_id, description, is_active)
  VALUES (v_company_id, 'Paracetamol 500mg', 'paracetamol-500mg', v_brand_pfi, v_cat_meds,
          'Analgésico y antipirético', TRUE)
    RETURNING id INTO v_prod_para;
  INSERT INTO public.product_variants (company_id, product_id, sku, barcode, name, unit_id, is_active)
  VALUES (v_company_id, v_prod_para, 'PARA-10', '7501000000011', 'Paracetamol 500mg x 10 tabletas (blister)', v_unit_blis, TRUE)
    RETURNING id INTO v_v1;
  INSERT INTO public.product_variants (company_id, product_id, sku, barcode, name, unit_id, is_active)
  VALUES (v_company_id, v_prod_para, 'PARA-20', '7501000000028', 'Paracetamol 500mg x 20 tabletas (caja)',   v_unit_caja, TRUE)
    RETURNING id INTO v_v2;

  -- Vitamina C 1000mg (2 variants)
  INSERT INTO public.products (company_id, name, slug, brand_id, category_id, description, is_active)
  VALUES (v_company_id, 'Vitamina C 1000mg', 'vitamina-c-1000mg', v_brand_bay, v_cat_vits,
          'Antioxidante e inmunomodulador', TRUE)
    RETURNING id INTO v_prod_vitc;
  INSERT INTO public.product_variants (company_id, product_id, sku, barcode, name, unit_id, is_active)
  VALUES (v_company_id, v_prod_vitc, 'VITC-10', '7501000000035', 'Vitamina C 1000mg x 10 tabletas (blister)', v_unit_blis, TRUE)
    RETURNING id INTO v_v3;
  INSERT INTO public.product_variants (company_id, product_id, sku, barcode, name, unit_id, is_active)
  VALUES (v_company_id, v_prod_vitc, 'VITC-30', '7501000000042', 'Vitamina C 1000mg x 30 tabletas (caja)',    v_unit_caja, TRUE)
    RETURNING id INTO v_v4;

  -- Ibuprofeno 400mg (1 variant)
  INSERT INTO public.products (company_id, name, slug, brand_id, category_id, description, is_active)
  VALUES (v_company_id, 'Ibuprofeno 400mg', 'ibuprofeno-400mg', v_brand_gen, v_cat_meds,
          'Antiinflamatorio no esteroideo', TRUE)
    RETURNING id INTO v_prod_ibu;
  INSERT INTO public.product_variants (company_id, product_id, sku, barcode, name, unit_id, is_active)
  VALUES (v_company_id, v_prod_ibu, 'IBU-10', '7501000000059', 'Ibuprofeno 400mg x 10 tabletas (blister)', v_unit_blis, TRUE)
    RETURNING id INTO v_v5;

  -- Pañales Etapa 1 (2 variants)
  INSERT INTO public.products (company_id, name, slug, brand_id, category_id, description, is_active)
  VALUES (v_company_id, 'Pañales Etapa 1', 'panales-etapa-1', v_brand_jnj, v_cat_beb,
          'Pañales desechables para recién nacido', TRUE)
    RETURNING id INTO v_prod_pan;
  INSERT INTO public.product_variants (company_id, product_id, sku, barcode, name, unit_id, is_active)
  VALUES (v_company_id, v_prod_pan, 'PAN-30', '7501000000066', 'Pañales Etapa 1 x 30 (caja)', v_unit_caja, TRUE)
    RETURNING id INTO v_v6;
  INSERT INTO public.product_variants (company_id, product_id, sku, barcode, name, unit_id, is_active)
  VALUES (v_company_id, v_prod_pan, 'PAN-60', '7501000000073', 'Pañales Etapa 1 x 60 (caja)', v_unit_caja, TRUE)
    RETURNING id INTO v_v7;

  -- Jabón de manos (1 variant)
  INSERT INTO public.products (company_id, name, slug, brand_id, category_id, description, is_active)
  VALUES (v_company_id, 'Jabón de manos', 'jabon-de-manos', v_brand_jnj, v_cat_cuid,
          'Jabón líquido antibacterial 200ml', TRUE)
    RETURNING id INTO v_prod_jab;
  INSERT INTO public.product_variants (company_id, product_id, sku, barcode, name, unit_id, is_active)
  VALUES (v_company_id, v_prod_jab, 'JAB-200', '7501000000080', 'Jabón de manos 200ml', v_unit_pza, TRUE)
    RETURNING id INTO v_v8;

  -- Multivitamínico (1 variant)
  INSERT INTO public.products (company_id, name, slug, brand_id, category_id, description, is_active)
  VALUES (v_company_id, 'Multivitamínico', 'multivitaminico', v_brand_gen, v_cat_vits,
          'Multivitamínico diario para adulto', TRUE)
    RETURNING id INTO v_prod_mult;
  INSERT INTO public.product_variants (company_id, product_id, sku, barcode, name, unit_id, is_active)
  VALUES (v_company_id, v_prod_mult, 'MULT-30', '7501000000097', 'Multivitamínico x 30 tabletas (caja)', v_unit_caja, TRUE)
    RETURNING id INTO v_v9;

  -- Active prices (one per variant; effective_until IS NULL keeps the unique
  -- partial index idx_product_prices_active satisfied).
  INSERT INTO public.product_prices (company_id, variant_id, price, currency, effective_from, effective_until, is_active) VALUES
    (v_company_id, v_v1, 35.00,  'MXN', now(), NULL, TRUE),
    (v_company_id, v_v2, 60.00,  'MXN', now(), NULL, TRUE),
    (v_company_id, v_v3, 45.00,  'MXN', now(), NULL, TRUE),
    (v_company_id, v_v4, 120.00, 'MXN', now(), NULL, TRUE),
    (v_company_id, v_v5, 40.00,  'MXN', now(), NULL, TRUE),
    (v_company_id, v_v6, 180.00, 'MXN', now(), NULL, TRUE),
    (v_company_id, v_v7, 320.00, 'MXN', now(), NULL, TRUE),
    (v_company_id, v_v8, 35.00,  'MXN', now(), NULL, TRUE),
    (v_company_id, v_v9, 95.00,  'MXN', now(), NULL, TRUE);

  -- Low-stock alerts: V8 Jabón has 70 units total but threshold 100 → alert fires.
  UPDATE public.product_variants SET reorder_threshold = 100.00 WHERE id = v_v8;
  UPDATE public.product_variants SET reorder_threshold = 5.00   WHERE id = v_v5;

  -- =========================================================================
  -- 7. SUPPLIERS (3)
  -- =========================================================================
  INSERT INTO public.suppliers (company_id, name, slug, tax_id, contact_name, phone, email, address, is_active)
  VALUES (v_company_id, 'Distribuidora Farmacéutica S.A.', 'distribuidora-farmaceutica', 'DFAB123456789',
          'Carlos Méndez', '55-1111-2222', 'ventas@distfarm.mx', 'Pol. Centro, CDMX', TRUE)
    RETURNING id INTO v_sup1;

  INSERT INTO public.suppliers (company_id, name, slug, tax_id, contact_name, phone, email, address, is_active)
  VALUES (v_company_id, 'VitaminLab México', 'vitaminlab-mexico', 'VLAB987654321',
          'Lucía Torres', '55-3333-4444', 'pedidos@vitaminlab.mx', 'Naucalpan, Edo. Méx.', TRUE)
    RETURNING id INTO v_sup2;

  INSERT INTO public.suppliers (company_id, name, slug, tax_id, contact_name, phone, email, address, is_active)
  VALUES (v_company_id, 'CuidadoTotal', 'cuidadototal', 'CUID456789123',
          'Roberto Soto', '55-5555-6666', 'contacto@cuidadototal.mx', 'Tlalnepantla, Edo. Méx.', TRUE)
    RETURNING id INTO v_sup3;

  -- =========================================================================
  -- 8. PURCHASE ORDER + ITEMS (status: received)
  -- Ordered = Received for every line; server-style computed subtotals/totals.
  -- =========================================================================
  INSERT INTO public.purchase_orders (
    company_id, branch_id, supplier_id, order_number, status,
    order_date, expected_date, payment_method,
    subtotal, tax_total, total, notes, is_active, created_by
  ) VALUES (
    v_company_id, v_branch_centro, v_sup1, 'PO-2026-0001', 'received',
    CURRENT_DATE - 14, CURRENT_DATE - 10, 'transfer',
    8800.00, 0.00, 8800.00,
    'Reabastecimiento inicial Sucursal Centro', TRUE, v_admin_id
  )
    RETURNING id INTO v_po_id;

  INSERT INTO public.purchase_order_items (
    company_id, purchase_order_id, variant_id,
    ordered_qty, received_qty, unit_cost, tax_rate, tax_amount, subtotal, is_active, created_by
  ) VALUES
    (v_company_id, v_po_id, v_v1, 100.000, 100.000, 20.00, 0.0000, 0.00, 2000.00, TRUE, v_admin_id),
    (v_company_id, v_po_id, v_v4,  50.000,  50.000, 70.00, 0.0000, 0.00, 3500.00, TRUE, v_admin_id),
    (v_company_id, v_po_id, v_v6,  30.000,  30.000, 110.00, 0.0000, 0.00, 3300.00, TRUE, v_admin_id);

  -- =========================================================================
  -- 9. STOCK LOTS + purchase_receipt movements
  -- 2-3 lots per variant, different expiration dates and quantities across
  -- branches Centro / Norte. For each lot we also append a matching
  -- purchase_receipt stock_movement so reconcile_inventory stays drift-free.
  -- =========================================================================
  v_lots := jsonb_build_array(
    -- V1 Paracetamol blister (2 @ Centro) — lot A is the SALE lot (sale=true)
    jsonb_build_object('variant_id', v_v1, 'branch', 'centro', 'lot_code', 'LOT-PARA10-CENTRO-01',
                       'exp', '2026-08-15', 'qty', 100.000, 'cost', 20.00, 'sale', true),
    jsonb_build_object('variant_id', v_v1, 'branch', 'centro', 'lot_code', 'LOT-PARA10-CENTRO-02',
                       'exp', '2026-07-10', 'qty', 80.000, 'cost', 19.50, 'sale', false),
    -- V2 Paracetamol caja
    jsonb_build_object('variant_id', v_v2, 'branch', 'centro', 'lot_code', 'LOT-PARA20-CENTRO-01',
                       'exp', '2027-03-10', 'qty', 60.000, 'cost', 35.00, 'sale', false),
    jsonb_build_object('variant_id', v_v2, 'branch', 'centro', 'lot_code', 'LOT-PARA20-CENTRO-02',
                       'exp', '2027-06-05', 'qty', 40.000, 'cost', 34.00, 'sale', false),
    -- V3 Vitamina C blister
    jsonb_build_object('variant_id', v_v3, 'branch', 'centro', 'lot_code', 'LOT-VITC10-CENTRO-01',
                       'exp', '2026-11-30', 'qty', 90.000, 'cost', 25.00, 'sale', false),
    jsonb_build_object('variant_id', v_v3, 'branch', 'centro', 'lot_code', 'LOT-VITC10-CENTRO-02',
                       'exp', '2027-04-15', 'qty', 70.000, 'cost', 24.00, 'sale', false),
    -- V4 Vitamina C caja (Centro + Norte)
    jsonb_build_object('variant_id', v_v4, 'branch', 'centro', 'lot_code', 'LOT-VITC30-CENTRO-01',
                       'exp', '2027-02-28', 'qty', 50.000, 'cost', 70.00, 'sale', false),
    jsonb_build_object('variant_id', v_v4, 'branch', 'norte',  'lot_code', 'LOT-VITC30-NORTE-01',
                       'exp', '2027-05-20', 'qty', 30.000, 'cost', 71.00, 'sale', false),
    -- V5 Ibuprofeno blister
    jsonb_build_object('variant_id', v_v5, 'branch', 'centro', 'lot_code', 'LOT-IBU10-CENTRO-01',
                       'exp', '2026-09-12', 'qty', 120.000, 'cost', 22.00, 'sale', false),
    jsonb_build_object('variant_id', v_v5, 'branch', 'centro', 'lot_code', 'LOT-IBU10-CENTRO-02',
                       'exp', '2026-12-01', 'qty', 100.000, 'cost', 21.00, 'sale', false),
    -- V6 Pañales x30 (Centro + Norte, no expiration)
    jsonb_build_object('variant_id', v_v6, 'branch', 'centro', 'lot_code', 'LOT-PAN30-CENTRO-01',
                       'exp', to_jsonb(NULL::DATE), 'qty', 30.000, 'cost', 110.00, 'sale', false),
    jsonb_build_object('variant_id', v_v6, 'branch', 'norte',  'lot_code', 'LOT-PAN30-NORTE-01',
                       'exp', to_jsonb(NULL::DATE), 'qty', 20.000, 'cost', 110.00, 'sale', false),
    -- V7 Pañales x60
    jsonb_build_object('variant_id', v_v7, 'branch', 'centro', 'lot_code', 'LOT-PAN60-CENTRO-01',
                       'exp', to_jsonb(NULL::DATE), 'qty', 25.000, 'cost', 200.00, 'sale', false),
    jsonb_build_object('variant_id', v_v7, 'branch', 'centro', 'lot_code', 'LOT-PAN60-CENTRO-02',
                       'exp', to_jsonb(NULL::DATE), 'qty', 15.000, 'cost', 198.00, 'sale', false),
    -- V8 Jabón de manos
    jsonb_build_object('variant_id', v_v8, 'branch', 'centro', 'lot_code', 'LOT-JAB200-CENTRO-01',
                       'exp', '2028-01-01', 'qty', 40.000, 'cost', 18.00, 'sale', false),
    jsonb_build_object('variant_id', v_v8, 'branch', 'centro', 'lot_code', 'LOT-JAB200-CENTRO-02',
                       'exp', '2028-06-01', 'qty', 30.000, 'cost', 17.50, 'sale', false),
    -- V9 Multivitamínico
    jsonb_build_object('variant_id', v_v9, 'branch', 'centro', 'lot_code', 'LOT-MULT30-CENTRO-01',
                       'exp', '2027-07-19', 'qty', 60.000, 'cost', 55.00, 'sale', false),
    jsonb_build_object('variant_id', v_v9, 'branch', 'centro', 'lot_code', 'LOT-MULT30-CENTRO-02',
                       'exp', '2027-10-10', 'qty', 50.000, 'cost', 54.50, 'sale', false)
  );

  FOR v_lot IN SELECT * FROM jsonb_array_elements(v_lots) LOOP
    IF v_lot->>'branch' = 'centro' THEN
      v_lot_branch := v_branch_centro;
    ELSE
      v_lot_branch := v_branch_norte;
    END IF;

    v_lot_exp  := NULLIF(v_lot->>'exp', '')::DATE;  -- null string → null date
    v_lot_qty  := (v_lot->>'qty')::NUMERIC;
    v_lot_cost := (v_lot->>'cost')::NUMERIC;

    -- Determine status: 'expired' if past, else 'active'. All lots here are
    -- future-dated or NULL, so all are 'active'.
    INSERT INTO public.stock_lots (
      company_id, branch_id, variant_id, lot_code, expiration_date,
      received_qty, remaining_qty, cost_per_unit, status, is_active, created_by, updated_by
    ) VALUES (
      v_company_id, v_lot_branch, (v_lot->>'variant_id')::UUID,
      v_lot->>'lot_code', v_lot_exp,
      v_lot_qty, v_lot_qty, v_lot_cost,
      CASE
        WHEN v_lot_exp IS NOT NULL AND v_lot_exp < CURRENT_DATE THEN 'expired'
        ELSE 'active'
      END,
      TRUE, v_admin_id, v_admin_id
    )
      RETURNING id INTO v_lot_id;

    -- Append the purchase_receipt movement (positive delta).
    INSERT INTO public.stock_movements (
      company_id, branch_id, variant_id, lot_id, movement_type,
      delta_qty, reference_type, reference_id, created_by, updated_by
    ) VALUES (
      v_company_id, v_lot_branch, (v_lot->>'variant_id')::UUID, v_lot_id,
      'purchase_receipt', v_lot_qty, 'purchase_order', v_po_id,
      v_admin_id, v_admin_id
    )
      RETURNING id INTO v_mv_id;

    -- Remember the lot used by the cashier sale for FEFO batch traceability.
    IF (v_lot->>'sale')::BOOLEAN THEN
      v_sale_lot_id := v_lot_id;
    END IF;
  END LOOP;

  -- =========================================================================
  -- 10. CUSTOMERS (2) + a preorder + a customer request (demand domain)
  -- =========================================================================
  INSERT INTO public.customers (company_id, name, slug, tax_id, phone, email, address, is_active, credit_limit)
  VALUES (v_company_id, 'Juan Pérez', 'juan-perez', 'PEJC800101HDF', '55-1234-0001', 'juan.perez@example.com',
          'Calle Olivos 12, CDMX', TRUE, 5000.00)
    RETURNING id INTO v_customer1;

  INSERT INTO public.customers (company_id, name, slug, tax_id, phone, email, address, is_active)
  VALUES (v_company_id, 'María García', 'maria-garcia', 'GARM900215MDF', '55-1234-0002', 'maria.garcia@example.com',
          'Av. Pinos 88, CDMX', TRUE)
    RETURNING id INTO v_customer2;

  -- One confirmed preorder for Juan Pérez at Sucursal Centro (demand signal).
  INSERT INTO public.preorders (company_id, branch_id, customer_id, preorder_number, status, notes, is_active, created_by)
  VALUES (v_company_id, v_branch_centro, v_customer1, 'PRE-2026-0001', 'confirmed',
          'Pedido para recoger en Sucursal Centro', TRUE, v_admin_id)
    RETURNING id INTO v_preorder_id;

  INSERT INTO public.preorder_items (company_id, preorder_id, variant_id, qty, unit_price, is_active, created_by)
  VALUES (v_company_id, v_preorder_id, v_v2, 3.000, 60.00, TRUE, v_admin_id);

  -- One pending customer request (catalogued variant) from María García.
  INSERT INTO public.customer_requests (company_id, customer_id, variant_id, requested_qty, status, notes, is_active, created_by)
  VALUES (v_company_id, v_customer2, v_v4, 2.000, 'pending', 'Surtir cuando llegue stock', TRUE, v_admin_id);

  -- =========================================================================
  -- 11. CASH SESSION (open) + opening_float movement
  -- =========================================================================
  INSERT INTO public.cash_sessions (
    company_id, branch_id, cashier_user_id, status,
    opened_at, opening_amount, expected_cash_amount, notes, is_active, created_by, updated_by
  ) VALUES (
    v_company_id, v_branch_centro, v_cashier_id, 'open',
    now(), 500.00, 500.00, 'Apertura de caja seed', TRUE, v_cashier_id, v_cashier_id
  )
    RETURNING id INTO v_cash_session_id;

  INSERT INTO public.cash_movements (
    company_id, branch_id, cash_session_id, movement_type, amount,
    reference_type, reason, notes, is_active, created_by, updated_by
  ) VALUES (
    v_company_id, v_branch_centro, v_cash_session_id, 'opening_float', 500.00,
    NULL, 'session_open', 'Apertura de caja seed', TRUE, v_cashier_id, v_cashier_id
  )
    RETURNING id INTO v_mv_id;

  -- =========================================================================
  -- 12. SALE — completed (status: active) for the cashier
  -- Manual FEFO deduction: 2 units of Paracetamol blister (V1) taken from
  -- the nearest-expiration active lot. The decrement UPDATE is permitted
  -- because seed runs as `postgres` (the quantity-edit guard allows it).
  -- =========================================================================

  -- Deduct 2 units from the sale lot and append a negative 'sale' movement
  -- so reconcile_inventory stays drift-free.
  UPDATE public.stock_lots
    SET remaining_qty = remaining_qty - 2.000,
        status = CASE WHEN remaining_qty - 2.000 = 0 THEN 'depleted' ELSE status END,
        updated_by = v_cashier_id
    WHERE id = v_sale_lot_id AND company_id = v_company_id;

  INSERT INTO public.stock_movements (
    company_id, branch_id, variant_id, lot_id, movement_type,
    delta_qty, reference_type, reference_id, created_by, updated_by
  ) VALUES (
    v_company_id, v_branch_centro, v_v1, v_sale_lot_id, 'sale',
    -2.000, 'sale', NULL, v_cashier_id, v_cashier_id
  )
    RETURNING id INTO v_mv_id;

  -- Sale header: sale_number starts at 1 for Sucursal Centro.
  INSERT INTO public.sales (
    company_id, branch_id, cashier_user_id, customer_id, cash_session_id,
    status, subtotal, discount_amount, tax_amount, total,
    sale_number, notes, is_active, created_by, updated_by
  ) VALUES (
    v_company_id, v_branch_centro, v_cashier_id, NULL, v_cash_session_id,
    'active', 70.00, 0.00, 0.00, 70.00,
    1, 'Venta seed — Paracetamol blister x2', TRUE, v_cashier_id, v_cashier_id
  )
    RETURNING id INTO v_sale_id;

  -- Sale line item
  INSERT INTO public.sale_items (
    company_id, sale_id, variant_id, quantity, unit_price,
    discount_percent, discount_amount, tax_percent, tax_amount, line_total,
    is_manual_price, is_active, created_by, updated_by
  ) VALUES (
    v_company_id, v_sale_id, v_v1, 2.000, 35.00,
    0.00, 0.00, 0.00, 0.00, 70.00,
    FALSE, TRUE, v_cashier_id, v_cashier_id
  )
    RETURNING id INTO v_sale_item_id;

  -- Lot traceability for the sold units
  INSERT INTO public.sale_item_batches (
    company_id, sale_item_id, lot_id, quantity, cost_price, is_active, created_by, updated_by
  ) VALUES (
    v_company_id, v_sale_item_id, v_sale_lot_id, 2.000, 20.00, TRUE, v_cashier_id, v_cashier_id
  );

  -- Cash payment (does NOT trigger seed_customer_balance — only 'credit' does)
  INSERT INTO public.payments (
    company_id, sale_id, payment_method, amount, reference, is_active, created_by, updated_by
  ) VALUES (
    v_company_id, v_sale_id, 'cash', 70.00, NULL, TRUE, v_cashier_id, v_cashier_id
  );
END $$;

-- Refresh PostgREST schema cache so storefront queries see seeded data
-- exposed through the auto-generated API.
NOTIFY pgrst, 'reload schema';
