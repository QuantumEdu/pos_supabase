-- pgTAP: Customers Demand domain constraint tests
-- Verifies composite FK enforcement, CHECK constraints, unique constraints,
-- nullable acceptance, and set_updated_at trigger on all 4 tables.
-- (source: customers-demand-domain Phase 1, RCD1–RCD7, RCD12–RCD14)

BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap;

SELECT plan(26);

-- ============================================================
-- Setup: Companies and reference data
-- ============================================================
INSERT INTO public.companies (id, name, slug)
VALUES
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'Customers Constraint Co A', 'customers-constraint-co-a'),
  ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'Customers Constraint Co B', 'customers-constraint-co-b');

-- Branches for preorders FK
INSERT INTO public.branches (id, company_id, name, slug)
VALUES
  ('a1111111-1111-1111-1111-111111111111', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'Branch A1', 'branch-a1'),
  ('b1111111-1111-1111-1111-111111111111', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'Branch B1', 'branch-b1');

-- Products and variants for variant FK references
INSERT INTO public.products (id, company_id, name, slug)
VALUES
  ('a2000000-0000-0000-0000-000000000001', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'Product A', 'product-a'),
  ('b2000000-0000-0000-0000-000000000001', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'Product B', 'product-b');

INSERT INTO public.product_variants (id, company_id, product_id, sku, name)
VALUES
  ('a3000000-0000-0000-0000-000000000001', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
   'a2000000-0000-0000-0000-000000000001', 'CD-VA-1', 'Variant A'),
  ('b3000000-0000-0000-0000-000000000001', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
   'b2000000-0000-0000-0000-000000000001', 'CD-VB-1', 'Variant B');

-- Customers for FK references
INSERT INTO public.customers (id, company_id, name, slug)
VALUES
  ('a4000000-0000-0000-0000-000000000001', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'Customer A1', 'customer-a1'),
  ('b4000000-0000-0000-0000-000000000001', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'Customer B1', 'customer-b1');

-- Preorders for preorder_items FK
INSERT INTO public.preorders (id, company_id, branch_id, customer_id, preorder_number, status)
VALUES
  ('a5000000-0000-0000-0000-000000000001', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
   'a1111111-1111-1111-1111-111111111111', 'a4000000-0000-0000-0000-000000000001',
   'PRE-A-001', 'draft'),
  ('b5000000-0000-0000-0000-000000000001', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
   'b1111111-1111-1111-1111-111111111111', 'b4000000-0000-0000-0000-000000000001',
   'PRE-B-001', 'draft');

-- Preorder item for set_updated_at trigger test
INSERT INTO public.preorder_items (id, company_id, preorder_id, variant_id, qty)
VALUES
  ('a6000000-0000-0000-0000-000000000001', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
   'a5000000-0000-0000-0000-000000000001', 'a3000000-0000-0000-0000-000000000001', 5);

-- ============================================================
-- UNIQUENESS: customers (company_id, slug)
-- ============================================================

-- Duplicate slug in same company should fail
SELECT throws_ok(
  $$ INSERT INTO public.customers (company_id, name, slug)
     VALUES ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'Customer A Dup', 'customer-a1') $$,
  NULL,
  NULL,
  'Customers unique: duplicate slug in same company should fail'
);

-- Same slug in different company should succeed
SELECT lives_ok(
  $$ INSERT INTO public.customers (company_id, name, slug)
     VALUES ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'Customer B Other', 'customer-a1') $$,
  'Customers unique: same slug in different company is allowed'
);

-- ============================================================
-- UNIQUENESS: preorders (company_id, preorder_number)
-- ============================================================

-- Duplicate preorder_number in same company should fail
SELECT throws_ok(
  $$ INSERT INTO public.preorders (company_id, branch_id, customer_id, preorder_number, status)
     VALUES ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
             'a1111111-1111-1111-1111-111111111111',
             'a4000000-0000-0000-0000-000000000001',
             'PRE-A-001', 'draft') $$,
  NULL,
  NULL,
  'Preorders unique: duplicate preorder_number in same company should fail'
);

-- Same preorder_number in different company should succeed
SELECT lives_ok(
  $$ INSERT INTO public.preorders (id, company_id, branch_id, customer_id, preorder_number, status)
     VALUES ('b5000000-0000-0000-0000-000000000002', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
             'b1111111-1111-1111-1111-111111111111',
             'b4000000-0000-0000-0000-000000000001',
             'PRE-A-001', 'draft') $$,
  'Preorders unique: same preorder_number in different company is allowed'
);

-- ============================================================
-- CHECK: customer_requests.status rejects invalid values
-- ============================================================

SELECT throws_ok(
  $$ INSERT INTO public.customer_requests (company_id, customer_id, requested_qty, status)
     VALUES ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
             'a4000000-0000-0000-0000-000000000001',
             10, 'bogus_status') $$,
  NULL,
  NULL,
  'Customer requests status: invalid status value should be rejected'
);

-- ============================================================
-- CHECK: customer_requests.requested_qty > 0
-- ============================================================

