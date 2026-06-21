// Edge Function: pos-sales/authorize-discount
// Admin-only discount authorization through the shared handler.

import { handlePosSalesRpc } from "../../_shared/pos_sales_handler.ts";
import type { PosSalesHandlerDeps } from "../../_shared/pos_sales_handler.ts";
import { AuthorizeDiscountRequest } from "../../_shared/pos_sales_schemas.ts";
import type { AuthorizeDiscountResult } from "../../_shared/pos_sales_schemas.ts";

export function handleAuthorizeDiscount(
  req: Request,
  deps?: PosSalesHandlerDeps,
): Promise<Response> {
  return handlePosSalesRpc<AuthorizeDiscountResult>(
    req,
    "authorize_discount",
    AuthorizeDiscountRequest,
    ["admin"],
    deps,
  );
}

if (import.meta.main) {
  Deno.serve(handleAuthorizeDiscount);
}