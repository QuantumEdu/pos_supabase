// Edge Function: purchasing/create-purchase-order
// (source: RP2, RP10 — EF→RPC pattern)
//
// Invokes create_purchase_order(JSONB) SECURITY DEFINER RPC.
// Validates admin auth, parses input via Zod, delegates to shared handler.

import { handlePurchasingRpc } from "../../_shared/purchasing_handler.ts";
import type { PurchasingHandlerDeps } from "../../_shared/purchasing_handler.ts";
import { CreatePurchaseOrderRequest } from "../../_shared/purchasing_schemas.ts";
import type { PurchaseOrderResult } from "../../_shared/purchasing_schemas.ts";

export function handleCreatePurchaseOrder(
  req: Request,
  deps?: PurchasingHandlerDeps,
): Promise<Response> {
  return handlePurchasingRpc<PurchaseOrderResult>(
    req,
    "create_purchase_order",
    CreatePurchaseOrderRequest,
    (input) => input.company_id as string,
    deps,
  );
}

if (import.meta.main) {
  Deno.serve(handleCreatePurchaseOrder);
}