SELECT throws_ok(
  $$ INSERT INTO public.customer_requests (company_id, customer_id, requested_qty)
     VALUES ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
             'a4000000-0000-0000-0000-000000000001',
             0) $$,
  NULL,
  NULL,
  'Customer requests qty: requested_qty <= 0 should be rejected'
);

-- ============================================================
-- CHECK: preorders.status rejects invalid values
-- ============================================================

SELECT throws_ok(
  $$ INSERT INTO public.preorders (company_id, branch_id, customer_id, preorder_number, status)
     VALUES ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
             'a1111111-1111-1111-1111-111111111111',
             'a4000000-0000-0000-0000-000000000001',
             'PRE-INVALID-STATUS', 'bogus_status') $$,
  NULL,
  NULL,
  'Preorders status: invalid status value should be rejected'
);

-- ============================================================
-- CHECK: preorder_items.qty > 0
-- ============================================================

SELECT throws_ok(
  $$ INSERT INTO public.preorder_items (company_id, preorder_id, variant_id, qty)
     VALUES ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
             'a5000000-0000-0000-0000-000000000001',
             'a3000000-0000-0000-0000-000000000001',
             0) $$,
  NULL,
  NULL,
  'Preorder items qty: qty <= 0 should be rejected'
);

-- ============================================================
-- NULLABLE: preorder_items.unit_price accepts NULL
-- ============================================================

SELECT lives_ok(
  $$ INSERT INTO public.preorder_items (id, company_id, preorder_id, variant_id, qty, unit_price)
     VALUES ('a6000000-0000-0000-0000-000000000002', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
             'a5000000-0000-0000-0000-000000000001',
             'a3000000-0000-0000-0000-000000000001',
             3, NULL) $$,
  'Preorder items: unit_price NULL is accepted'
);

-- ============================================================
-- NOT NULL: preorder_items.variant_id rejects NULL
-- ============================================================

SELECT throws_ok(
  $$ INSERT INTO public.preorder_items (company_id, preorder_id, variant_id, qty)
     VALUES ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
             'a5000000-0000-0000-0000-000000000001',
             NULL, 3) $$,
  NULL,
  NULL,
  'Preorder items: variant_id NULL should be rejected (NOT NULL constraint)'
);

-- ============================================================
-- COMPOSITE FK INTEGRITY: Cross-tenant rejection
-- Each test inserts a row with company A's company_id but
-- references a row from company B — composite FK must reject.
-- ============================================================

-- 1. customer_requests → customers cross-tenant
SELECT throws_ok(
  $$ INSERT INTO public.customer_requests (company_id, customer_id, requested_qty)
     VALUES ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
             'b4000000-0000-0000-0000-000000000001', -- Company B's customer
             5) $$,
  NULL,
  NULL,
  'Cross-tenant FK: customer_requests referencing another company customer should fail'
);

-- 2. customer_requests → variant cross-tenant
SELECT throws_ok(
  $$ INSERT INTO public.customer_requests (company_id, customer_id, variant_id, requested_qty)
     VALUES ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
             'a4000000-0000-0000-0000-000000000001',
             'b3000000-0000-0000-0000-000000000001', -- Company B's variant
             5) $$,
  NULL,
  NULL,
  'Cross-tenant FK: customer_requests referencing another company variant should fail'
);

-- 3. customer_requests variant_id NULL accepted (nullable FK)
SELECT lives_ok(
  $$ INSERT INTO public.customer_requests (id, company_id, customer_id, variant_id, requested_qty)
     VALUES ('c7000000-0000-0000-0000-000000000001', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
             'a4000000-0000-0000-0000-000000000001',
             NULL, 5) $$,
  'Cross-tenant FK: customer_requests with NULL variant_id is accepted'
);

-- 4. customer_requests valid same-company variant FK
SELECT lives_ok(
  $$ INSERT INTO public.customer_requests (id, company_id, customer_id, variant_id, requested_qty)
     VALUES ('c7000000-0000-0000-0000-000000000002', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
             'a4000000-0000-0000-0000-000000000001',
             'a3000000-0000-0000-0000-000000000001', -- Same company variant
             5) $$,
  'Cross-tenant FK: customer_requests with valid same-company variant succeeds'
);

-- 5. preorders → customers cross-tenant
SELECT throws_ok(
  $$ INSERT INTO public.preorders (company_id, branch_id, customer_id, preorder_number, status)
     VALUES ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
             'a1111111-1111-1111-1111-111111111111',
             'b4000000-0000-0000-0000-000000000001', -- Company B's customer
             'PRE-CROSS-CUST', 'draft') $$,
  NULL,
  NULL,
  'Cross-tenant FK: preorders referencing another company customer should fail'
);

-- 6. preorders → branches cross-tenant
SELECT throws_ok(
  $$ INSERT INTO public.preorders (company_id, branch_id, customer_id, preorder_number, status)
     VALUES ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
             'b1111111-1111-1111-1111-111111111111', -- Company B's branch
             'a4000000-0000-0000-0000-000000000001',
             'PRE-CROSS-BRANCH', 'draft') $$,
  NULL,
  NULL,
  'Cross-tenant FK: preorders referencing another company branch should fail'
);

