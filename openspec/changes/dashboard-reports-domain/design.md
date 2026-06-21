# Design: Dashboard, Reports & Export Domain

## D1 — View Architecture

All views use `security_invoker = true` for RLS enforcement. Each view includes company_id for RLS policy filtering. Comments document purpose and source spec requirement.

### v_dashboard_sales_today

```sql
CREATE OR REPLACE VIEW v_dashboard_sales_today
WITH (security_invoker = true)
AS
WITH
sales_agg AS (
  SELECT
    company_id,
    branch_id,
    SUM(total)::NUMERIC(14,2) AS total_sales,
    COUNT(*)::BIGINT AS sales_count
  FROM sales
  WHERE created_at >= CURRENT_DATE
    AND status <> 'cancelled'
  GROUP BY company_id, branch_id
),
payment_agg AS (
  SELECT
    s.company_id,
    s.branch_id,
    jsonb_object_agg(p.payment_method, p.method_total) AS by_payment_method
  FROM sales s
  JOIN (
    SELECT company_id, sale_id, payment_method, SUM(amount)::NUMERIC(14,2) AS method_total
    FROM payments
    GROUP BY company_id, sale_id, payment_method
  ) p ON p.company_id = s.company_id AND p.sale_id = s.id
  WHERE s.created_at >= CURRENT_DATE
    AND s.status <> 'cancelled'
  GROUP BY s.company_id, s.branch_id
)
SELECT
  sa.company_id,
  sa.branch_id,
  sa.total_sales,
  sa.sales_count,
  COALESCE(pa.by_payment_method, '{}'::jsonb) AS by_payment_method,
  CURRENT_DATE AS as_of_date
FROM sales_agg sa
LEFT JOIN payment_agg pa ON pa.company_id = sa.company_id AND pa.branch_id = sa.branch_id;

COMMENT ON VIEW v_dashboard_sales_today IS 'RR1: Today sales total, count, and payment method breakdown grouped by branch';
```

### v_dashboard_sales_week

```sql
CREATE OR REPLACE VIEW v_dashboard_sales_week
WITH (security_invoker = true)
AS
SELECT
  company_id,
  branch_id,
  date_trunc('day', created_at)::DATE AS day_date,
  COALESCE(SUM(total), 0)::NUMERIC(14,2) AS daily_total,
  COUNT(*)::BIGINT AS daily_count,
  CURRENT_DATE AS as_of_date
FROM sales
WHERE created_at >= CURRENT_DATE - INTERVAL '6 days'
  AND status <> 'cancelled'
GROUP BY company_id, branch_id, date_trunc('day', created_at);

COMMENT ON VIEW v_dashboard_sales_week IS 'RR2: Daily sales breakdown for rolling 7-day window';
```

### v_dashboard_sales_month

```sql
CREATE OR REPLACE VIEW v_dashboard_sales_month
WITH (security_invoker = true)
AS
SELECT
  company_id,
  branch_id,
  date_trunc('day', created_at)::DATE AS day_date,
  COALESCE(SUM(total), 0)::NUMERIC(14,2) AS daily_total,
  COUNT(*)::BIGINT AS daily_count,
  CURRENT_DATE AS as_of_date
FROM sales
WHERE created_at >= date_trunc('month', CURRENT_DATE)
  AND status <> 'cancelled'
GROUP BY company_id, branch_id, date_trunc('day', created_at);

COMMENT ON VIEW v_dashboard_sales_month IS 'RR3: Daily sales breakdown for current calendar month';
```

### v_dashboard_low_stock

```sql
CREATE OR REPLACE VIEW v_dashboard_low_stock
WITH (security_invoker = true)
AS
SELECT
  pv.company_id,
  pv.branch_id,
  pv.variant_id,
  pv.name AS variant_name,
  pv.sku,
  COALESCE(vsa.physical_qty, 0)::NUMERIC(12,2) AS available_qty,
  pv.reorder_threshold,
  CASE
    WHEN pv.reorder_threshold IS NOT NULL
    THEN (pv.reorder_threshold - COALESCE(vsa.physical_qty, 0))::NUMERIC(12,2)
    ELSE NULL
  END AS below_threshold_by
FROM product_variants pv
LEFT JOIN v_stock_available vsa
  ON vsa.company_id = pv.company_id
 AND vsa.branch_id = pv.branch_id
 AND vsa.variant_id = pv.variant_id
WHERE (
  (pv.reorder_threshold IS NOT NULL AND COALESCE(vsa.physical_qty, 0) <= pv.reorder_threshold)
  OR
  (COALESCE(vsa.physical_qty, 0) = 0)
);

COMMENT ON VIEW v_dashboard_low_stock IS 'RR4: Low-stock alerts — variants below reorder threshold or zero stock';
```

### v_dashboard_near_expiration

