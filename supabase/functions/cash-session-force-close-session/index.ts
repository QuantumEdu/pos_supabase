// Edge Function: cash-session/force-close-session
// Admin-only force close path through the shared cash-session handler.

import { handleCashSessionRpc } from "../_shared/cash_session_handler.ts";
import type { CashSessionHandlerDeps } from "../_shared/cash_session_handler.ts";
import {
  ForceCloseCashSessionRequest,
} from "../_shared/cash_session_schemas.ts";
import type { ForceCloseCashSessionResult } from "../_shared/cash_session_schemas.ts";

export function handleForceCloseCashSession(
  req: Request,
  deps?: CashSessionHandlerDeps,
): Promise<Response> {
  return handleCashSessionRpc<ForceCloseCashSessionResult>(
    req,
    "force_close_cash_session",
    ForceCloseCashSessionRequest,
    ["admin"],
    deps,
  );
}

if (import.meta.main) {
  Deno.serve(handleForceCloseCashSession);
}
