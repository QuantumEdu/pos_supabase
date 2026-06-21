// Edge Function: purchasing/manage-supplier
// (source: RP1, RP10 — supplier CRUD, admin-only)
//
// Invokes manage_supplier(JSONB) SECURITY DEFINER RPC.
// Routes action: create | update | deactivate.
// Logical deletion via deactivate; no physical DELETE.

import { handlePurchasingRpc } from "../../_shared/purchasing_handler.ts";
import type { PurchasingHandlerDeps } from "../../_shared/purchasing_handler.ts";
import { ManageSupplierRequest } from "../../_shared/purchasing_schemas.ts";
import type { SupplierResult } from "../../_shared/purchasing_schemas.ts";

export function handleManageSupplier(
  req: Request,
  deps?: PurchasingHandlerDeps,
): Promise<Response> {
  return handlePurchasingRpc<SupplierResult>(
    req,
    "manage_supplier",
    ManageSupplierRequest,
    (input) => input.company_id as string,
    deps,
  );
}

if (import.meta.main) {
  Deno.serve(handleManageSupplier);
}