```sql
CREATE OR REPLACE VIEW v_dashboard_near_expiration
WITH (security_invoker = true)
AS
SELECT
  sl.company_id,
  sl.branch_id,
  sl.id AS lot_id,
  sl.variant_id,
  sl.lot_code,
  sl.expiration_date,
  sl.remaining_qty,
  (sl.expiration_date - CURRENT_DATE)::INTEGER AS days_until_expiry
FROM stock_lots sl
WHERE sl.expiration_date IS NOT NULL
  AND sl.expiration_date <= CURRENT_DATE + INTERVAL '30 days'
  AND sl.remaining_qty > 0
  AND sl.status = 'active';

COMMENT ON VIEW v_dashboard_near_expiration IS 'RR5: Lots expiring within 30 days with remaining stock';
```

### v_dashboard_outstanding_balances

```sql
CREATE OR REPLACE VIEW v_dashboard_outstanding_balances
WITH (security_invoker = true)
AS
SELECT
  cb.company_id,
  cb.customer_id,
  c.name AS customer_name,
  SUM(cb.total_amount)::NUMERIC(14,2) AS total_owed,
  SUM(cb.paid_amount)::NUMERIC(14,2) AS paid_amount,
  SUM(cb.remaining_amount)::NUMERIC(14,2) AS remaining_amount,
  MIN(cb.created_at)::TIMESTAMPTZ AS oldest_balance_date
FROM customer_balances cb
JOIN customers c ON c.company_id = cb.company_id AND c.id = cb.customer_id
WHERE cb.status IN ('pending', 'partial')
GROUP BY cb.company_id, cb.customer_id, c.name
HAVING SUM(cb.remaining_amount) > 0;

COMMENT ON VIEW v_dashboard_outstanding_balances IS 'RR6: Customers with outstanding credit balances (nonzero remaining)';
```

### v_dashboard_sales_by_branch

```sql
CREATE OR REPLACE VIEW v_dashboard_sales_by_branch
WITH (security_invoker = true)
AS
SELECT
  b.company_id,
  b.id AS branch_id,
  COALESCE(today.total, 0)::NUMERIC(14,2) AS today_total,
  COALESCE(week.total, 0)::NUMERIC(14,2) AS week_total,
  COALESCE(month.total, 0)::NUMERIC(14,2) AS month_total
FROM branches b
LEFT JOIN LATERAL (
  SELECT SUM(total)::NUMERIC(14,2) AS total
  FROM sales
  WHERE company_id = b.company_id AND branch_id = b.id
    AND created_at >= CURRENT_DATE AND status <> 'cancelled'
) today ON true
LEFT JOIN LATERAL (
  SELECT SUM(total)::NUMERIC(14,2) AS total
  FROM sales
  WHERE company_id = b.company_id AND branch_id = b.id
    AND created_at >= date_trunc('week', CURRENT_DATE) AND status <> 'cancelled'
) week ON true
LEFT JOIN LATERAL (
  SELECT SUM(total)::NUMERIC(14,2) AS total
  FROM sales
  WHERE company_id = b.company_id AND branch_id = b.id
    AND created_at >= date_trunc('month', CURRENT_DATE) AND status <> 'cancelled'
) month ON true;

COMMENT ON VIEW v_dashboard_sales_by_branch IS 'RR7: Each branch with today/week/month totals (COALESCE 0 for no-sale windows)';
```

### v_report_sales_by_day

```sql
CREATE OR REPLACE VIEW v_report_sales_by_day
WITH (security_invoker = true)
AS
SELECT
  company_id,
  branch_id,
  date_trunc('day', created_at)::DATE AS sale_date,
  COALESCE(SUM(total), 0)::NUMERIC(14,2) AS total_sales,
  COUNT(*)::BIGINT AS sales_count,
  CASE WHEN COUNT(*) > 0
    THEN (SUM(total) / COUNT(*))::NUMERIC(14,2)
    ELSE 0
  END AS avg_ticket
FROM sales
WHERE status <> 'cancelled'
GROUP BY company_id, branch_id, date_trunc('day', created_at);

COMMENT ON VIEW v_report_sales_by_day IS 'RR8: Daily sales aggregations with avg ticket';
```

### v_report_sales_by_week

```sql
CREATE OR REPLACE VIEW v_report_sales_by_week
WITH (security_invoker = true)
AS
SELECT
  company_id,
  branch_id,
  date_trunc('week', created_at)::DATE AS week_start,
  COALESCE(SUM(total), 0)::NUMERIC(14,2) AS total_sales,
  COUNT(*)::BIGINT AS sales_count,
  CASE WHEN COUNT(*) > 0
    THEN (SUM(total) / COUNT(*))::NUMERIC(14,2)
    ELSE 0
  END AS avg_ticket
FROM sales
WHERE status <> 'cancelled'
GROUP BY company_id, branch_id, date_trunc('week', created_at);

COMMENT ON VIEW v_report_sales_by_week IS 'RR9: Weekly sales aggregations (ISO week, Monday start)';
```

### v_report_sales_by_month

```sql
CREATE OR REPLACE VIEW v_report_sales_by_month
WITH (security_invoker = true)
AS
SELECT
  company_id,
  branch_id,
  date_trunc('month', created_at)::DATE AS month_start,
  COALESCE(SUM(total), 0)::NUMERIC(14,2) AS total_sales,
  COUNT(*)::BIGINT AS sales_count,
  CASE WHEN COUNT(*) > 0
    THEN (SUM(total) / COUNT(*))::NUMERIC(14,2)
    ELSE 0
  END AS avg_ticket
FROM sales
WHERE status <> 'cancelled'
GROUP BY company_id, branch_id, date_trunc('month', created_at);

COMMENT ON VIEW v_report_sales_by_month IS 'RR10: Monthly sales aggregations';
```

