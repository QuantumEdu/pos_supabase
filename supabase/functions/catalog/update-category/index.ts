// Edge Function: catalog/update-category
// (source: RC2, D10, D12 — EF contracts)
//
// 8-step pattern: CORS → Auth → Input → RPC → Return
// Invokes update_category(JSONB) SECURITY DEFINER RPC

import { handleCatalogRpc } from "../../_shared/catalog_handler.ts";
import { UpdateCategoryRequest } from "../../_shared/catalog_schemas.ts";
import type { UpdateResult } from "../../_shared/catalog_schemas.ts";

Deno.serve(async (req: Request): Promise<Response> => {
  return handleCatalogRpc<UpdateResult>(
    req,
    "update_category",
    UpdateCategoryRequest,
    (input) => input.company_id as string,
  );
});