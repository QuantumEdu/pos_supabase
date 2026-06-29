// Edge Function: inventory/record-sale-return
// (source: RI3, RI8 — inventory EF contracts)

import { handleInventoryRpc } from "../../_shared/inventory_handler.ts";
import { RecordSaleReturnRequest } from "../../_shared/inventory_schemas.ts";
import type { InventoryHandlerDeps } from "../../_shared/inventory_handler.ts";
import type { InventoryMovementResult } from "../../_shared/inventory_schemas.ts";

export function handleRecordSaleReturn(
  req: Request,
  deps?: InventoryHandlerDeps,
): Promise<Response> {
  return handleInventoryRpc<InventoryMovementResult>(
    req,
    "record_sale_return",
    RecordSaleReturnRequest,
    (input) => input.company_id as string,
    deps,
  );
}

if (import.meta.main) {
  Deno.serve((req: Request) => handleRecordSaleReturn(req));
}