### v_report_current_inventory

```sql
CREATE OR REPLACE VIEW v_report_current_inventory
WITH (security_invoker = true)
AS
SELECT
  sl.company_id,
  sl.branch_id,
  sl.variant_id,
  pv.name AS variant_name,
  pv.sku,
  sl.lot_code,
  sl.status AS lot_status,
  sl.remaining_qty,
  sl.cost_per_unit,
  (sl.remaining_qty * COALESCE(sl.cost_per_unit, 0))::NUMERIC(14,2) AS estimated_value
FROM stock_lots sl
JOIN product_variants pv ON pv.company_id = sl.company_id AND pv.id = sl.variant_id
WHERE sl.remaining_qty > 0;

COMMENT ON VIEW v_report_current_inventory IS 'RR11: All active lots with non-zero stock and estimated value';
```

### v_report_low_stock

```sql
CREATE OR REPLACE VIEW v_report_low_stock
WITH (security_invoker = true)
AS
SELECT
  pv.company_id,
  pv.branch_id,
  pv.variant_id,
  pv.name AS variant_name,
  pv.sku,
  COALESCE(vsa.physical_qty, 0)::NUMERIC(12,2) AS available_qty,
  pv.reorder_threshold,
  CASE
    WHEN pv.reorder_threshold IS NOT NULL
    THEN (pv.reorder_threshold - COALESCE(vsa.physical_qty, 0))::NUMERIC(12,2)
    ELSE NULL
  END AS below_threshold_by
FROM product_variants pv
LEFT JOIN v_stock_available vsa
  ON vsa.company_id = pv.company_id
 AND vsa.branch_id = pv.branch_id
 AND vsa.variant_id = pv.variant_id
WHERE pv.reorder_threshold IS NOT NULL;

COMMENT ON VIEW v_report_low_stock IS 'RR12: All variants with reorder_threshold set (full reorder report, including above-threshold)';
```

### v_report_expiration

```sql
CREATE OR REPLACE VIEW v_report_expiration
WITH (security_invoker = true)
AS
SELECT
  sl.company_id,
  sl.branch_id,
  sl.id AS lot_id,
  sl.variant_id,
  sl.lot_code,
  sl.expiration_date,
  sl.remaining_qty,
  (sl.expiration_date - CURRENT_DATE)::INTEGER AS days_until_expiry,
  CASE
    WHEN sl.expiration_date IS NULL THEN 'no_date'
    WHEN sl.expiration_date < CURRENT_DATE THEN 'expired'
    WHEN sl.expiration_date - CURRENT_DATE <= 7 THEN 'critical'
    WHEN sl.expiration_date - CURRENT_DATE <= 30 THEN 'warning'
    ELSE 'ok'
  END AS status
FROM stock_lots sl
WHERE sl.remaining_qty > 0;

COMMENT ON VIEW v_report_expiration IS 'RR13: Full expiration report — all active lots with status classification';
```

### v_report_customer_balances

```sql
CREATE OR REPLACE VIEW v_report_customer_balances
WITH (security_invoker = true)
AS
SELECT
  cb.company_id,
  cb.customer_id,
  c.name AS customer_name,
  SUM(cb.total_amount)::NUMERIC(14,2) AS total_owed,
  SUM(cb.paid_amount)::NUMERIC(14,2) AS paid_amount,
  SUM(cb.remaining_amount)::NUMERIC(14,2) AS remaining,
  COUNT(*)::BIGINT AS balance_count,
  MIN(cb.created_at)::TIMESTAMPTZ AS oldest_balance
FROM customer_balances cb
JOIN customers c ON c.company_id = cb.company_id AND c.id = cb.customer_id
GROUP BY cb.company_id, cb.customer_id, c.name;

COMMENT ON VIEW v_report_customer_balances IS 'RR14: All credit customers with balance summary (including fully paid)';
```

### v_report_payments_received

```sql
CREATE OR REPLACE VIEW v_report_payments_received
WITH (security_invoker = true)
AS
SELECT
  cp.company_id,
  date_trunc('day', cp.created_at)::DATE AS date,
  cp.payment_method,
  SUM(cp.amount)::NUMERIC(14,2) AS total_amount,
  COUNT(*)::BIGINT AS payment_count
FROM customer_payments cp
GROUP BY cp.company_id, date_trunc('day', cp.created_at), cp.payment_method;

COMMENT ON VIEW v_report_payments_received IS 'RR15: Customer payments aggregated by date and payment method';
```

---

## D2 — RPC Signatures

All RPCs follow the established pattern: SECURITY DEFINER, `SET search_path = public`, REVOKE from PUBLIC+anon, GRANT to authenticated.

### fn_report_sales_by_cashier

