# Tasks: POS Sales Domain

## Review Workload Forecast

| Field | Value |
|-------|-------|
| Estimated changed lines | 900-1300 |
| 400-line budget risk | High |
| Chained PRs recommended | Yes |
| Suggested split | PR1 SQL foundation -> PR2 pgTAP hardening -> PR3 shared EF + create-sale -> PR4 cancel/authorize + Deno tests + verify |
| Delivery strategy | auto-chain |
| Chain strategy | feature-branch-chain |

Decision needed before apply: Yes
Chained PRs recommended: Yes
400-line budget risk: High

### Suggested Work Units

| Unit | Goal | Likely PR | Notes |
|------|------|-----------|-------|
| 1 | Create migration `00009_pos_sales_domain.sql` with tables, RLS, RPCs | PR 1 | Base slice; enables all later work |
| 2 | Add pgTAP constraints/RLS/RPC coverage | PR 2 | Depends on PR 1; proves SQL contract |
| 3 | Add shared EF schemas + handler + create-sale EF | PR 3 | Depends on PR 2; first runtime path |
| 4 | Add cancel-sale + authorize-discount EFs + Deno tests + verify report | PR 4 | Depends on PR 3; closes V1 scope |

## Phase 1: SQL Foundation

- [ ] 1.1 Create `supabase/migrations/00009_pos_sales_domain.sql` with `sales`, `sale_items`, `sale_item_batches`, `payments`, `discount_authorizations` tables, composite FKs, indexes, sequence helper for branch-scoped `sale_number`, audit/logical-delete columns. Verify with `supabase db reset` and schema inspection for required columns/constraints.
- [ ] 1.2 Add RLS policies (SELECT per company, all writes denied), grants (service_role only), and SECURITY DEFINER RPCs `create_sale_transaction`, `cancel_sale_transaction`, `authorize_discount` in the same migration. Verify direct authenticated writes fail while service-role RPC execution remains available.

## Phase 2: Database Test Hardening

- [ ] 2.1 Add `supabase/tests/test_pos_sales_constraints.sql` for table existence, status CHECK, composite FK integrity, logical-delete behavior, and sale_number uniqueness per branch. Verify `supabase test db` passes constraint assertions.
- [ ] 2.2 Add `supabase/tests/test_pos_sales_rls.sql` for cashier branch reads, admin company-wide reads, anon zero-row access, and absence of operational DELETE/UPDATE/INSERT paths. Verify `supabase test db` proves RLS isolation and write denial.
- [ ] 2.3 Add `supabase/tests/test_pos_sales_rpcs.sql` for create-sale with open session, create-sale without open session (rejected), cancel-sale reversal, authorize-discount admin gate, and duplicate operations. Verify `supabase test db` covers atomic RPC outcomes and controlled failures.

## Phase 3: Shared EF Runtime + Create-Sale

- [ ] 3.1 Add `supabase/functions/_shared/pos_sales_schemas.ts` for create-sale, cancel-sale, and authorize-discount payload validation. Verify invalid amounts, missing IDs, and bad payment methods fail schema parsing.
- [ ] 3.2 Add `supabase/functions/_shared/pos_sales_handler.ts` extending the shared handler pattern from `cash_session_handler.ts` for sales RPC invocation with cashier/admin roles and company checks. Verify handler returns consistent `EFResult` errors for auth, scope, and RPC failures.
- [ ] 3.3 Add `supabase/functions/pos-sales/create-sale/index.ts` using the shared handler. Verify the function only orchestrates validation plus the correct RPC invocation with server-derived auth context.

## Phase 4: Remaining Runtime and Verification

- [ ] 4.1 Add `supabase/functions/pos-sales/cancel-sale/index.ts` and `supabase/functions/pos-sales/authorize-discount/index.ts` with the same shared contract. Verify cashier/admin boundaries and active-sale validation are enforced end to end.
- [ ] 4.2 Add `supabase/functions/_test/pos_sales_ef_test.ts` covering schema validation, auth/CORS, role gates, create-sale flow, cancel-sale flow, and discount authorization. Verify `deno test supabase/functions/_test/` passes.
- [ ] 4.3 Capture implementation evidence in `openspec/changes/pos-sales-domain/verify.md` with `supabase db reset`, `supabase test db`, and `deno test` results. Verify the report maps passing evidence back to spec requirements RPS1-RPS12.
