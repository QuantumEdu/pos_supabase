// Edge Function: cash-session/close-session
// Supports cashier/admin callers while preserving SQL close-own semantics.

import { handleCashSessionRpc } from "../../_shared/cash_session_handler.ts";
import type { CashSessionHandlerDeps } from "../../_shared/cash_session_handler.ts";
import {
  CloseCashSessionRequest,
} from "../../_shared/cash_session_schemas.ts";
import type { CloseCashSessionResult } from "../../_shared/cash_session_schemas.ts";

export function handleCloseCashSession(
  req: Request,
  deps?: CashSessionHandlerDeps,
): Promise<Response> {
  return handleCashSessionRpc<CloseCashSessionResult>(
    req,
    "close_cash_session",
    CloseCashSessionRequest,
    ["cashier", "admin"],
    deps,
  );
}

if (import.meta.main) {
  Deno.serve(handleCloseCashSession);
}