```sql
CREATE OR REPLACE FUNCTION public.fn_report_sales_by_cashier(
  p_company_id UUID,
  p_date_from DATE,
  p_date_to DATE
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller_company_id UUID;
  v_result JSONB;
BEGIN
  v_caller_company_id := get_company_id();
  IF v_caller_company_id IS DISTINCT FROM p_company_id THEN
    RETURN jsonb_build_object('success', false, 'code', 'CROSS_TENANT', 'message', 'company_id mismatch');
  END IF;

  SELECT jsonb_agg(row_to_json(r.*))
  INTO v_result
  FROM (
    SELECT
      s.cashier_user_id,
      p.full_name AS cashier_name,
      COALESCE(SUM(s.total), 0)::NUMERIC(14,2) AS total_sales,
      COUNT(*)::BIGINT AS sale_count,
      CASE WHEN COUNT(*) > 0
        THEN (SUM(s.total) / COUNT(*))::NUMERIC(14,2)
        ELSE 0
      END AS avg_ticket
    FROM sales s
    JOIN company_users cu ON cu.company_id = s.company_id AND cu.user_id = s.cashier_user_id
    JOIN profiles p ON p.id = cu.user_id
    WHERE s.company_id = p_company_id
      AND s.created_at >= p_date_from::TIMESTAMPTZ
      AND s.created_at < (p_date_to + 1)::TIMESTAMPTZ
      AND s.status <> 'cancelled'
    GROUP BY s.cashier_user_id, cu.user_id
    ORDER BY total_sales DESC
  ) r;

  RETURN jsonb_build_object(
    'success', true,
    'data', COALESCE(v_result, '[]'::jsonb)
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.fn_report_sales_by_cashier(UUID, DATE, DATE) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_report_sales_by_cashier(UUID, DATE, DATE) TO authenticated, service_role;

COMMENT ON FUNCTION public.fn_report_sales_by_cashier IS 'RR16: Sales grouped by cashier within date range';
```

### fn_report_cash_cut

```sql
CREATE OR REPLACE FUNCTION public.fn_report_cash_cut(
  p_company_id UUID,
  p_cash_session_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller_company_id UUID;
  v_session JSONB;
  v_payments JSONB;
  v_cash_movements JSONB;
BEGIN
  v_caller_company_id := get_company_id();
  IF v_caller_company_id IS DISTINCT FROM p_company_id THEN
    RETURN jsonb_build_object('success', false, 'code', 'CROSS_TENANT', 'message', 'company_id mismatch');
  END IF;

  -- Session details
  SELECT jsonb_build_object(
    'cash_session_id', cs.id,
    'branch_id', cs.branch_id,
    'cashier_user_id', cs.cashier_user_id,
    'opened_at', cs.opened_at,
    'closed_at', cs.closed_at,
    'opening_amount', cs.opening_amount,
    'expected_cash_amount', cs.expected_cash_amount,
    'counted_cash_amount', cs.counted_cash_amount,
    'difference_amount', cs.difference_amount
  )
  INTO v_session
  FROM cash_sessions cs
  WHERE cs.company_id = p_company_id AND cs.id = p_cash_session_id;

  IF v_session IS NULL THEN
    RETURN jsonb_build_object('success', false, 'code', 'NOT_FOUND', 'message', 'cash session not found');
  END IF;

  -- Payment totals for sales in this session
  SELECT jsonb_agg(row_to_json(p.*))
  INTO v_payments
  FROM (
    SELECT p.payment_method, SUM(p.amount)::NUMERIC(14,2) AS total, COUNT(*)::BIGINT AS count
    FROM payments p
    JOIN sales s ON s.company_id = p.company_id AND s.id = p.sale_id
    WHERE p.company_id = p_company_id
      AND s.cash_session_id = p_cash_session_id
      AND s.status <> 'cancelled'
    GROUP BY p.payment_method
  ) p;

  -- Cash movements in this session
  SELECT jsonb_agg(row_to_json(cm.*))
  INTO v_cash_movements
  FROM (
    SELECT cm.movement_type, SUM(cm.amount)::NUMERIC(14,2) AS total, COUNT(*)::BIGINT AS count
    FROM cash_movements cm
    WHERE cm.company_id = p_company_id AND cm.cash_session_id = p_cash_session_id
    GROUP BY cm.movement_type
  ) cm;

  RETURN jsonb_build_object(
    'success', true,
    'data', jsonb_build_object(
      'session', v_session,
      'payments', COALESCE(v_payments, '[]'::jsonb),
      'cash_movements', COALESCE(v_cash_movements, '[]'::jsonb)
    )
  );
END;
$$;
REVOKE EXECUTE ON FUNCTION public.fn_report_cash_cut(UUID, UUID) FROM PUBLIC, anon;

  GRANT EXECUTE ON FUNCTION public.fn_report_cash_cut(UUID, UUID) TO authenticated, service_role;

COMMENT ON FUNCTION public.fn_report_cash_cut IS 'RR17: Cash cut report matching close_cash_session calculation logic';
```

### fn_report_purchases_by_supplier

