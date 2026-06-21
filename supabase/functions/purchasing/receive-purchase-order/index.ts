// Edge Function: purchasing/receive-purchase-order
// (source: RP4-RP6, DP1 — master receipt RPC, single-call atomicity)
//
// Delegates entire receipt workflow to receive_purchase_transaction(JSONB)
// SECURITY DEFINER RPC in a single call. EF does NOT loop over items.
// Atomicity guarantee: either all items received or nothing persisted.

import { handlePurchasingRpc } from "../../_shared/purchasing_handler.ts";
import type { PurchasingHandlerDeps } from "../../_shared/purchasing_handler.ts";
import { ReceivePurchaseOrderRequest } from "../../_shared/purchasing_schemas.ts";
import type { ReceivePurchaseResult } from "../../_shared/purchasing_schemas.ts";

export function handleReceivePurchaseOrder(
  req: Request,
  deps?: PurchasingHandlerDeps,
): Promise<Response> {
  return handlePurchasingRpc<ReceivePurchaseResult>(
    req,
    "receive_purchase_transaction",
    ReceivePurchaseOrderRequest,
    (input) => input.company_id as string,
    deps,
  );
}

if (import.meta.main) {
  Deno.serve(handleReceivePurchaseOrder);
}
