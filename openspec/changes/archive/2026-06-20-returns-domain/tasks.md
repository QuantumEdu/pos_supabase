# Tasks: Returns Domain

## Review Workload Forecast

| Field | Value |
|-------|-------|
| Estimated changed lines | ~780 (migration ~300 + EF/schemas/handler ~150 + pgTAP ~250 + Deno ~80) |
| 400-line budget risk | High |
| Chained PRs recommended | Yes |
| Suggested split | PR1: SQL foundation (migration + pgTAP) → PR2: EF + Deno tests |
| Delivery strategy | force-chained |
| Chain strategy | feature-branch-chain |

Decision needed before apply: No
Chained PRs recommended: Yes
Chain strategy: feature-branch-chain
400-line budget risk: High

### Suggested Work Units

| Unit | Goal | Likely PR | Notes |
|------|------|-----------|-------|
| 1 | SQL foundation: migration + CHECK extensions + RPC + RLS + grants + 3 pgTAP suites | PR 1 | Base: feature/returns-domain; tests included |
| 2 | Edge Function layer: Zod schemas + handler + index + Deno test | PR 2 | Base: PR 1 branch; depends on PR 1 RPC |

## Phase 1: SQL Foundation (PR1)

- [x] 1.1 Create `supabase/migrations/00011_returns_domain.sql` — `returns`, `return_items`, `return_item_batches` tables with columns, composite FKs, unique `(company_id, id)`, CHECKs, indexes. **Verify**: `supabase db reset` succeeds.
- [x] 1.2 Add CHECK extensions on `stock_movements.movement_type` (add `waste_return`, `warranty_return`, `disposal_return`), `stock_movements.delta_qty` sign constraint (group new types with negatives), and `cash_movements.movement_type` (add `sale_return_refund`) via idempotent `DO $$` blocks. **Verify**: existing types still accepted; new types accepted.
- [x] 1.3 Create `return_sale_item_transaction(p JSONB) → JSONB` SECURITY DEFINER RPC — `SET search_path=public`, REVOKE ALL FROM PUBLIC+anon, GRANT EXECUTE to authenticated. Atomic: validate sale → validate qty available → validate batches → insert header+items+batches → route inventory per destination → cash reversal if applicable → return result. **Verify**: valid partial return commits; invalid input rolls back entirely.
- [x] 1.4 Create RLS policies + grants for all 3 return tables — admin-only INSERT/UPDATE via RPC, company/branch-scoped SELECT, no DELETE policy, service_role bypass. **Verify**: non-admin INSERT rejected; admin SELECT scoped to company.
- [x] 1.5 Create `supabase/tests/test_returns_constraints.sql` — pgTAP: table columns exist, CHECKs enforce (`type`, `status`, `destination`, `qty>0`), composite FKs valid, unique `(company_id, id)`, physical DELETE blocked. **Verify**: `supabase test db` all pass.
- [x] 1.6 Create `supabase/tests/test_returns_rpcs.sql` — pgTAP: valid return commits (RR2 scenarios), qty overflow rejected, cancelled sale rejected, wrong lot rejected, inventario routes through `adjust_inventory_stock`, merma/garantia/desecho create single negative `stock_movements` each (RR3), cash refund for cash-paid (RR4), credit-only skips cash movement, no open session → rejected, full rollback on any failure. **Verify**: `supabase test db` all pass.
- [x] 1.7 Create `supabase/tests/test_returns_rls.sql` — pgTAP: admin INSERT OK, non-admin INSERT rejected, company-scoped SELECT, branch-scoped SELECT for non-admin, no DELETE policy (RR5). **Verify**: `supabase test db` all pass.

## Phase 2: Edge Function + Deno Tests (PR2)

- [x] 2.1 Create `supabase/functions/_shared/return_schemas.ts` — `ReturnSaleItemRequest` and `ReturnSaleItemResult` Zod schemas per D6/D7 contracts. **Verify**: Zod parse accepts valid input; rejects invalid.
- [x] 2.2 Create `supabase/functions/_shared/return_handler.ts` — `handleReturnSaleItem` shared handler, admin-only, 8-step pattern (auth → company → branch → role → Zod → RPC → audit → EFResult). **Verify**: TypeScript compiles; handler rejects non-admin.
- [x] 2.3 Create `supabase/functions/return-sale-item/index.ts` — thin entry point delegating to shared handler. **Verify**: `deno check` succeeds; EF deploys via `supabase functions deploy`.
- [x] 2.4 Create `supabase/functions/_test/return_ef_test.ts` — Deno test: valid admin call succeeds (RR6), non-admin receives `FORBIDDEN`, invalid Zod input rejected, missing auth → 401, RPC invocation returns `EFResult` with `return_id`. **Verify**: `deno test` all pass.