```sql
CREATE OR REPLACE FUNCTION public.fn_report_purchases_by_supplier(
  p_company_id UUID,
  p_date_from DATE,
  p_date_to DATE
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller_company_id UUID;
  v_result JSONB;
BEGIN
  v_caller_company_id := get_company_id();
  IF v_caller_company_id IS DISTINCT FROM p_company_id THEN
    RETURN jsonb_build_object('success', false, 'code', 'CROSS_TENANT', 'message', 'company_id mismatch');
  END IF;

  SELECT jsonb_agg(row_to_json(r.*))
  INTO v_result
  FROM (
    SELECT
      po.supplier_id,
      s.name AS supplier_name,
      SUM(po.total)::NUMERIC(14,2) AS total_purchases,
      COUNT(*)::BIGINT AS order_count
    FROM purchase_orders po
    JOIN suppliers s ON s.company_id = po.company_id AND s.id = po.supplier_id
    WHERE po.company_id = p_company_id
      AND po.status <> 'cancelled'
      AND po.order_date >= p_date_from
      AND po.order_date <= p_date_to
    GROUP BY po.supplier_id, s.name
    ORDER BY total_purchases DESC
  ) r;

  RETURN jsonb_build_object(
    'success', true,
    'data', COALESCE(v_result, '[]'::jsonb)
  );
END;
$$;
REVOKE EXECUTE ON FUNCTION public.fn_report_purchases_by_supplier(UUID, DATE, DATE) FROM PUBLIC, anon;

  GRANT EXECUTE ON FUNCTION public.fn_report_purchases_by_supplier(UUID, DATE, DATE) TO authenticated, service_role;

COMMENT ON FUNCTION public.fn_report_purchases_by_supplier IS 'RR18: Purchase orders grouped by supplier within date range';
```

### fn_purchase_suggestions

```sql
CREATE OR REPLACE FUNCTION public.fn_purchase_suggestions(
  p_company_id UUID,
  p_branch_id UUID DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller_company_id UUID;
  v_lookback_days CONSTANT INTEGER := 30;
  v_lead_time_days CONSTANT INTEGER := 7;
  v_result JSONB;
BEGIN
  v_caller_company_id := get_company_id();
  IF v_caller_company_id IS DISTINCT FROM p_company_id THEN
    RETURN jsonb_build_object('success', false, 'code', 'CROSS_TENANT', 'message', 'company_id mismatch');
  END IF;

  WITH
  -- CTE 1: Sales velocity over lookback period
  sales_velocity AS (
    SELECT
      si.company_id,
      si.branch_id,
      si.variant_id,
      COUNT(*)::NUMERIC / v_lookback_days AS avg_daily_sales
    FROM sale_items si
    JOIN sales s ON s.company_id = si.company_id AND s.id = si.sale_id
    WHERE si.company_id = p_company_id
      AND (p_branch_id IS NULL OR si.branch_id = p_branch_id)
      AND s.created_at >= CURRENT_DATE - v_lookback_days
      AND s.status <> 'cancelled'
    GROUP BY si.company_id, si.branch_id, si.variant_id
  ),
  -- CTE 2: Current stock per variant per branch
  current_stock AS (
    SELECT
      vsa.company_id,
      vsa.branch_id,
      vsa.variant_id,
      vsa.physical_qty
    FROM v_stock_available vsa
    WHERE vsa.company_id = p_company_id
      AND (p_branch_id IS NULL OR vsa.branch_id = p_branch_id)
  ),
  -- CTE 3: Pending customer requests
  pending_requests AS (
    SELECT
      cr.company_id,
      cr.variant_id,
      COALESCE(SUM(cr.requested_qty - COALESCE(cr.fulfilled_qty, 0)), 0) AS pending_qty
    FROM customer_requests cr
    WHERE cr.company_id = p_company_id
      AND cr.status = 'pending'
    GROUP BY cr.company_id, cr.variant_id
  ),
  -- CTE 4: Reorder thresholds
  variant_thresholds AS (
    SELECT
      pv.company_id,
      pv.branch_id,
      pv.id AS variant_id,
      pv.name AS variant_name,
      pv.reorder_threshold
    FROM product_variants pv
    WHERE pv.company_id = p_company_id
      AND (p_branch_id IS NULL OR pv.branch_id = p_branch_id)
      AND pv.is_active = true
  )
  -- CTE 5: Final suggestions
  SELECT jsonb_agg(
    jsonb_build_object(
      'variant_id', vt.variant_id,
      'variant_name', vt.variant_name,
      'current_stock', COALESCE(cs.physical_qty, 0)::NUMERIC(12,2),
      'avg_daily_sales', COALESCE(sv.avg_daily_sales, 0)::NUMERIC(12,4),
      'pending_requests', COALESCE(pr.pending_qty, 0)::INTEGER,
      'days_until_stockout',
        CASE
          WHEN COALESCE(sv.avg_daily_sales, 0) > 0
          THEN GREATEST(0, FLOOR(COALESCE(cs.physical_qty, 0) / sv.avg_daily_sales))::INTEGER
          ELSE NULL
        END,
      'suggested_qty',
        GREATEST(0,
          CEIL(
            GREATEST(
              COALESCE(pr.pending_qty, 0),
              COALESCE(sv.avg_daily_sales, 0) * v_lead_time_days
            ) - COALESCE(cs.physical_qty, 0)
          )
        )::NUMERIC(12,2),
      'priority_score',
        (COALESCE(pr.pending_qty, 0) * 4
         + COALESCE(sv.avg_daily_sales, 0) * 3
         + CASE WHEN COALESCE(cs.physical_qty, 0) < COALESCE(vt.reorder_threshold, 0) THEN 2 ELSE 0 END
         + CASE WHEN COALESCE(cs.physical_qty, 0) = 0 AND COALESCE(sv.avg_daily_sales, 0) > 0 THEN 1 ELSE 0 END
        )::NUMERIC(12,2)
    )
    ORDER BY priority_score DESC NULLS LAST
  ) INTO v_result
  FROM variant_thresholds vt
  LEFT JOIN current_stock cs ON cs.company_id = vt.company_id AND cs.branch_id = vt.branch_id AND cs.variant_id = vt.variant_id
  LEFT JOIN sales_velocity sv ON sv.company_id = vt.company_id AND sv.branch_id = vt.branch_id AND sv.variant_id = vt.variant_id
  LEFT JOIN pending_requests pr ON pr.company_id = vt.company_id AND pr.variant_id = vt.variant_id;

  RETURN jsonb_build_object(
    'success', true,
    'data', COALESCE(v_result, '[]'::jsonb)
  );
END;
$$;
REVOKE EXECUTE ON FUNCTION public.fn_purchase_suggestions(UUID, UUID) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.fn_purchase_suggestions(UUID, UUID) TO authenticated, service_role;

COMMENT ON FUNCTION public.fn_purchase_suggestions IS 'RR19: Purchase suggestions by sales velocity, pending requests, stock level, and reorder threshold';
```

