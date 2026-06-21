# Design: Edge Functions-Only Module Architecture

## Technical Approach

Remove Vue/Vite/frontend scaffold entirely; repackage as Supabase CLI + Deno project. Design the catalog-domain schema, RPC boundary, and EF contracts as a blueprint for the downstream catalog-domain change. Preserve all deployed migrations (00001-00003) and the health EF.

## Architecture Decisions

### D8: Remove Frontend Scaffold — Clean Break

| Option | Tradeoff | Decision |
|--------|----------|----------|
| A: Delete all; rewrite package.json | Clean, no dead code, matches architecture | ✅ |
| B: Demote to /frontend | Mixed signals, still carries npm/Vue | ❌ |
| C: Keep until catalog ready | Contradicts R7/R8, wrong test tooling | ❌ |

**Rationale**: User explicitly rejected frontend-centered approach. Vue scaffold has zero business logic.

### D9: package.json + deno.json Dual Config

**Choice**: `package.json` for Supabase CLI + scripts only; `deno.json` for Deno test/lint/import-map config.
**Alternatives**: `package.json` only (Deno ignores it); `deno.json` only (Supabase CLI uses npm).
**Rationale**: Each tool uses its native config. No Vue/Node deps remain.

### D10: Catalog Schema — 6 Tables with Audit Columns

All tables share: `company_id UUID NOT NULL`, `is_active BOOLEAN NOT NULL DEFAULT TRUE`, `created_at/updated_at TIMESTAMPTZ`, `created_by/updated_by UUID`, `deleted_at/updated_at TIMESTAMPTZ`, `deleted_by UUID`. All inherit `set_updated_at()` trigger. All have RLS enabled with `company_id = get_company_id()` pattern.

| Table | Key Columns | Unique Constraints | Indexes |
|-------|-------------|-------------------|---------|
| `brands` | name, slug | `(company_id, slug)` UNIQUE | `company_id` |
| `categories` | name, slug, `parent_id → categories(id)` (NULL=root) | `(company_id, slug)` UNIQUE; cycle-prevention trigger | `company_id`, `parent_id` |
| `units` | name, abbreviation | `(company_id, name)` UNIQUE | `company_id` |
| `products` | brand_id→brands, category_id→categories, name, slug, description | `(company_id, slug)` UNIQUE | `company_id`, `brand_id`, `category_id` |
| `product_variants` | product_id→products, sku, barcode, name | `(company_id, sku)` UNIQUE; `(company_id, barcode)` UNIQUE WHERE barcode NOT NULL | `company_id`, `product_id` |
| `product_prices` | variant_id→product_variants, price numeric(12,2), currency text DEFAULT 'USD', effective_from, effective_until | `(variant_id)` UNIQUE WHERE effective_until IS NULL — at most one active price | `company_id`, `variant_id`, `effective_from` |

**Rationale**: Separate `product_prices` supports temporal pricing (RC5). `parent_id` self-FK enables hierarchical categories (RC2). Partial unique index enforces "one active price per variant". Cycle prevention via BEFORE UPDATE trigger that walks ancestor chain.

### D11: RPC Boundary — SECURITY DEFINER for Atomic Mutations

| RPC Signature | Purpose | Auth |
|--------------|---------|------|
| `create_product_with_variant(p_co UUID, p_brand UUID, p_cat UUID, p_name TEXT, p_slug TEXT, p_sku TEXT, p_vname TEXT, p_price NUMERIC, p_currency TEXT)` → JSON | Atomic product+variant+price creation | Admin (EF validates) |
| `deactivate_product(p_product_id UUID)` → VOID | Logical delete product + all variants | Admin (EF validates) |
| `set_variant_price(p_variant_id UUID, p_price NUMERIC, p_currency TEXT)` → JSON | Close previous price, open new | Admin (EF validates) |

**Rationale**: Multi-table creates/deactivations must be atomic (R6). SELECT reads bypass EF — SDK+RLS (RC6). Simple column updates (name, barcode) use SDK+RLS with audit triggers; only price changes need RPC for temporal close+open logic.

### D12: EF Layout and Contracts

```
supabase/functions/
  _shared/cors.ts (existing)
  _shared/auth.ts (NEW: validateAuth 8-step)
  _shared/types.ts (NEW: EFResult<T> = {success,data,error})
  catalog/
    create-product/index.ts
    update-product/index.ts
    deactivate-product/index.ts
```

