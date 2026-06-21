// Auth validation helper for Supabase Edge Functions
// (source: D3 — 8-step authorization pattern, D12 — EF layout and contracts)
//
// Implements steps 2-4 of the D3 8-step pattern:
//   Step 2: Validate JWT → extract user
//   Step 3: Validate company membership → extract company_id
//   Step 4: Validate role → check authorization
//
// Steps 1 (CORS), 5 (input), 6 (RPC), 7 (audit), 8 (return) are the
// calling EF's responsibility. This helper returns the auth context
// or throws a Response with an EFResult error body.

import { createClient } from "@supabase/supabase-js";
import { corsHeaders } from "./cors.ts";
import type { EFResult } from "./types.ts";

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

/** Auth context returned by validateAuth on success */
export type AuthContext = {
  user: {
    id: string;
    email?: string;
  };
  companyId: string;
  role: string;
};

/** Standard error descriptors for auth validation failures */
export const AUTH_ERRORS = {
  NO_AUTH_HEADER: {
    code: "UNAUTHORIZED",
    message: "Missing Authorization header",
  },
  INVALID_TOKEN: {
    code: "UNAUTHORIZED",
    message: "Invalid or expired token",
  },
  NO_COMPANY: {
    code: "FORBIDDEN",
    message: "User is not associated with a company",
  },
  INSUFFICIENT_ROLE: {
    code: "FORBIDDEN",
    message: "Insufficient permissions",
  },
} as const;

// ---------------------------------------------------------------------------
// validateAuth — D3 steps 2-4
// ---------------------------------------------------------------------------

/**
 * Validate authentication for an Edge Function request.
 *
 * Extracts the JWT from the Authorization header, verifies it with
 * Supabase Auth, then checks company membership and role.
 *
 * @param req - The incoming Request object (from Deno.serve handler)
 * @param requiredRole - The minimum role required (e.g. "admin")
 * @returns AuthContext with user, companyId, and role
 * @throws Response with EFResult error JSON body (401/403) on failure
 */
export async function validateAuth(
  req: Request,
  requiredRole: string | string[],
): Promise<AuthContext> {
  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY");

  if (!supabaseUrl || !supabaseAnonKey) {
    throw errorResponse(500, {
      code: "SERVER_ERROR",
      message: "Missing Supabase environment configuration",
    });
  }

  // Step 2: Extract and validate JWT
  const authHeader = req.headers.get("Authorization");
  if (!authHeader) {
    throw errorResponse(401, AUTH_ERRORS.NO_AUTH_HEADER);
  }

  const token = authHeader.replace(/^Bearer\s+/i, "");
  if (!token) {
    throw errorResponse(401, AUTH_ERRORS.NO_AUTH_HEADER);
  }

  const supabase = createClient(supabaseUrl, supabaseAnonKey);
  const { data: { user }, error: authError } = await supabase.auth.getUser(token);

  if (authError || !user) {
    throw errorResponse(401, AUTH_ERRORS.INVALID_TOKEN);
  }

  // Step 3: Validate company membership
  const companyId = user.app_metadata?.company_id as string | undefined;
  if (!companyId) {
    throw errorResponse(403, AUTH_ERRORS.NO_COMPANY);
  }

  // Step 4: Validate role
  const role = user.app_metadata?.role as string | undefined;
  const allowedRoles = Array.isArray(requiredRole) ? requiredRole : [requiredRole];
  if (!role || !allowedRoles.includes(role)) {
    throw errorResponse(403, AUTH_ERRORS.INSUFFICIENT_ROLE);
  }

  return {
    user: { id: user.id, email: user.email ?? undefined },
    companyId,
    role,
  };
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

/** Build an HTTP Response with an EFResult error JSON body */
export function errorResponse(
  status: number,
  error: { code: string; message: string },
): Response {
  const body: EFResult<never> = { success: false, error };
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "Content-Type": "application/json",
      ...corsHeaders,
    },
  });
}
