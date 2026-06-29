// Edge Function: return-sale-item
// Admin-only: process item-level sale returns with destination routing.
// Follows the 8-step critical-op pattern via the shared return handler.
// (source: RR6, D6)

import { handleReturnSaleItem } from "../_shared/return_handler.ts";
import type { ReturnHandlerDeps } from "../_shared/return_handler.ts";

export { handleReturnSaleItem };

if (import.meta.main) {
  Deno.serve((req: Request) => handleReturnSaleItem(req));
}
