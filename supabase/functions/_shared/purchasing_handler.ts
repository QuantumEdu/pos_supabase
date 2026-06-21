// Shared helper for invoking purchasing RPCs from Edge Functions
// (source: RP10 — EF→RPC pattern, DP1 — single RPC call)
//
// Centralizes the 8-step pattern: CORS → validateAuth(admin) → Zod parse
// → company_id check → serviceClient.rpc → EFResult response.
// Injectable dependencies for Deno testability.

import { createClient } from "@supabase/supabase-js";
import { corsHeaders } from "./cors.ts";
import { validateAuth } from "./auth.ts";
import { fail } from "./types.ts";
import type { AuthContext } from "./auth.ts";
import type { ZodIssue, ZodSchema } from "https://esm.sh/zod@3";

type RpcError = {
  code?: string;
  message: string;
};

type RpcClient = {
  rpc(
    rpcName: string,
    args: { p: Record<string, unknown> },
  ): Promise<{ data: unknown; error: RpcError | null }>;
};

export type PurchasingHandlerDeps = {
  validateAuth?: (req: Request, requiredRole: string) => Promise<AuthContext>;
  createServiceClient?: () => RpcClient | null;
};

export function createServiceClient(): RpcClient | null {
  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !supabaseServiceKey) {
    return null;
  }
  return createClient(supabaseUrl, supabaseServiceKey);
}

export async function handlePurchasingRpc<T>(
  req: Request,
  rpcName: string,
  schema: ZodSchema,
  companyField: (input: Record<string, unknown>) => string = (input) => input.company_id as string,
  deps: PurchasingHandlerDeps = {},
): Promise<Response> {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  const authValidator = deps.validateAuth ?? validateAuth;
  const serviceClientFactory = deps.createServiceClient ?? createServiceClient;

  try {
    const auth = await authValidator(req, "admin");

    const body = await req.json();
    const parsed = schema.safeParse(body);
    if (!parsed.success) {
      const message = parsed.error.issues.map((issue: ZodIssue) => issue.message).join("; ");
      return Response.json(
        fail("VALIDATION_ERROR", message),
        { status: 400, headers: corsHeaders },
      );
    }

    const input = parsed.data as Record<string, unknown>;
    if (companyField(input) !== auth.companyId) {
      return Response.json(
        fail("FORBIDDEN", "company_id does not match authenticated user"),
        { status: 403, headers: corsHeaders },
      );
    }

    const client = serviceClientFactory();
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

    return Response.json(
      { success: true, data: data as T },
      { headers: corsHeaders },
    );
  } catch (error) {
    if (error instanceof Response) {
      return error;
    }
    return Response.json(
      fail("SERVER_ERROR", error instanceof Error ? error.message : "Unknown error"),
      { status: 500, headers: corsHeaders },
    );
  }
}
