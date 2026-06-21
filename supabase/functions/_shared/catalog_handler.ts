// Shared helper for invoking catalog RPCs from Edge Functions
// (source: D10, D12 — EF→RPC pattern)
//
// All catalog CRUD EFs follow the same 8-step pattern:
//   1. CORS preflight
//   2-4. Auth validation (admin)
//   5. Input validation (Zod)
//   6. RPC invocation via service_role
//   7. Audit (log-level)
//   8. Return EFResult<T>
//
// This helper centralizes step 6 (RPC invocation) and the service client setup,
// reducing duplication across the 9 CRUD EFs.

import { createClient } from "@supabase/supabase-js";
import { fail } from "./types.ts";
import type { EFResult } from "./types.ts";
import { corsHeaders } from "./cors.ts";
import { validateAuth } from "./auth.ts";
import type { AuthContext } from "./auth.ts";
import type { ZodSchema, ZodIssue } from "https://esm.sh/zod@3";

// ---------------------------------------------------------------------------
// Service client factory
// ---------------------------------------------------------------------------

/** Create a Supabase service_role client for RPC invocation */
export function createServiceClient() {
  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !supabaseServiceKey) {
    return null;
  }
  return createClient(supabaseUrl, supabaseServiceKey);
}

// ---------------------------------------------------------------------------
// Generic catalog EF handler
// ---------------------------------------------------------------------------

/**
 * Generic handler for catalog CRUD Edge Functions.
 * Centralizes the common 8-step pattern so each EF only provides
 * its Zod schema and RPC details.
 *
 * @param req - Incoming Request
 * @param rpcName - Name of the SECURITY DEFINER RPC to invoke
 * @param schema - Zod schema for input validation
 * @param companyField - Extract company_id from parsed input for auth check
 * @returns Response with EFResult<T>
 */
export async function handleCatalogRpc<T>(
  req: Request,
  rpcName: string,
  schema: ZodSchema,
  companyField: (input: Record<string, unknown>) => string,
): Promise<Response> {
  // Step 1: CORS preflight
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    // Step 2-4: Auth validation (admin)
    const auth: AuthContext = await validateAuth(req, "admin");

    // Step 5: Input validation via Zod
    const body = await req.json();
    const parsed = schema.safeParse(body);
    if (!parsed.success) {
      const message = parsed.error.issues.map((i: ZodIssue) => i.message).join("; ");
      return Response.json(
        fail("VALIDATION_ERROR", message),
        { status: 400, headers: corsHeaders },
      );
    }
    const input = parsed.data as Record<string, unknown>;

    // Verify auth company matches request company_id
    const inputCompanyId = companyField(input);
    if (inputCompanyId !== auth.companyId) {
      return Response.json(
        fail("FORBIDDEN", "company_id does not match authenticated user"),
        { status: 403, headers: corsHeaders },
      );
    }

    // Step 6: Invoke RPC via service_role client
    const client = createServiceClient();
    if (!client) {
      return Response.json(
        fail("SERVER_ERROR", "Missing Supabase service configuration"),
        { status: 500, headers: corsHeaders },
      );
    }

    const { data, error } = await client.rpc(rpcName, { p: input });

    if (error) {
      return Response.json(
        fail(error.code || "RPC_ERROR", error.message),
        { status: 400, headers: corsHeaders },
      );
    }

    // Step 8: Return EFResult<T>
    return Response.json(
      { success: true, data: data as T },
      { headers: corsHeaders },
    );
  } catch (err) {
    if (err instanceof Response) return err;
    return Response.json(
      fail("SERVER_ERROR", err instanceof Error ? err.message : "Unknown error"),
      { status: 500, headers: corsHeaders },
    );
  }
}