// Edge Function: cash-session/open-session
// Supports cashier self-open and admin open-for-cashier through the shared handler.

import { handleCashSessionRpc } from "../../_shared/cash_session_handler.ts";
import type { CashSessionHandlerDeps } from "../../_shared/cash_session_handler.ts";
import {
  OpenCashSessionRequest,
} from "../../_shared/cash_session_schemas.ts";
import type { OpenCashSessionResult } from "../../_shared/cash_session_schemas.ts";

export function handleOpenCashSession(
  req: Request,
  deps?: CashSessionHandlerDeps,
): Promise<Response> {
  return handleCashSessionRpc<OpenCashSessionResult>(
    req,
    "open_cash_session",
    OpenCashSessionRequest,
    ["cashier", "admin"],
    deps,
  );
}

if (import.meta.main) {
  Deno.serve((req: Request) => handleOpenCashSession(req));
}
