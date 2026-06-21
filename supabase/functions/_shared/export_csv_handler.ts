// Shared handler for CSV export Edge Function.
// Calls fn_export_entities RPC and streams CSV or returns JSON.
// Follows the 8-step critical-op pattern:
//   1. CORS preflight
//   2. validateAuth → AuthContext
//   3. Role check → admin only
//   4. Validate input (entity, format, filters)
//   5. Call fn_export_entities RPC with service_role
//   6. Convert to CSV streaming response or JSON
//   7. (audit logging — future)
//   8. Return response with proper Content-Type
// (source: RR25, D6)

import { createClient } from "@supabase/supabase-js";
import { corsHeaders } from "./cors.ts";
import { validateAuth } from "./auth.ts";
import { fail } from "./types.ts";
import type { AuthContext } from "./auth.ts";

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

export type ExportCsvRequest = {
  entity: string;
  format?: "json" | "csv";
  filters?: Record<string, unknown>;
};

type RpcClient = {
  rpc(
    fnName: string,
    args: Record<string, unknown>,
  ): Promise<{ data: unknown; error: { code?: string; message: string } | null }>;
};

export type ExportCsvHandlerDeps = {
  validateAuth?: (req: Request, requiredRole: string | string[]) => Promise<AuthContext>;
  createServiceClient?: () => RpcClient | null;
};

// ---------------------------------------------------------------------------
// Default service client factory
// ---------------------------------------------------------------------------

export function createServiceClient(): RpcClient | null {
  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");

  if (!supabaseUrl || !supabaseServiceKey) {
    return null;
  }

  return createClient(supabaseUrl, supabaseServiceKey);
}

// ---------------------------------------------------------------------------
// Handler
// ---------------------------------------------------------------------------

export async function handleExportCsv(
  req: Request,
  deps: ExportCsvHandlerDeps = {},
): Promise<Response> {
  const authValidator = deps.validateAuth ?? validateAuth;
  const serviceClientFactory = deps.createServiceClient ?? createServiceClient;

  // Step 1: CORS preflight
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    // Step 2-3: Validate auth + role (admin only)
    const auth = await authValidator(req, "admin");

    // Step 4: Validate input
    const body = await req.json().catch(() => null);
    if (!body || typeof body.entity !== "string" || !body.entity.trim()) {
      return Response.json(
        fail("VALIDATION_ERROR", "Missing or invalid 'entity' field"),
        { status: 400, headers: corsHeaders },
      );
    }

    const entity = body.entity.trim();
    const format: "json" | "csv" = body.format === "csv" ? "csv" : "json";
    const filters: Record<string, unknown> = body.filters ?? {};

    // Step 5: Call fn_export_entities RPC
    const client = serviceClientFactory();
    if (!client) {
      return Response.json(
        fail("SERVER_ERROR", "Missing Supabase service configuration"),
        { status: 500, headers: corsHeaders },
      );
    }

    const { data, error } = await client.rpc("fn_export_entities", {
      p_company_id: auth.companyId,
      p_entity: entity,
      p_format: format,
      p_filters: filters,
    });

    if (error) {
      return Response.json(
        fail(error.code || "RPC_ERROR", error.message),
        { status: 400, headers: corsHeaders },
      );
    }

    // Step 6: Format response
    const result = data as Record<string, unknown>;

    if (!result || result.success === false) {
      const err = result as { code?: string; message?: string };
      return Response.json(
        fail(err.code || "RPC_ERROR", err.message || "Export failed"),
        { status: 400, headers: corsHeaders },
      );
    }

    // Step 6a: CSV format — stream with Content-Disposition
    if (format === "csv" && result.format === "csv") {
      const csvContent = result.data as string;
      const filename = `${entity}_${new Date().toISOString().slice(0, 10)}.csv`;

      return new Response(csvContent, {
        status: 200,
        headers: {
          "Content-Type": "text/csv; charset=utf-8",
          "Content-Disposition": `attachment; filename="${filename}"`,
          ...corsHeaders,
        },
      });
    }

    // Step 6b: JSON format
    return Response.json(
      { success: true, data: result.data, format: result.format },
      { headers: corsHeaders },
    );
  } catch (error) {
    // Step 7: (audit logging — future)
    if (error instanceof Response) {
      return error;
    }
    // Step 8: Return error
    return Response.json(
      fail("SERVER_ERROR", error instanceof Error ? error.message : "Unknown error"),
      { status: 500, headers: corsHeaders },
    );
  }
}
