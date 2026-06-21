// Edge Function: catalog/update-brand
// (source: RC1, D10, D12 — EF contracts)
//
// 8-step pattern: CORS → Auth → Input → RPC → Return
// Invokes update_brand(JSONB) SECURITY DEFINER RPC

import { handleCatalogRpc } from "../_shared/catalog_handler.ts";
import { UpdateBrandRequest } from "../_shared/catalog_schemas.ts";
import type { UpdateResult } from "../_shared/catalog_schemas.ts";

Deno.serve(async (req: Request): Promise<Response> => {
  return handleCatalogRpc<UpdateResult>(
    req,
    "update_brand",
    UpdateBrandRequest,
    (input) => input.company_id as string,
  );
});