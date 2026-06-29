// Edge Function: cash-session/record-manual-movement
// Supports cashier/admin callers through the shared cash-session handler.

import { handleCashSessionRpc } from "../../_shared/cash_session_handler.ts";
import type { CashSessionHandlerDeps } from "../../_shared/cash_session_handler.ts";
import {
  RecordManualMovementRequest,
} from "../../_shared/cash_session_schemas.ts";
import type { ManualCashMovementResult } from "../../_shared/cash_session_schemas.ts";

export function handleRecordManualMovement(
  req: Request,
  deps?: CashSessionHandlerDeps,
): Promise<Response> {
  return handleCashSessionRpc<ManualCashMovementResult>(
    req,
    "record_cash_movement",
    RecordManualMovementRequest,
    ["cashier", "admin"],
    deps,
  );
}

if (import.meta.main) {
  Deno.serve((req: Request) => handleRecordManualMovement(req));
}
