// Edge Function: catalog/deactivate-category
// (source: RC2, D10, D12 — EF contracts)
//
// 8-step pattern: CORS → Auth → Input → RPC → Return
// Invokes deactivate_category(JSONB) SECURITY DEFINER RPC

import { handleCatalogRpc } from "../../_shared/catalog_handler.ts";
import { DeactivateCategoryRequest } from "../../_shared/catalog_schemas.ts";
import type { DeactivateResult } from "../../_shared/catalog_schemas.ts";

Deno.serve(async (req: Request): Promise<Response> => {
  return handleCatalogRpc<DeactivateResult>(
    req,
    "deactivate_category",
    DeactivateCategoryRequest,
    (input) => input.company_id as string,
  );
});