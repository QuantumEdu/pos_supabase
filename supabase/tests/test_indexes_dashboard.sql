-- pgTAP: Dashboard & Reports domain index tests
-- Verifies all 7 composite indexes for query performance
-- source: RR22

BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap;

SELECT plan(7);

-- ============================================================================
-- Index existence checks
-- ============================================================================
SELECT has_index(
  'public', 'sales', 'idx_sales_company_created_at',
  'sales: idx_sales_company_created_at exists'
);

SELECT has_index(
  'public', 'sales', 'idx_sales_company_branch_created_at',
  'sales: idx_sales_company_branch_created_at exists'
);

SELECT has_index(
  'public', 'sales', 'idx_sales_company_cashier_created_at',
  'sales: idx_sales_company_cashier_created_at exists'
);

SELECT has_index(
  'public', 'sale_items', 'idx_sale_items_company_variant',
  'sale_items: idx_sale_items_company_variant exists'
);

SELECT has_index(
  'public', 'payments', 'idx_payments_company_method_created_at',
  'payments: idx_payments_company_method_created_at exists'
);

SELECT has_index(
  'public', 'stock_lots', 'idx_stock_lots_company_branch_status_qty',
  'stock_lots: idx_stock_lots_company_branch_status_qty exists'
);

SELECT has_index(
  'public', 'stock_lots', 'idx_stock_lots_company_expiration',
  'stock_lots: idx_stock_lots_company_expiration exists'
);

SELECT * FROM finish();
ROLLBACK;
