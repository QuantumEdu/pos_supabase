// Edge Function: catalog/create-brand
// (source: RC1, D10, D12 — EF contracts)
//
// 8-step pattern: CORS → Auth → Input → RPC → Return
// Invokes create_brand(JSONB) SECURITY DEFINER RPC

import { handleCatalogRpc } from "../_shared/catalog_handler.ts";
import { CreateBrandRequest } from "../_shared/catalog_schemas.ts";
import type { BrandResult } from "../_shared/catalog_schemas.ts";

Deno.serve(async (req: Request): Promise<Response> => {
  return handleCatalogRpc<BrandResult>(
    req,
    "create_brand",
    CreateBrandRequest,
    (input) => input.company_id as string,
  );
});