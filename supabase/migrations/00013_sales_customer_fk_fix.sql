-- Migration: 00013_sales_customer_fk_fix
-- Purpose: align sales.customer_id with real customers instead of company_users.

DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'fk_sales_customer_company_membership'
  ) THEN
    ALTER TABLE public.sales
      DROP CONSTRAINT fk_sales_customer_company_membership;
  END IF;
END;
$$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'fk_sales_customer_same_company'
  ) THEN
    ALTER TABLE public.sales
      ADD CONSTRAINT fk_sales_customer_same_company
      FOREIGN KEY (company_id, customer_id) REFERENCES public.customers(company_id, id);
  END IF;
END;
$$;

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
  v_payment           JSONB;
  v_is_admin          BOOLEAN;
BEGIN
  v_company_id      := (p->>'company_id')::UUID;
  v_branch_id       := (p->>'branch_id')::UUID;
  v_actor_user_id   := (p->>'actor_user_id')::UUID;
  v_cashier_user_id := COALESCE((p->>'cashier_user_id')::UUID, v_actor_user_id);

  PERFORM set_config('request.jwt.claims', json_build_object(
    'sub', v_actor_user_id,
    'role', 'service_role',
    'app_metadata', json_build_object(
      'company_id', v_company_id,
      'role', 'admin'
    )
  )::text, true);

  v_customer_id := (p->>'customer_id')::UUID;
  v_items       := p->'items';
  v_payments    := p->'payments';
  v_notes       := p->>'notes';

  IF NOT public.is_active_company_user(v_company_id, v_actor_user_id) THEN
    RETURN jsonb_build_object('success', false, 'code', 'FORBIDDEN', 'message', 'Caller not active in company');
  END IF;

  v_is_admin := public.has_role(v_company_id, v_actor_user_id, 'admin');

  IF v_actor_user_id <> v_cashier_user_id AND NOT v_is_admin THEN
    RETURN jsonb_build_object('success', false, 'code', 'FORBIDDEN', 'message', 'Only admins can create sales for other cashiers');
  END IF;

  IF NOT public.has_role(v_company_id, v_cashier_user_id, 'cashier') THEN
    RETURN jsonb_build_object('success', false, 'code', 'VALIDATION_ERROR', 'message', 'Cashier must have cashier role');
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.branches
    WHERE id = v_branch_id AND company_id = v_company_id AND is_active
  ) THEN
    RETURN jsonb_build_object('success', false, 'code', 'VALIDATION_ERROR', 'message', 'Branch not found or not active in company');
  END IF;

  IF v_customer_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.customers
    WHERE id = v_customer_id AND company_id = v_company_id AND is_active = TRUE
  ) THEN
    RETURN jsonb_build_object('success', false, 'code', 'VALIDATION_ERROR', 'message', 'Customer not found or not active in company');
  END IF;

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

  IF v_customer_id IS NULL AND v_payments @> '[{"payment_method": "credit"}]'::JSONB THEN
    RETURN jsonb_build_object('success', false, 'code', 'VALIDATION_ERROR', 'message', 'Customer is required for credit payments');
  END IF;

  v_sale_number := public.next_sale_number(v_company_id, v_branch_id);

  INSERT INTO public.sales (
    company_id, branch_id, cashier_user_id, customer_id, cash_session_id,
    status, subtotal, discount_amount, tax_amount, total, sale_number, notes, created_by, updated_by
  ) VALUES (
    v_company_id, v_branch_id, v_cashier_user_id, v_customer_id, v_cash_session_id,
    'active', 0, 0, 0, 0, v_sale_number, v_notes, v_actor_user_id, v_actor_user_id
  )
  RETURNING id INTO v_sale_id;

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

    v_fefo_result := public.record_sale_deduction(jsonb_build_object(
      'company_id', v_company_id,
      'branch_id', v_branch_id,
      'variant_id', v_item->>'variant_id',
      'qty', (v_item->>'quantity')::NUMERIC,
      'reference_type', 'sale',
      'reference_id', v_sale_id
    ));

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

  UPDATE public.sales
    SET subtotal = v_subtotal,
        discount_amount = v_discount_amount,
        tax_amount = v_tax_amount,
        total = v_total,
        updated_by = v_actor_user_id
  WHERE id = v_sale_id;

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

COMMENT ON FUNCTION public.create_sale_transaction(JSONB) IS
  'Creates sales against real customers(company_id,id), validates customer activity, deducts inventory FEFO, and records payments atomically.';
