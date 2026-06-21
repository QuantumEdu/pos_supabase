// Edge Function: register-payment
// Admin-only: register a customer payment (abono) against a credit balance.
// Follows the 8-step critical-op pattern via the shared credit-payment handler.
// (source: RCP7, D5)

import { handleRegisterCustomerPayment } from "../_shared/credit_payment_handler.ts";
import type { CreditPaymentHandlerDeps } from "../_shared/credit_payment_handler.ts";

export { handleRegisterCustomerPayment };

if (import.meta.main) {
  Deno.serve(handleRegisterCustomerPayment);
}