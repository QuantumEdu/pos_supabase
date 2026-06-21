// Health Edge Function
// (source: D3 — 8-step validation pattern, D6 — local dev workflow)
//
// This is a scaffold health-check function verifying the Edge Function
// runtime pattern. It follows the D3 authorization sequence where
// applicable (steps 1-8). For this health endpoint, only steps 1-2
// and 8 are relevant since it performs no critical operations.

import { corsHeaders } from "../_shared/cors.ts";

Deno.serve(async (req: Request) => {
  // Step D3.1: Handle CORS preflight
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    // Step D3.1: Validate user (optional for health check)
    // const authHeader = req.headers.get("Authorization");
    // if (!authHeader) { ... }

    // Step D3.8: Return consistent result
    return Response.json(
      {
        success: true,
        data: {
          status: "healthy",
          service: "pos-supabase-edge-functions",
          timestamp: new Date().toISOString(),
        },
      },
      { headers: corsHeaders },
    );
  } catch (error) {
    return Response.json(
      {
        success: false,
        error: {
          code: "HEALTH_CHECK_ERROR",
          message: error instanceof Error ? error.message : "Unknown error",
        },
      },
      { status: 500, headers: corsHeaders },
    );
  }
});