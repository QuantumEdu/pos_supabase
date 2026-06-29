// Edge Function: pos-sales/cancel-sale
// Supports cashier and admin sale cancellation through the shared handler.

import { handlePosSalesRpc } from "../../_shared/pos_sales_handler.ts";
import type { PosSalesHandlerDeps } from "../../_shared/pos_sales_handler.ts";
import { CancelSaleRequest } from "../../_shared/pos_sales_schemas.ts";
import type { CancelSaleResult } from "../../_shared/pos_sales_schemas.ts";

export function handleCancelSale(
  req: Request,
  deps?: PosSalesHandlerDeps,
): Promise<Response> {
  return handlePosSalesRpc<CancelSaleResult>(
    req,
    "cancel_sale_transaction",
    CancelSaleRequest,
    ["cashier", "admin"],
    deps,
  );
}

if (import.meta.main) {
  Deno.serve((req: Request) => handleCancelSale(req));
}
