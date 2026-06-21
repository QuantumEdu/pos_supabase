// Edge Function: catalog/create-unit
// (source: RC3, D10, D12 — EF contracts)
//
// 8-step pattern: CORS → Auth → Input → RPC → Return
// Invokes create_unit(JSONB) SECURITY DEFINER RPC

import { handleCatalogRpc } from "../_shared/catalog_handler.ts";
import { CreateUnitRequest } from "../_shared/catalog_schemas.ts";
import type { UnitResult } from "../_shared/catalog_schemas.ts";

Deno.serve(async (req: Request): Promise<Response> => {
  return handleCatalogRpc<UnitResult>(
    req,
    "create_unit",
    CreateUnitRequest,
    (input) => input.company_id as string,
  );
});