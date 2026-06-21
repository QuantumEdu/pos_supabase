// Shared handler for invoking the return_sale_item_transaction RPC
// from the return-sale-item Edge Function.
// The EF layer owns actor_user_id/company_id and never trusts client copies.
// (source: RR6, D6 — follows credit_payment_handler pattern)

import { handleCashSessionRpc } from "./cash_session_handler.ts";
import type { CashSessionHandlerDeps } from "./cash_session_handler.ts";
import { ReturnSaleItemRequest } from "./return_schemas.ts";
import type { ReturnSaleItemResult } from "./return_schemas.ts";

/** Dependency-injection handle for the return handler */
export type ReturnHandlerDeps = CashSessionHandlerDeps;

/**
 * Handle a return-sale-item request.
 *
 * Follows the 8-step critical-op pattern:
 *   1. CORS preflight → handleCashSessionRpc
 *   2. validateAuth → AuthContext {user, companyId, role}
 *   3. Role check → admin only
 *   4. Zod.parse body → ReturnSaleItemRequest
 *   5. Inject actor_user_id + company_id into RPC payload
 *   6. service_role.rpc('return_sale_item_transaction', {p})
 *   7. (audit logging — future)
 *   8. Return EFResult<ReturnSaleItemResult>
 */
export function handleReturnSaleItem(
  req: Request,
  deps?: ReturnHandlerDeps,
): Promise<Response> {
  return handleCashSessionRpc<ReturnSaleItemResult>(
    req,
    "return_sale_item_transaction",
    ReturnSaleItemRequest,
    ["admin"],
    deps,
  );
}