// Edge Function: inventory/release-reservation
// (source: RI10 — V1.5 stub behavior)

import { handleInventoryRpc } from "../../_shared/inventory_handler.ts";
import { ReleaseReservationRequest } from "../../_shared/inventory_schemas.ts";
import type { InventoryHandlerDeps } from "../../_shared/inventory_handler.ts";

export function handleReleaseReservation(
  req: Request,
  deps?: InventoryHandlerDeps,
): Promise<Response> {
  return handleInventoryRpc(
    req,
    "release_reservation",
    ReleaseReservationRequest,
    (input) => input.company_id as string,
    deps,
  );
}

if (import.meta.main) {
  Deno.serve(handleReleaseReservation);
}
