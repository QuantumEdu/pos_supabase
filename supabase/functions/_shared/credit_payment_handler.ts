// Shared helper for invoking the register_customer_payment_transaction RPC
// from the register-payment Edge Function.
// The EF layer owns actor_user_id/company_id and never trusts client copies.
// (source: RCP7, D5 — follows cash-session handler pattern)

import { handleCashSessionRpc } from "./cash_session_handler.ts";
import type { CashSessionHandlerDeps } from "./cash_session_handler.ts";
import { RegisterCustomerPaymentRequest } from "./credit_payment_schemas.ts";
import type { RegisterCustomerPaymentResult } from "./credit_payment_schemas.ts";

/** Dependency-injection handle for the credit-payment handler */
export type CreditPaymentHandlerDeps = CashSessionHandlerDeps;

/**
 * Handle a register-customer-payment request.
 *
 * Follows the 8-step critical-op pattern:
 *   1. CORS preflight → handleCashSessionRpc
 *   2. validateAuth → AuthContext {user, companyId, role}
 *   3. Role check → admin only
 *   4. Zod.parse body → RegisterCustomerPaymentRequest
 *   5. Inject actor_user_id + company_id into RPC payload
 *   6. service_role.rpc('register_customer_payment_transaction', {p})
 *   7. (audit logging — future: R12)
 *   8. Return EFResult<RegisterCustomerPaymentResult>
 */
export function handleRegisterCustomerPayment(
  req: Request,
  deps?: CreditPaymentHandlerDeps,
): Promise<Response> {
  return handleCashSessionRpc<RegisterCustomerPaymentResult>(
    req,
    "register_customer_payment_transaction",
    RegisterCustomerPaymentRequest,
    ["admin"],
    deps,
  );
}