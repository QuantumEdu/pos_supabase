// Deno test: export-csv Edge Function (PR4)
// Validates the 8-step critical-op pattern for CSV/JSON export.
// (source: RR25, D6)

import { assertEquals, assertStringIncludes } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { corsHeaders } from "../_shared/cors.ts";
import { handleExportCsv } from "../export-csv/index.ts";
import { AUTH_ERRORS } from "../_shared/auth.ts";
import type { AuthContext } from "../_shared/auth.ts";
import type { ExportCsvHandlerDeps } from "../_shared/export_csv_handler.ts";

// ---------------------------------------------------------------------------
// Test constants
// ---------------------------------------------------------------------------

const COMPANY_ID = "00000000-0000-0000-0000-000000000001";
const ADMIN_ID = "00000000-0000-0000-0000-000000000010";
const VALID_ENTITY = "products";
const INVALID_ENTITY = "nonexistent_entity";

// ---------------------------------------------------------------------------
// Mock deps factory
// ---------------------------------------------------------------------------

function mockAuth(context: Partial<AuthContext> = {}): AuthContext {
  return {
    user: { id: ADMIN_ID },
    companyId: COMPANY_ID,
    role: "admin",
    ...context,
  };
}

function makeDeps(overrides: {
  mockAuthContext?: Partial<AuthContext>;
  rpcResult?: Record<string, unknown>;
  rpcError?: { code?: string; message: string } | null;
  failAuth?: boolean;
} = {}): ExportCsvHandlerDeps {
  const authContext = mockAuth(overrides.mockAuthContext);

  return {
    validateAuth: async (_req, _requiredRole): Promise<AuthContext> => {
      if (overrides.failAuth) {
        throw new Response("Unauthorized", {
          status: 401,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }
      return authContext;
    },
    createServiceClient: () => ({
      rpc: async (_fnName, _args) => {
        if (overrides.rpcError) {
          return { data: null, error: overrides.rpcError };
        }
        return {
          data: overrides.rpcResult ?? { success: true, data: [], format: "json" },
          error: null,
        };
      },
    }),
  };
}

function makeRequest(
  body: Record<string, unknown> | null,
  method = "POST",
): Request {
  return new Request("http://localhost/export-csv", {
    method,
    headers: { "Content-Type": "application/json" },
    body: body !== null ? JSON.stringify(body) : undefined,
  });
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

Deno.test("export-csv: CORS preflight returns ok", async () => {
  const req = new Request("http://localhost/export-csv", { method: "OPTIONS" });
  const res = await handleExportCsv(req, makeDeps());
  assertEquals(res.status, 200);
  const text = await res.text();
  assertEquals(text, "ok");
});

Deno.test("export-csv: auth failure returns 401", async () => {
  const req = makeRequest({ entity: VALID_ENTITY });
  const res = await handleExportCsv(req, makeDeps({ failAuth: true }));
  assertEquals(res.status, 401);
});

Deno.test("export-csv: missing body entity returns 400", async () => {
  const req = makeRequest(null);
  const res = await handleExportCsv(req, makeDeps());
  assertEquals(res.status, 400);
});

Deno.test("export-csv: empty entity string returns 400", async () => {
  const req = makeRequest({ entity: "" });
  const res = await handleExportCsv(req, makeDeps());
  assertEquals(res.status, 400);
});

Deno.test("export-csv: valid products CSV returns 200 with correct headers", async () => {
  const csvData = "id,name,sku\n1,Widget A,WGT-001";
  const req = makeRequest({ entity: VALID_ENTITY, format: "csv" });
  const res = await handleExportCsv(req, makeDeps({
    rpcResult: { success: true, data: csvData, format: "csv" },
  }));

  assertEquals(res.status, 200);
  assertEquals(res.headers.get("Content-Type"), "text/csv; charset=utf-8");
  assertStringIncludes(res.headers.get("Content-Disposition")!, "filename=");
  assertStringIncludes(res.headers.get("Content-Disposition")!, ".csv");
  const body = await res.text();
  assertStringIncludes(body, "WGT-001");
});

Deno.test("export-csv: valid products JSON returns 200 with data", async () => {
  const jsonData = [{ id: 1, name: "Widget A", sku: "WGT-001" }];
  const req = makeRequest({ entity: VALID_ENTITY, format: "json" });
  const res = await handleExportCsv(req, makeDeps({
    rpcResult: { success: true, data: jsonData, format: "json" },
  }));

  assertEquals(res.status, 200);
  const body = await res.json();
  assertEquals(body.success, true);
  assertEquals(body.data[0].sku, "WGT-001");
});

Deno.test("export-csv: invalid entity returns RPC error", async () => {
  const req = makeRequest({ entity: INVALID_ENTITY });
  const res = await handleExportCsv(req, makeDeps({
    rpcResult: { success: false, code: "UNKNOWN_ENTITY", message: "unknown entity: nonexistent_entity" },
  }));

  assertEquals(res.status, 400);
  const body = await res.json();
  assertEquals(body.error.code, "UNKNOWN_ENTITY");
});

Deno.test("export-csv: RPC network error returns 400", async () => {
  const req = makeRequest({ entity: VALID_ENTITY });
  const res = await handleExportCsv(req, makeDeps({
    rpcError: { code: "CONNECTION_ERROR", message: "Cannot connect to database" },
  }));

  assertEquals(res.status, 400);
  const body = await res.json();
  assertEquals(body.error.code, "CONNECTION_ERROR");
});

Deno.test("export-csv: cross-tenant company_id is rejected", async () => {
  const req = makeRequest({ entity: VALID_ENTITY });
  const res = await handleExportCsv(req, makeDeps({
    mockAuthContext: { companyId: "00000000-0000-0000-0000-000000000099" },
    rpcResult: { success: false, code: "CROSS_TENANT", message: "company_id mismatch" },
  }));

  assertEquals(res.status, 400);
  const body = await res.json();
  assertEquals(body.error.code, "CROSS_TENANT");
});

Deno.test("export-csv: non-admin role is rejected", async () => {
  const req = makeRequest({ entity: VALID_ENTITY });
  const deps: ExportCsvHandlerDeps = {
    validateAuth: async (_req, requiredRole): Promise<AuthContext> => {
      const allowed = Array.isArray(requiredRole) ? requiredRole : [requiredRole];
      if (!allowed.includes("cashier")) {
        throw new Response(JSON.stringify({
          success: false,
          error: { code: "FORBIDDEN", message: "Insufficient permissions" },
        }), {
          status: 403,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }
      return mockAuth();
    },
  };
  const res = await handleExportCsv(req, deps);
  assertEquals(res.status, 403);
});
