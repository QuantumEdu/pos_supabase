// Edge Function: export-csv
// Admin-only: export entities as CSV (or JSON) via fn_export_entities RPC.
// Follows the 8-step critical-op pattern via the shared export handler.
// (source: RR25, D6)

import { handleExportCsv } from "../_shared/export_csv_handler.ts";

export { handleExportCsv };

if (import.meta.main) {
  Deno.serve(handleExportCsv);
}
