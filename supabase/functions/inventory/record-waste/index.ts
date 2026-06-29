// Edge Function: inventory/record-waste
// (source: RI3, RI8 — inventory EF contracts)

import { handleInventoryRpc } from "../../_shared/inventory_handler.ts";
import { RecordWasteRequest } from "../../_shared/inventory_schemas.ts";
import type { InventoryHandlerDeps } from "../../_shared/inventory_handler.ts";
import type { InventoryMovementResult } from "../../_shared/inventory_schemas.ts";

export function handleRecordWaste(
  req: Request,
  deps?: InventoryHandlerDeps,
): Promise<Response> {
  return handleInventoryRpc<InventoryMovementResult>(
    req,
    "record_waste",
    RecordWasteRequest,
    (input) => input.company_id as string,
    deps,
  );
}

if (import.meta.main) {
  Deno.serve((req: Request) => handleRecordWaste(req));
}
