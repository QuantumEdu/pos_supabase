// Edge Function: catalog/deactivate-unit
// (source: RC3, D10, D12 — EF contracts)
//
// 8-step pattern: CORS → Auth → Input → RPC → Return
// Invokes deactivate_unit(JSONB) SECURITY DEFINER RPC

import { handleCatalogRpc } from "../../_shared/catalog_handler.ts";
import { DeactivateUnitRequest } from "../../_shared/catalog_schemas.ts";
import type { DeactivateResult } from "../../_shared/catalog_schemas.ts";

Deno.serve(async (req: Request): Promise<Response> => {
  return handleCatalogRpc<DeactivateResult>(
    req,
    "deactivate_unit",
    DeactivateUnitRequest,
    (input) => input.company_id as string,
  );
});