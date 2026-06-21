// Edge Function: inventory/reserve-stock
// (source: RI10 — V1.5 stub behavior)

import { handleInventoryRpc } from "../../_shared/inventory_handler.ts";
import { ReserveStockRequest } from "../../_shared/inventory_schemas.ts";
import type { InventoryHandlerDeps } from "../../_shared/inventory_handler.ts";

export function handleReserveStock(
  req: Request,
  deps?: InventoryHandlerDeps,
): Promise<Response> {
  return handleInventoryRpc(
    req,
    "reserve_stock",
    ReserveStockRequest,
    (input) => input.company_id as string,
    deps,
  );
}

if (import.meta.main) {
  Deno.serve(handleReserveStock);
}
