// Edge Function: catalog/deactivate-brand
// (source: RC1, D10, D12 — EF contracts)
//
// 8-step pattern: CORS → Auth → Input → RPC → Return
// Invokes deactivate_brand(JSONB) SECURITY DEFINER RPC

import { handleCatalogRpc } from "../../_shared/catalog_handler.ts";
import { DeactivateBrandRequest } from "../../_shared/catalog_schemas.ts";
import type { DeactivateResult } from "../../_shared/catalog_schemas.ts";

Deno.serve(async (req: Request): Promise<Response> => {
  return handleCatalogRpc<DeactivateResult>(
    req,
    "deactivate_brand",
    DeactivateBrandRequest,
    (input) => input.company_id as string,
  );
});