### fn_export_entities

```sql
CREATE OR REPLACE FUNCTION public.fn_export_entities(
  p_company_id UUID,
  p_entity TEXT,
  p_format TEXT DEFAULT 'json',
  p_filters JSONB DEFAULT '{}'::JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller_company_id UUID;
  v_data JSONB;
  v_csv TEXT;
  v_date_from DATE;
  v_date_to DATE;
  v_branch_id UUID;
  v_status TEXT;
  v_supplier_id UUID;
BEGIN
  v_caller_company_id := get_company_id();
  IF v_caller_company_id IS DISTINCT FROM p_company_id THEN
    RETURN jsonb_build_object('success', false, 'code', 'CROSS_TENANT', 'message', 'company_id mismatch');
  END IF;

  -- Extract optional filters
  v_date_from := (p_filters->>'date_from')::DATE;
  v_date_to := (p_filters->>'date_to')::DATE;
  v_branch_id := (p_filters->>'branch_id')::UUID;
  v_status := p_filters->>'status';
  v_supplier_id := (p_filters->>'supplier_id')::UUID;

  CASE p_entity
    WHEN 'products' THEN
      SELECT jsonb_agg(row_to_json(r.*))
      INTO v_data
      FROM (
        SELECT pv.id, pv.sku, pv.name, pv.description, pv.is_active, pv.created_at
        FROM product_variants pv
        WHERE pv.company_id = p_company_id
          AND (v_status IS NULL OR pv.is_active = (v_status = 'active'))
      ) r;

    WHEN 'inventory' THEN
      SELECT jsonb_agg(row_to_json(r.*))
      INTO v_data
      FROM (
        SELECT sl.branch_id, sl.variant_id, pv.name AS variant_name, pv.sku,
               sl.lot_code, sl.expiration_date, sl.remaining_qty, sl.cost_per_unit,
               (sl.remaining_qty * COALESCE(sl.cost_per_unit, 0))::NUMERIC(14,2) AS estimated_value
        FROM stock_lots sl
        JOIN product_variants pv ON pv.company_id = sl.company_id AND pv.id = sl.variant_id
        WHERE sl.company_id = p_company_id
          AND (v_branch_id IS NULL OR sl.branch_id = v_branch_id)
          AND (v_status IS NULL OR sl.status = v_status)
      ) r;

    WHEN 'sales' THEN
      SELECT jsonb_agg(row_to_json(r.*))
      INTO v_data
      FROM (
        SELECT s.id, s.sale_number, s.branch_id, s.cashier_user_id, s.customer_id,
               s.subtotal, s.discount_amount, s.tax_amount, s.total, s.status, s.created_at
        FROM sales s
        WHERE s.company_id = p_company_id
          AND (v_date_from IS NULL OR s.created_at >= v_date_from::TIMESTAMPTZ)
          AND (v_date_to IS NULL OR s.created_at < (v_date_to + 1)::TIMESTAMPTZ)
          AND (v_branch_id IS NULL OR s.branch_id = v_branch_id)
          AND (v_status IS NULL OR s.status = v_status)
        ORDER BY s.created_at DESC
      ) r;

    WHEN 'customers' THEN
      SELECT jsonb_agg(row_to_json(r.*))
      INTO v_data
      FROM (
        SELECT c.id, c.name, c.phone, c.email, c.rfc, c.created_at
        FROM customers c
        WHERE c.company_id = p_company_id
          AND (v_status IS NULL OR c.is_active = (v_status = 'active'))
      ) r;

    WHEN 'purchases' THEN
      SELECT jsonb_agg(row_to_json(r.*))
      INTO v_data
      FROM (
        SELECT po.id, po.order_number, po.branch_id, po.supplier_id, s.name AS supplier_name,
               po.status, po.total, po.order_date, po.created_at
        FROM purchase_orders po
        JOIN suppliers s ON s.company_id = po.company_id AND s.id = po.supplier_id
        WHERE po.company_id = p_company_id
          AND (v_date_from IS NULL OR po.order_date >= v_date_from)
          AND (v_date_to IS NULL OR po.order_date <= v_date_to)
          AND (v_supplier_id IS NULL OR po.supplier_id = v_supplier_id)
          AND (v_status IS NULL OR po.status = v_status)
        ORDER BY po.created_at DESC
      ) r;

    WHEN 'credits' THEN
      SELECT jsonb_agg(row_to_json(r.*))
      INTO v_data
      FROM (
        SELECT cb.id, cb.customer_id, c.name AS customer_name, cb.sale_id,
               cb.total_amount, cb.paid_amount, cb.remaining_amount, cb.status, cb.created_at
        FROM customer_balances cb
        JOIN customers c ON c.company_id = cb.company_id AND c.id = cb.customer_id
        WHERE cb.company_id = p_company_id
          AND (v_status IS NULL OR cb.status = v_status)
        ORDER BY cb.created_at DESC
      ) r;

    ELSE
      RETURN jsonb_build_object('success', false, 'code', 'UNKNOWN_ENTITY', 'message', 'unknown entity: ' || p_entity);
  END CASE;

  IF p_format = 'csv' AND v_data IS NOT NULL THEN
    -- Build CSV from JSONB using jsonb_to_recordset / string_agg
    v_csv := fn_jsonb_to_csv(v_data);
    RETURN jsonb_build_object('success', true, 'data', v_csv, 'format', 'csv');
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'data', COALESCE(v_data, '[]'::jsonb),
    'format', 'json'
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.fn_export_entities(UUID, TEXT, TEXT, JSONB) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_export_entities(UUID, TEXT, TEXT, JSONB) TO authenticated, service_role;

COMMENT ON FUNCTION public.fn_export_entities IS 'RR20: Universal export — returns JSONB or CSV for 6 entity types with optional filters';
```