-- 7. preorder_items → preorders cross-tenant
SELECT throws_ok(
  $$ INSERT INTO public.preorder_items (company_id, preorder_id, variant_id, qty)
     VALUES ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
             'b5000000-0000-0000-0000-000000000001', -- Company B's preorder
             'a3000000-0000-0000-0000-000000000001',
             3) $$,
  NULL,
  NULL,
  'Cross-tenant FK: preorder_items referencing another company preorder should fail'
);

-- 8. preorder_items → variant cross-tenant
SELECT throws_ok(
  $$ INSERT INTO public.preorder_items (company_id, preorder_id, variant_id, qty)
     VALUES ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
             'a5000000-0000-0000-0000-000000000001',
             'b3000000-0000-0000-0000-000000000001', -- Company B's variant
             3) $$,
  NULL,
  NULL,
  'Cross-tenant FK: preorder_items referencing another company variant should fail'
);

-- ============================================================
-- set_updated_at TRIGGER: fires on UPDATE for all 4 tables
-- ============================================================

-- Verify set_updated_at on customers
UPDATE public.customers
SET notes = 'Trigger test'
WHERE id = 'a4000000-0000-0000-0000-000000000001';

SELECT is(
  (SELECT (updated_at > created_at) FROM public.customers WHERE id = 'a4000000-0000-0000-0000-000000000001'),
  TRUE,
  'set_updated_at trigger: updated_at was updated on customers'
);

-- Verify set_updated_at on customer_requests
INSERT INTO public.customer_requests (id, company_id, customer_id, requested_qty, status)
VALUES ('c7000000-0000-0000-0000-000000000010', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
        'a4000000-0000-0000-0000-000000000001', 5, 'pending');

UPDATE public.customer_requests
SET notes = 'Trigger test'
WHERE id = 'c7000000-0000-0000-0000-000000000010';

SELECT is(
  (SELECT (updated_at > created_at) FROM public.customer_requests WHERE id = 'c7000000-0000-0000-0000-000000000010'),
  TRUE,
  'set_updated_at trigger: updated_at was updated on customer_requests'
);

-- Verify set_updated_at on preorders
UPDATE public.preorders
SET notes = 'Trigger test'
WHERE id = 'a5000000-0000-0000-0000-000000000001';

SELECT is(
  (SELECT (updated_at > created_at) FROM public.preorders WHERE id = 'a5000000-0000-0000-0000-000000000001'),
  TRUE,
  'set_updated_at trigger: updated_at was updated on preorders'
);

-- Verify set_updated_at on preorder_items
UPDATE public.preorder_items
SET qty = 7
WHERE id = 'a6000000-0000-0000-0000-000000000001';

SELECT is(
  (SELECT (updated_at > created_at) FROM public.preorder_items WHERE id = 'a6000000-0000-0000-0000-000000000001'),
  TRUE,
  'set_updated_at trigger: updated_at was updated on preorder_items'
);

-- ============================================================
-- LOGICAL DELETION: deleted_at/deleted_by accept NULL values
-- ============================================================

-- Verify customers deleted columns accept NULL
SELECT lives_ok(
  $$ INSERT INTO public.customers (id, company_id, name, slug, deleted_at, deleted_by)
     VALUES ('a4000000-0000-0000-0000-000000000099', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
             'Deleted Null Test', 'deleted-null-test', NULL, NULL) $$,
  'Logical deletion: customers deleted_at/deleted_by accept NULL'
);

-- Verify customer_requests deleted columns accept NULL
SELECT lives_ok(
  $$ INSERT INTO public.customer_requests (id, company_id, customer_id, requested_qty, deleted_at, deleted_by)
     VALUES ('c7000000-0000-0000-0000-000000000099', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
             'a4000000-0000-0000-0000-000000000001', 5, NULL, NULL) $$,
  'Logical deletion: customer_requests deleted_at/deleted_by accept NULL'
);

-- Verify preorders deleted columns accept NULL
SELECT lives_ok(
  $$ INSERT INTO public.preorders (id, company_id, branch_id, customer_id, preorder_number, status, deleted_at, deleted_by)
     VALUES ('a5000000-0000-0000-0000-000000000099', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
             'a1111111-1111-1111-1111-111111111111', 'a4000000-0000-0000-0000-000000000001',
             'PRE-NULL-DEL', 'draft', NULL, NULL) $$,
  'Logical deletion: preorders deleted_at/deleted_by accept NULL'
);

-- Verify preorder_items deleted columns accept NULL
SELECT lives_ok(
  $$ INSERT INTO public.preorder_items (id, company_id, preorder_id, variant_id, qty, deleted_at, deleted_by)
     VALUES ('a6000000-0000-0000-0000-000000000099', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
             'a5000000-0000-0000-0000-000000000001', 'a3000000-0000-0000-0000-000000000001',
             3, NULL, NULL) $$,
  'Logical deletion: preorder_items deleted_at/deleted_by accept NULL'
);

-- ============================================================
-- Finish
-- ============================================================
SELECT * FROM finish();
ROLLBACK;
