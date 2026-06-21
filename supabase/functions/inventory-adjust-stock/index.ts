// Edge Function: inventory/adjust-stock
// (source: RI6, RI8 — inventory EF contracts)

import { handleInventoryRpc } from "../_shared/inventory_handler.ts";
import { AdjustInventoryRequest } from "../_shared/inventory_schemas.ts";
import type { InventoryHandlerDeps } from "../_shared/inventory_handler.ts";
import type { InventoryBatchMovementResult, ReceivePurchaseResult } from "../_shared/inventory_schemas.ts";

export function handleAdjustStock(
  req: Request,
  deps?: InventoryHandlerDeps,
): Promise<Response> {
  return handleInventoryRpc<InventoryBatchMovementResult | ReceivePurchaseResult>(
    req,
    "adjust_inventory",
    AdjustInventoryRequest,
    (input) => input.company_id as string,
    deps,
  );
}

if (import.meta.main) {
  Deno.serve(handleAdjustStock);
}
