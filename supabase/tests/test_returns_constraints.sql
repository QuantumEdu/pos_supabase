-- pgTAP: Returns domain constraint tests
-- Verifies table/column presence, CHECK constraints (type, status, destination,
-- qty>0), composite FKs (returns→sales, return_items→{returns,sale_items},
-- return_item_batches→{return_items,sale_item_batches}), unique (company_id,id)
-- indexes backing the composite FKs, append-only / logical-delete protection,
-- and the additive CHECK extensions on stock_movements + cash_movements (RR7).
-- source: RR1, RR7, design D1, D5

BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap;

-- ============================================================================
-- Seed data
-- ============================================================================
INSERT INTO public.companies (id, name, slug)
VALUES ('c1b00000-0000-0000-0000-000000000001', 'Returns Constraints Co A', 'returns-constraints-co-a');

INSERT INTO public.branches (id, company_id, name, slug)
VALUES ('b1b00000-1111-1111-1111-111111111111', 'c1b00000-0000-0000-0000-000000000001', 'RC Branch A1', 'rc-branch-a1');

INSERT INTO auth.users (id, email, raw_app_meta_data, raw_user_meta_data)
VALUES
  ('ab1b0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'rc-admin-a@test.com',
   '{"company_id": "c1b00000-0000-0000-0000-000000000001", "role": "admin"}',
   '{"full_name": "RC Admin A"}'),
  ('ab1b0000-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'rc-cashier-a@test.com',
   '{"company_id": "c1b00000-0000-0000-0000-000000000001", "role": "cashier"}',
   '{"full_name": "RC Cashier A"}')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.profiles (id, full_name)
