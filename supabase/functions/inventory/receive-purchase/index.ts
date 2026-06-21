// Edge Function: inventory/receive-purchase
// (source: RI2, RI5, RI8 — inventory EF contracts)

import { handleInventoryRpc } from "../../_shared/inventory_handler.ts";
import { ReceivePurchaseRequest } from "../../_shared/inventory_schemas.ts";
import type { InventoryHandlerDeps } from "../../_shared/inventory_handler.ts";
import type { ReceivePurchaseResult } from "../../_shared/inventory_schemas.ts";

export function handleReceivePurchase(
  req: Request,
  deps?: InventoryHandlerDeps,
): Promise<Response> {
  return handleInventoryRpc<ReceivePurchaseResult>(
    req,
    "receive_purchase_lot",
    ReceivePurchaseRequest,
    (input) => input.company_id as string,
    deps,
  );
}

if (import.meta.main) {
  Deno.serve(handleReceivePurchase);
}
