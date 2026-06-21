// Edge Function: pos-sales/create-sale
// Supports cashier self-checkout and admin create-for-cashier through the shared handler.

import { handlePosSalesRpc } from "../../_shared/pos_sales_handler.ts";
import type { PosSalesHandlerDeps } from "../../_shared/pos_sales_handler.ts";
import { CreateSaleRequest } from "../../_shared/pos_sales_schemas.ts";
import type { CreateSaleResult } from "../../_shared/pos_sales_schemas.ts";

export function handleCreateSale(
  req: Request,
  deps?: PosSalesHandlerDeps,
): Promise<Response> {
  return handlePosSalesRpc<CreateSaleResult>(
    req,
    "create_sale_transaction",
    CreateSaleRequest,
    ["cashier", "admin"],
    deps,
  );
}

if (import.meta.main) {
  Deno.serve(handleCreateSale);
}