`EFResult<T>`: `{ success: boolean; data?: T; error?: { code: string; message: string } }`
`validateAuth(req, requiredRole)`: D3 steps 1–4. Returns `{ user, companyId, role }` or throws `EFResult` error.

8-step pattern per EF: (1) CORS preflight → (2) validate JWT → (3) validate company membership → (4) validate role → (5) validate input schema → (6) invoke RPC → (7) audit log → (8) return EFResult.

### D13: Testing Layout — Deno.test + pgTAP

| Layer | Framework | Location | Runner |
|-------|-----------|----------|--------|
| EF unit/integration | `Deno.test` | `supabase/functions/_test/*.test.ts` | `deno test supabase/functions/_test/` |
| SQL/RLS | pgTAP | `supabase/tests/*.sql` | `supabase test db` |
| Orchestration | npm scripts | `package.json` | `npm run test:all` |

## Data Flow

```
Admin ──→ EF (8-step auth) ──→ RPC (SECURITY DEFINER) ──→ Catalog Tables
  │                                        │
  └── SDK + RLS (reads, own company) ←────┘

Deno.test ──→ EF code (unit/integration)
pgTAP      ──→ RLS isolation (per-tenant)
```

## File Changes

| File | Action | Description |
|------|--------|-------------|
| `src/**` (5 files), `index.html`, `vite.config.ts`, `vitest.config.ts`, `env.d.ts` | Delete | Frontend scaffold removed |
| `tests/setup.ts`, `tests/ef-auth.test.ts`, `tests/supabase-rls.test.ts` | Delete | Vitest stubs replaced |
| `tsconfig.node.json` | Delete | Vite/Node config no longer needed |
| `package-lock.json` | Delete | Regenerates with new package.json |
| `package.json` | Modify | Rewrite: Supabase CLI + Deno scripts only |
| `tsconfig.json` | Modify | Retarget Deno/EF, remove Vue/DOM libs |
| `.gitignore` | Modify | Remove frontend build artifacts, add Deno patterns |
| `deno.json` | Create | Deno config: tasks, lint, import-map |
| `supabase/functions/_shared/auth.ts` | Create | D3 8-step auth validation helper |
| `supabase/functions/_shared/types.ts` | Create | EFResult<T> type definition |
| `supabase/tests/.gitkeep` | Create | Placeholder for pgTAP tests |
| `supabase/config.toml` | Modify | Update auth.site_url (remove :3000 SPA reference) |
| `openspec/specs/project-architecture/spec.md` | Modify | Update R7, R8, D6, D7 for EF-only |
| `openspec/config.yaml` | Modify | Stack, test_command, build_command |

Catalog-domain schema, RPCs, and catalog EFs are **designed here, implemented in the next change**.

## Testing Strategy

| Layer | What | Approach |
|-------|------|----------|
| Unit | Auth validation helpers | `Deno.test` — mock Request, verify step-by-step |
| Integration | Catalog EF → RPC | `Deno.test` — invoke EF against local Supabase |
| DB | RLS tenant isolation | pgTAP — verify company A cannot see company B rows |
| DB | Unique constraints | pgTAP — duplicate SKU/barcode/slug rejected |

## Migration / Rollout

**Strategy**: Feature-branch-chain, 3 slices (≤400 lines each):

| Slice | Content | Risk |
|-------|---------|------|
| 1 | Delete frontend scaffold, rewrite package.json/deno.json/tsconfig, update .gitignore | Low — all in git |
| 2 | Add _shared/auth.ts + types.ts, pgTAP+Deno test stubs, update config.toml+config.yaml+spec | Low — additive only |
| 3 | Verify: `supabase start`, health EF, `deno test`, `supabase test db` all pass | Verification-only |

**Rollback**: Each slice is a single commit on feature branch. `git revert` restores any slice. Remote migrations 00001-00003 and health EF are never modified.

**Remote deployment**: No destructive changes to deployed resources. `supabase db push --linked` is unnecessary until catalog-domain migration. EF deployments are additive (new functions only).

## Open Questions

None — all resolved per user decisions (hierarchical categories, separate product_prices, Deno.test + pgTAP, clean break removal).