VALUES
  ('ab1b0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'RC Admin A'),
  ('ab1b0000-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'RC Cashier A')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.company_users (user_id, company_id, role)
VALUES
  ('ab1b0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'c1b00000-0000-0000-0000-000000000001', 'admin'),
  ('ab1b0000-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'c1b00000-0000-0000-0000-000000000001', 'cashier')
ON CONFLICT (user_id, company_id) DO NOTHING;

INSERT INTO public.branch_users (user_id, branch_id, company_id)
VALUES ('ab1b0000-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'b1b00000-1111-1111-1111-111111111111', 'c1b00000-0000-0000-0000-000000000001')
ON CONFLICT (user_id, branch_id) DO NOTHING;

-- Product + variant + a stock lot (FK targets for sale_item_batches.lot_id)
INSERT INTO public.products (id, company_id, name, slug, created_by)
VALUES ('ddb00000-0000-0000-0000-000000000001', 'c1b00000-0000-0000-0000-000000000001', 'RC Product One', 'rc-product-one', 'ab1b0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa');

INSERT INTO public.product_variants (id, company_id, product_id, name, sku, created_by)
VALUES ('dcb00000-0000-0000-0000-000000000001', 'c1b00000-0000-0000-0000-000000000001', 'ddb00000-0000-0000-0000-000000000001', 'RC Variant One', 'RC-VAR-1', 'ab1b0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa');

INSERT INTO public.stock_lots (
  id, company_id, branch_id, variant_id, lot_code, received_qty, remaining_qty, created_by, updated_by
) VALUES (
  'dab00000-0000-0000-0000-000000000001', 'c1b00000-0000-0000-0000-000000000001',
  'b1b00000-1111-1111-1111-111111111111', 'dcb00000-0000-0000-0000-000000000001',
  'LOT-RC-1', 100, 100,
  'ab1b0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'ab1b0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
);

-- Open cash session (FK target for sales.cash_session_id)
INSERT INTO public.cash_sessions (
  id, company_id, branch_id, cashier_user_id, status, opening_amount, expected_cash_amount, created_by, updated_by
) VALUES (
  '0cb10000-0000-0000-0000-000000000091', 'c1b00000-0000-0000-0000-000000000001',
  'b1b00000-1111-1111-1111-111111111111', 'ab1b0000-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
  'open', 100.00, 100.00,
  'ab1b0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'ab1b0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
);

-- A sale + sale_item + sale_item_batch (composite FK targets for returns)
INSERT INTO public.sales (
  id, company_id, branch_id, cashier_user_id, cash_session_id, status,
  subtotal, total, sale_number, created_by, updated_by
) VALUES (
  '1ab10000-0000-0000-0000-000000000001', 'c1b00000-0000-0000-0000-000000000001',
  'b1b00000-1111-1111-1111-111111111111', 'ab1b0000-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
  '0cb10000-0000-0000-0000-000000000091', 'active', 100.00, 100.00, 7001,
  'ab1b0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'ab1b0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
);

INSERT INTO public.sale_items (
  id, company_id, sale_id, variant_id, quantity, unit_price, line_total, created_by, updated_by
) VALUES (
  '1ab10000-0000-0000-0000-0000000000a1', 'c1b00000-0000-0000-0000-000000000001',
  '1ab10000-0000-0000-0000-000000000001', 'dcb00000-0000-0000-0000-000000000001',
  5, 10.00, 50.00,
  'ab1b0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'ab1b0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
);

INSERT INTO public.sale_item_batches (
  id, company_id, sale_item_id, lot_id, quantity, created_by, updated_by
) VALUES (
  '1ab10000-0000-0000-0000-0000000000b1', 'c1b00000-0000-0000-0000-000000000001',
  '1ab10000-0000-0000-0000-0000000000a1', 'dab00000-0000-0000-0000-000000000001',
  5,
  'ab1b0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'ab1b0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
);

SELECT plan(66);

-- ============================================================================
-- Table existence
-- ============================================================================
SELECT has_table('public', 'returns', 'returns table exists');
SELECT has_table('public', 'return_items', 'return_items table exists');
SELECT has_table('public', 'return_item_batches', 'return_item_batches table exists');

-- ============================================================================
-- returns columns
-- ============================================================================
SELECT has_column('public', 'returns', 'id', 'returns.id exists');
SELECT has_column('public', 'returns', 'company_id', 'returns.company_id exists');
SELECT has_column('public', 'returns', 'branch_id', 'returns.branch_id exists');
SELECT has_column('public', 'returns', 'sale_id', 'returns.sale_id exists');
SELECT has_column('public', 'returns', 'type', 'returns.type exists');
SELECT has_column('public', 'returns', 'status', 'returns.status exists');
SELECT has_column('public', 'returns', 'total_amount', 'returns.total_amount exists');
SELECT has_column('public', 'returns', 'reason', 'returns.reason exists');
SELECT has_column('public', 'returns', 'authorized_by', 'returns.authorized_by exists');
SELECT has_column('public', 'returns', 'is_active', 'returns.is_active exists');
SELECT has_column('public', 'returns', 'deleted_at', 'returns.deleted_at exists (soft-delete)');

-- ============================================================================
-- return_items columns
-- ============================================================================
SELECT has_column('public', 'return_items', 'id', 'return_items.id exists');
SELECT has_column('public', 'return_items', 'company_id', 'return_items.company_id exists');
SELECT has_column('public', 'return_items', 'return_id', 'return_items.return_id exists');
SELECT has_column('public', 'return_items', 'sale_item_id', 'return_items.sale_item_id exists');
SELECT has_column('public', 'return_items', 'variant_id', 'return_items.variant_id exists');
SELECT has_column('public', 'return_items', 'qty', 'return_items.qty exists');
SELECT has_column('public', 'return_items', 'destination', 'return_items.destination exists');
SELECT has_column('public', 'return_items', 'unit_price', 'return_items.unit_price exists');
SELECT has_column('public', 'return_items', 'subtotal', 'return_items.subtotal exists');

-- ============================================================================
-- return_item_batches columns
-- ============================================================================
SELECT has_column('public', 'return_item_batches', 'id', 'return_item_batches.id exists');
SELECT has_column('public', 'return_item_batches', 'company_id', 'return_item_batches.company_id exists');
SELECT has_column('public', 'return_item_batches', 'return_item_id', 'return_item_batches.return_item_id exists');
SELECT has_column('public', 'return_item_batches', 'original_batch_id', 'return_item_batches.original_batch_id exists');
SELECT has_column('public', 'return_item_batches', 'variant_id', 'return_item_batches.variant_id exists');
SELECT has_column('public', 'return_item_batches', 'qty', 'return_item_batches.qty exists');

-- ============================================================================
-- NOT NULL on key columns
-- ============================================================================
SELECT col_not_null('public', 'returns', 'company_id', 'returns.company_id NOT NULL');
SELECT col_not_null('public', 'returns', 'sale_id', 'returns.sale_id NOT NULL');
SELECT col_not_null('public', 'returns', 'type', 'returns.type NOT NULL');
SELECT col_not_null('public', 'returns', 'status', 'returns.status NOT NULL');
SELECT col_not_null('public', 'return_items', 'qty', 'return_items.qty NOT NULL');
SELECT col_not_null('public', 'return_items', 'destination', 'return_items.destination NOT NULL');
SELECT col_not_null('public', 'return_item_batches', 'qty', 'return_item_batches.qty NOT NULL');

-- ============================================================================
-- Unique (company_id, id) indexes backing the composite FKs
-- ============================================================================
SELECT index_is_unique('public', 'returns', 'idx_returns_company_id_id', 'returns has UNIQUE (company_id, id)');
SELECT index_is_unique('public', 'return_items', 'idx_return_items_company_id_id', 'return_items has UNIQUE (company_id, id)');
SELECT index_is_unique('public', 'return_item_batches', 'idx_return_item_batches_company_id_id', 'return_item_batches has UNIQUE (company_id, id)');

-- ============================================================================
-- Valid insert of returns + return_items + return_item_batches
-- ============================================================================
SELECT lives_ok(
  $$ INSERT INTO public.returns (
       id, company_id, branch_id, sale_id, type, status, total_amount, reason,
       authorized_by, created_by, updated_by
     ) VALUES (
       'fbb10000-0000-0000-0000-000000000001',
       'c1b00000-0000-0000-0000-000000000001',
       'b1b00000-1111-1111-1111-111111111111',
       '1ab10000-0000-0000-0000-000000000001',
       'partial', 'completed', 30.00, 'damaged',
       'ab1b0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
       'ab1b0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
       'ab1b0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
     ) $$,
  'returns: valid insert succeeds'
);

SELECT lives_ok(
  $$ INSERT INTO public.return_items (
       id, company_id, return_id, sale_item_id, variant_id, qty,
       destination, unit_price, subtotal, created_by, updated_by
     ) VALUES (
       'fbb10000-0000-0000-0000-0000000000d1',
       'c1b00000-0000-0000-0000-000000000001',
       'fbb10000-0000-0000-0000-000000000001',
       '1ab10000-0000-0000-0000-0000000000a1',
       'dcb00000-0000-0000-0000-000000000001', 3, 'inventario', 10.00, 30.00,
       'ab1b0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
       'ab1b0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
     ) $$,
  'return_items: valid insert succeeds'
);

SELECT lives_ok(
  $$ INSERT INTO public.return_item_batches (
       id, company_id, return_item_id, original_batch_id, variant_id, qty,
       created_by, updated_by
     ) VALUES (
       'fbb10000-0000-0000-0000-0000000000e1',
       'c1b00000-0000-0000-0000-000000000001',
       'fbb10000-0000-0000-0000-0000000000d1',
       '1ab10000-0000-0000-0000-0000000000b1',
       'dcb00000-0000-0000-0000-000000000001', 3,
       'ab1b0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
       'ab1b0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
     ) $$,
  'return_item_batches: valid insert succeeds'
);

-- ============================================================================
-- CHECK constraints
-- ============================================================================
SELECT throws_ok(
  $$ INSERT INTO public.returns (id, company_id, branch_id, sale_id, type, created_by, updated_by)
     VALUES ('fbb10000-0000-0000-0000-000000000002',
       'c1b00000-0000-0000-0000-000000000001', 'b1b00000-1111-1111-1111-111111111111',
       '1ab10000-0000-0000-0000-000000000001', 'foo',
       'ab1b0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'ab1b0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa') $$,
  NULL, NULL, 'returns: type CHECK rejects invalid value'
);

SELECT throws_ok(
  $$ INSERT INTO public.returns (id, company_id, branch_id, sale_id, type, status, created_by, updated_by)
     VALUES ('fbb10000-0000-0000-0000-000000000003',
       'c1b00000-0000-0000-0000-000000000001', 'b1b00000-1111-1111-1111-111111111111',
       '1ab10000-0000-0000-0000-000000000001', 'partial', 'foo',
       'ab1b0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'ab1b0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa') $$,
  NULL, NULL, 'returns: status CHECK rejects invalid value'
);

SELECT throws_ok(
  $$ INSERT INTO public.return_items (id, company_id, return_id, sale_item_id, variant_id, qty, destination, unit_price, subtotal, created_by, updated_by)
     VALUES ('fbb10000-0000-0000-0000-0000000000d2',
       'c1b00000-0000-0000-0000-000000000001', 'fbb10000-0000-0000-0000-000000000001',
       '1ab10000-0000-0000-0000-0000000000a1', 'dcb00000-0000-0000-0000-000000000001', 1, 'foo',
       10.00, 10.00, 'ab1b0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'ab1b0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa') $$,
  NULL, NULL, 'return_items: destination CHECK rejects invalid value'
);

SELECT throws_ok(
  $$ INSERT INTO public.return_items (id, company_id, return_id, sale_item_id, variant_id, qty, destination, unit_price, subtotal, created_by, updated_by)
     VALUES ('fbb10000-0000-0000-0000-0000000000d3',
       'c1b00000-0000-0000-0000-000000000001', 'fbb10000-0000-0000-0000-000000000001',
       '1ab10000-0000-0000-0000-0000000000a1', 'dcb00000-0000-0000-0000-000000000001', 0, 'merma',
       10.00, 0.00, 'ab1b0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'ab1b0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa') $$,
  NULL, NULL, 'return_items: qty CHECK rejects zero'
);

SELECT throws_ok(
  $$ INSERT INTO public.return_item_batches (id, company_id, return_item_id, original_batch_id, variant_id, qty, created_by, updated_by)
     VALUES ('fbb10000-0000-0000-0000-0000000000e2',
       'c1b00000-0000-0000-0000-000000000001', 'fbb10000-0000-0000-0000-0000000000d1',
       '1ab10000-0000-0000-0000-0000000000b1', 'dcb00000-0000-0000-0000-000000000001', 0,
       'ab1b0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'ab1b0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa') $$,
  NULL, NULL, 'return_item_batches: qty CHECK rejects zero'
);

-- ============================================================================
-- Composite FKs (same-company reference integrity)
-- ============================================================================
-- returns → sales: unknown sale_id for this company
SELECT throws_ok(
  $$ INSERT INTO public.returns (id, company_id, branch_id, sale_id, type, created_by, updated_by)
     VALUES ('fbb10000-0000-0000-0000-000000000021',
       'c1b00000-0000-0000-0000-000000000001', 'b1b00000-1111-1111-1111-111111111111',
       'ffffffff-0000-0000-0000-000000000099', 'partial',
       'ab1b0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'ab1b0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa') $$,
  NULL, NULL, 'returns: composite FK (company_id, sale_id)→sales rejects unknown sale'
);

-- return_items → returns: unknown return_id
SELECT throws_ok(
  $$ INSERT INTO public.return_items (id, company_id, return_id, sale_item_id, variant_id, qty, destination, unit_price, subtotal, created_by, updated_by)
     VALUES ('fbb10000-0000-0000-0000-0000000000d9',
       'c1b00000-0000-0000-0000-000000000001', 'ffffffff-0000-0000-0000-0000000000ff',
       '1ab10000-0000-0000-0000-0000000000a1', 'dcb00000-0000-0000-0000-000000000001', 1, 'inventario',
       10.00, 10.00, 'ab1b0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'ab1b0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa') $$,
  NULL, NULL, 'return_items: composite FK (company_id, return_id)→returns rejects unknown return'
);

-- return_items → sale_items: unknown sale_item_id
SELECT throws_ok(
  $$ INSERT INTO public.return_items (id, company_id, return_id, sale_item_id, variant_id, qty, destination, unit_price, subtotal, created_by, updated_by)
     VALUES ('fbb10000-0000-0000-0000-0000000000da',
       'c1b00000-0000-0000-0000-000000000001', 'fbb10000-0000-0000-0000-000000000001',
       'ffffffff-0000-0000-0000-0000000000a1', 'dcb00000-0000-0000-0000-000000000001', 1, 'inventario',
       10.00, 10.00, 'ab1b0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'ab1b0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa') $$,
  NULL, NULL, 'return_items: composite FK (company_id, sale_item_id)→sale_items rejects unknown sale_item'
);

-- return_item_batches → return_items: unknown return_item_id
SELECT throws_ok(
  $$ INSERT INTO public.return_item_batches (id, company_id, return_item_id, original_batch_id, variant_id, qty, created_by, updated_by)
     VALUES ('fbb10000-0000-0000-0000-0000000000e9',
       'c1b00000-0000-0000-0000-000000000001', 'ffffffff-0000-0000-0000-0000000000dd',
       '1ab10000-0000-0000-0000-0000000000b1', 'dcb00000-0000-0000-0000-000000000001', 1,
       'ab1b0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'ab1b0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa') $$,
  NULL, NULL, 'return_item_batches: composite FK (company_id, return_item_id)→return_items rejects unknown return_item'
);

-- return_item_batches → sale_item_batches: unknown original_batch_id
SELECT throws_ok(
  $$ INSERT INTO public.return_item_batches (id, company_id, return_item_id, original_batch_id, variant_id, qty, created_by, updated_by)
     VALUES ('fbb10000-0000-0000-0000-0000000000ea',
       'c1b00000-0000-0000-0000-000000000001', 'fbb10000-0000-0000-0000-0000000000d1',
       'ffffffff-0000-0000-0000-0000000000b1', 'dcb00000-0000-0000-0000-000000000001', 1,
       'ab1b0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'ab1b0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa') $$,
  NULL, NULL, 'return_item_batches: composite FK (company_id, original_batch_id)→sale_item_batches rejects unknown batch'
);

-- ============================================================================
-- Append-only / logical-delete protection
-- ============================================================================
SELECT throws_ok(
  $$ UPDATE public.return_items SET qty = 999 WHERE id = 'fbb10000-0000-0000-0000-0000000000d1' $$,
  NULL, NULL, 'return_items: direct UPDATE is rejected (append-only)'
);

SELECT throws_ok(
  $$ DELETE FROM public.return_items WHERE id = 'fbb10000-0000-0000-0000-0000000000d1' $$,
  NULL, NULL, 'return_items: physical DELETE is rejected'
);

SELECT throws_ok(
  $$ UPDATE public.return_item_batches SET qty = 999 WHERE id = 'fbb10000-0000-0000-0000-0000000000e1' $$,
  NULL, NULL, 'return_item_batches: direct UPDATE is rejected (append-only)'
);

SELECT throws_ok(
  $$ DELETE FROM public.return_item_batches WHERE id = 'fbb10000-0000-0000-0000-0000000000e1' $$,
  NULL, NULL, 'return_item_batches: physical DELETE is rejected'
);

SELECT throws_ok(
  $$ DELETE FROM public.returns WHERE id = 'fbb10000-0000-0000-0000-000000000001' $$,
  NULL, NULL, 'returns: physical DELETE is rejected (logical deletion only)'
);

-- returns UPDATE for status transition is allowed (D7)
SELECT lives_ok(
  $$ UPDATE public.returns SET status = 'approved', updated_by = 'ab1b0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
       WHERE id = 'fbb10000-0000-0000-0000-000000000001' $$,
  'returns: UPDATE for status transition is allowed'
);

-- ============================================================================
-- RR7: additive CHECK extensions on stock_movements + cash_movements
-- Existing types still accepted + new types accepted
-- ============================================================================
-- existing positive
SELECT lives_ok(
  $$ INSERT INTO public.stock_movements (
       company_id, branch_id, variant_id, lot_id, movement_type, delta_qty, created_by, updated_by
     ) VALUES (
       'c1b00000-0000-0000-0000-000000000001', 'b1b00000-1111-1111-1111-111111111111',
       'dcb00000-0000-0000-0000-000000000001', 'dab00000-0000-0000-0000-000000000001',
       'sale_return', 3, 'ab1b0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'ab1b0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
     ) $$,
  'stock_movements: existing sale_return (positive) still accepted'
);

-- new negative types
SELECT lives_ok(
  $$ INSERT INTO public.stock_movements (
       company_id, branch_id, variant_id, lot_id, movement_type, delta_qty, created_by, updated_by
     ) VALUES (
       'c1b00000-0000-0000-0000-000000000001', 'b1b00000-1111-1111-1111-111111111111',
       'dcb00000-0000-0000-0000-000000000001', 'dab00000-0000-0000-0000-000000000001',
       'waste_return', -1, 'ab1b0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'ab1b0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
     ) $$,
  'stock_movements: waste_return (negative) accepted'
);

SELECT lives_ok(
  $$ INSERT INTO public.stock_movements (
       company_id, branch_id, variant_id, lot_id, movement_type, delta_qty, created_by, updated_by
     ) VALUES (
       'c1b00000-0000-0000-0000-000000000001', 'b1b00000-1111-1111-1111-111111111111',
       'dcb00000-0000-0000-0000-000000000001', 'dab00000-0000-0000-0000-000000000001',
       'warranty_return', -1, 'ab1b0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'ab1b0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
     ) $$,
  'stock_movements: warranty_return (negative) accepted'
);

SELECT lives_ok(
  $$ INSERT INTO public.stock_movements (
       company_id, branch_id, variant_id, lot_id, movement_type, delta_qty, created_by, updated_by
     ) VALUES (
       'c1b00000-0000-0000-0000-000000000001', 'b1b00000-1111-1111-1111-111111111111',
       'dcb00000-0000-0000-0000-000000000001', 'dab00000-0000-0000-0000-000000000001',
       'disposal_return', -1, 'ab1b0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'ab1b0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
     ) $$,
  'stock_movements: disposal_return (negative) accepted'
);

-- sign constraint: waste_return with positive delta rejected
SELECT throws_ok(
  $$ INSERT INTO public.stock_movements (
       company_id, branch_id, variant_id, lot_id, movement_type, delta_qty, created_by, updated_by
     ) VALUES (
       'c1b00000-0000-0000-0000-000000000001', 'b1b00000-1111-1111-1111-111111111111',
       'dcb00000-0000-0000-0000-000000000001', 'dab00000-0000-0000-0000-000000000001',
       'waste_return', 1, 'ab1b0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'ab1b0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
     ) $$,
  NULL, NULL, 'stock_movements: waste_return with positive delta rejected (sign constraint)'
);

-- cash_movements: existing and new sale_return_refund accepted
SELECT lives_ok(
  $$ INSERT INTO public.cash_movements (
       company_id, branch_id, cash_session_id, movement_type, amount, created_by, updated_by
     ) VALUES (
       'c1b00000-0000-0000-0000-000000000001', 'b1b00000-1111-1111-1111-111111111111',
       '0cb10000-0000-0000-0000-000000000091', 'manual_cash_out', 10.00,
       'ab1b0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'ab1b0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
     ) $$,
  'cash_movements: existing manual_cash_out still accepted'
);

SELECT lives_ok(
  $$ INSERT INTO public.cash_movements (
       company_id, branch_id, cash_session_id, movement_type, amount, created_by, updated_by
     ) VALUES (
       'c1b00000-0000-0000-0000-000000000001', 'b1b00000-1111-1111-1111-111111111111',
       '0cb10000-0000-0000-0000-000000000091', 'sale_return_refund', 20.00,
       'ab1b0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'ab1b0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
     ) $$,
  'cash_movements: sale_return_refund accepted'
);

SELECT throws_ok(
  $$ INSERT INTO public.cash_movements (
       company_id, branch_id, cash_session_id, movement_type, amount, created_by, updated_by
     ) VALUES (
       'c1b00000-0000-0000-0000-000000000001', 'b1b00000-1111-1111-1111-111111111111',
       '0cb10000-0000-0000-0000-000000000091', 'sale_return_refund', 0.00,
       'ab1b0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'ab1b0000-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
     ) $$,
  NULL, NULL, 'cash_movements: sale_return_refund zero amount rejected'
);

-- ============================================================================
-- Cleanup
-- ============================================================================
SELECT * FROM finish();
ROLLBACK;