---

## D3 — Schema Change

```sql
ALTER TABLE product_variants
  ADD COLUMN IF NOT EXISTS reorder_threshold NUMERIC(12,2);

COMMENT ON COLUMN product_variants.reorder_threshold IS
  'RR21, RR23: Low-stock alert threshold. NULL = use company default (future). Non-NULL enables low-stock views.';
```

---

## D4 — Indexes

```sql
CREATE INDEX IF NOT EXISTS idx_sales_company_created_at
  ON sales (company_id, created_at);

CREATE INDEX IF NOT EXISTS idx_sales_company_branch_created_at
  ON sales (company_id, branch_id, created_at);

CREATE INDEX IF NOT EXISTS idx_sales_company_cashier_created_at
  ON sales (company_id, cashier_user_id, created_at);

CREATE INDEX IF NOT EXISTS idx_sale_items_company_variant
  ON sale_items (company_id, variant_id);

CREATE INDEX IF NOT EXISTS idx_payments_company_method_created_at
  ON payments (company_id, payment_method, created_at);

CREATE INDEX IF NOT EXISTS idx_stock_lots_company_branch_status_qty
  ON stock_lots (company_id, branch_id, status, remaining_qty);

CREATE INDEX IF NOT EXISTS idx_stock_lots_company_expiration
  ON stock_lots (company_id, expiration_date);
```

---

## D5 — Purchase Suggestion Algorithm

The `fn_purchase_suggestions` RPC uses a 5-CTE chain:

1. **sales_velocity**: 30-day lookback. Avg daily sales = `COUNT(sale_items) / 30` per variant/branch.
2. **current_stock**: Physical qty from `v_stock_available` per variant/branch.
3. **pending_requests**: Sum of unfulfilled `customer_requests` qty per variant.
4. **variant_thresholds**: Active variants with thresholds (only `is_active = true` — exclude discontinued).
5. **final suggestions**: Compute `suggested_qty = max(pending_requests, avg_daily_sales × 7) - current_stock`. Order by `priority_score` descending.

**Priority scoring:**
| Factor | Weight | Condition |
|--------|--------|-----------|
| Pending customer requests | 4 × qty | Any open requests |
| Sales velocity | 3 × avg_daily | Sales in last 30 days |
| Low stock | 2 (flat) | current_stock < reorder_threshold |
| Sold out | 1 (flat) | current_stock = 0 AND avg_daily > 0

Weights match RR19 spec literal values. Pending requests dominate (4 per request), ensuring customer-facing demand is prioritized. Sales velocity gives a small boost (3 × avg_daily ≈ 1.5 for a variant selling once every 2 days). Low stock (2) and sold-out (1) are tiebreakers. In practice, variants with pending customer requests AND zero stock will rank highest.

