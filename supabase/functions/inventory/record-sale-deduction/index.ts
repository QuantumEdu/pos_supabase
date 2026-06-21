// Edge Function: inventory/record-sale-deduction
// (source: RI4, RI8 — inventory EF contracts)

import { handleInventoryRpc } from "../../_shared/inventory_handler.ts";
import { RecordSaleDeductionRequest } from "../../_shared/inventory_schemas.ts";
import type { InventoryHandlerDeps } from "../../_shared/inventory_handler.ts";
import type { InventoryBatchMovementResult } from "../../_shared/inventory_schemas.ts";

export function handleRecordSaleDeduction(
  req: Request,
  deps?: InventoryHandlerDeps,
): Promise<Response> {
  return handleInventoryRpc<InventoryBatchMovementResult>(
    req,
    "record_sale_deduction",
    RecordSaleDeductionRequest,
    (input) => input.company_id as string,
    deps,
  );
}

if (import.meta.main) {
  Deno.serve(handleRecordSaleDeduction);
}
