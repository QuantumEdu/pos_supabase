// Edge Function: catalog/create-category
// (source: RC2, D10, D12 — EF contracts)
//
// 8-step pattern: CORS → Auth → Input → RPC → Return
// Invokes create_category(JSONB) SECURITY DEFINER RPC

import { handleCatalogRpc } from "../_shared/catalog_handler.ts";
import { CreateCategoryRequest } from "../_shared/catalog_schemas.ts";
import type { CategoryResult } from "../_shared/catalog_schemas.ts";

Deno.serve(async (req: Request): Promise<Response> => {
  return handleCatalogRpc<CategoryResult>(
    req,
    "create_category",
    CreateCategoryRequest,
    (input) => input.company_id as string,
  );
});