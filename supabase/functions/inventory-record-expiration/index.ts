// Edge Function: inventory/record-expiration
// (source: RI3, RI8 — inventory EF contracts)

import { handleInventoryRpc } from "../_shared/inventory_handler.ts";
import { RecordExpirationRequest } from "../_shared/inventory_schemas.ts";
import type { InventoryHandlerDeps } from "../_shared/inventory_handler.ts";
import type { InventoryExpirationResult } from "../_shared/inventory_schemas.ts";

export function handleRecordExpiration(
  req: Request,
  deps?: InventoryHandlerDeps,
): Promise<Response> {
  return handleInventoryRpc<InventoryExpirationResult>(
    req,
    "record_expiration",
    RecordExpirationRequest,
    (input) => input.company_id as string,
    deps,
  );
}

if (import.meta.main) {
  Deno.serve(handleRecordExpiration);
}