---

## D6 — CSV Export (Edge Function)

### Approach

The `fn_export_entities` RPC returns JSONB. When `format = 'csv'`, it delegates to a helper function `fn_jsonb_to_csv` that converts JSONB array to CSV text.

### Helper: fn_jsonb_to_csv

```sql
CREATE OR REPLACE FUNCTION public.fn_jsonb_to_csv(p_data JSONB)
RETURNS TEXT
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_keys TEXT[];
  v_row JSONB;
  v_csv TEXT := '';
  v_first BOOLEAN := true;
BEGIN
  IF p_data IS NULL OR jsonb_array_length(p_data) = 0 THEN
    RETURN '';
  END IF;

  -- Extract keys from first row
  SELECT array_agg(k ORDER BY k)
  INTO v_keys
  FROM jsonb_object_keys(p_data->0) AS k;

  -- Header row
  v_csv := array_to_string(v_keys, ',');

  -- Data rows
  FOR v_row IN SELECT * FROM jsonb_array_elements(p_data)
  LOOP
    v_csv := v_csv || E'\n' || (
      SELECT string_agg(
        CASE
          WHEN jsonb_typeof(v_row->key) = 'null' THEN ''
          WHEN jsonb_typeof(v_row->key) = 'string' THEN '"' || replace((v_row->>key)::TEXT, '"', '""') || '"'
          ELSE (v_row->>key)::TEXT
        END,
        ','
        ORDER BY ordinality
      )
      FROM unnest(v_keys) WITH ORDINALITY AS k(key, ordinality)
    );
  END LOOP;

  RETURN v_csv;
END;
$$;

COMMENT ON FUNCTION public.fn_jsonb_to_csv IS 'Internal: JSONB array to CSV text with string escaping';
```

### Edge Function (deferred to PR4)

```typescript
// supabase/functions/export-csv/index.ts
// 8-step critical-op pattern (to be implemented in PR4):
// 1. CORS preflight
// 2. Validate authentication
// 3. Admin role check
// 4. Zod parse request { entity, format, filters }
// 5. Call fn_export_entities RPC
// 6. Set Content-Disposition: attachment header
// 7. Stream CSV response
// 8. Audit placeholder
```

---

## D7 — R11 Resolution

| R11 Row | Decision | Status |
|---------|----------|--------|
| #3: Excel export — CSV-only MVP or XLSX in Edge Functions | **CSV-only V1**. CSV importable by Excel. xlsx deferred to V1.5 due to Deno Edge Function size constraints. | CHOSEN |

Resolved in `project-architecture/spec.md` R11 table and `dashboard-reports-domain/spec.md` RR24.

---

## D8 — Migration Plan

Single migration `00012_dashboard_reports_domain.sql`:

| Step | SQL | Idempotent? |
|------|-----|-------------|
| 1 | Schema change: `ALTER TABLE product_variants ADD COLUMN IF NOT EXISTS reorder_threshold` | Yes |
| 2 | Indexes: `CREATE INDEX IF NOT EXISTS` (7 indexes) | Yes |
| 3 | Views: `CREATE OR REPLACE VIEW ... WITH (security_invoker = true)` (15 views) | Yes |
| 4 | Helper function: `CREATE OR REPLACE FUNCTION fn_jsonb_to_csv` | Yes |
| 5 | RPCs: `CREATE OR REPLACE FUNCTION` (5 RPCs) | Yes |
| 6 | Privileges: `REVOKE/GRANT` for each function | Yes (idempotent) |
| 7 | Comments: `COMMENT ON` for each view and function | Yes (idempotent) |

---

## D9 — File Changes Table

| File | Action | Content |
|------|--------|---------|
| `supabase/migrations/00012_dashboard_reports_domain.sql` | Create | Migration: reorder_threshold column, indexes, 15 views, 6 functions |
| `supabase/functions/_shared/export_csv_handler.ts` | Create (PR4) | Shared handler for CSV export |
| `supabase/functions/export-csv/index.ts` | Create (PR4) | Edge Function entry point |
| `supabase/functions/_test/export_csv_test.ts` | Create (PR4) | Deno tests for CSV export |
| `openspec/specs/dashboard-reports-domain/spec.md` | Create (post-archive) | Synced canonical spec |
| `openspec/specs/project-architecture/spec.md` | Modify | Update R11 row #3 status: CHOSEN |

---

## D10 — Open Questions

| # | Question | Status | Notes |
|---|----------|--------|-------|
| 1 | Company-level default reorder threshold | Deferred | Future company-settings domain MAY define a global default; V1 uses NULL = "no threshold" |
| 2 | `fn_export_entities` CSV column ordering | Implementation detail | Alphabetical by JSONB key (per fn_jsonb_to_csv). If specific ordering needed, add a column_order parameter in V2 |
| 3 | Sales velocity window (30 vs 60 vs 90 days) | Fixed at 30 for V1 | Using 30 days for MVP; can be parameterized in V1.5 |
| 4 | Lead time for purchase suggestions | Hardcoded at 7 days | No supplier lead time data exists yet. Future purchasing-domain enhancement could make this per-supplier |
