// Edge Function: purchasing/cancel-purchase-order
// (source: RP9, RP10 — cancel PO, admin-only)
//
// Invokes cancel_purchase_order(JSONB) SECURITY DEFINER RPC.
// Allows cancellation for POs in draft/sent/partial status.
// Rejects received POs. Does not reverse receipts or inventory.

import { handlePurchasingRpc } from "../../_shared/purchasing_handler.ts";
import type { PurchasingHandlerDeps } from "../../_shared/purchasing_handler.ts";
import { CancelPurchaseOrderRequest } from "../../_shared/purchasing_schemas.ts";
import type { CancelPurchaseOrderResult } from "../../_shared/purchasing_schemas.ts";

export function handleCancelPurchaseOrder(
  req: Request,
  deps?: PurchasingHandlerDeps,
): Promise<Response> {
  return handlePurchasingRpc<CancelPurchaseOrderResult>(
    req,
    "cancel_purchase_order",
    CancelPurchaseOrderRequest,
    (input) => input.company_id as string,
    deps,
  );
}

if (import.meta.main) {
  Deno.serve(handleCancelPurchaseOrder);
}
