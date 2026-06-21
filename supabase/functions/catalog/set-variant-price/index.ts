// Edge Function: catalog/set-variant-price
// (source: RC5, D12 — EF contracts, PR3 corrective follow-up)
//
// 8-step pattern: CORS → Auth → Input → RPC → Return
// Invokes set_variant_price(JSONB) SECURITY DEFINER RPC

import { corsHeaders } from "../../_shared/cors.ts";
import { validateAuth } from "../../_shared/auth.ts";
import { ok, fail } from "../../_shared/types.ts";
import type { EFResult } from "../../_shared/types.ts";
import { SetVariantPriceRequest } from "../../_shared/catalog_schemas.ts";
import type { SetPriceResult } from "../../_shared/catalog_schemas.ts";
import { createClient } from "@supabase/supabase-js";

Deno.serve(async (req: Request): Promise<Response> => {
  // Step 1: Handle CORS preflight
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    // Step 2-4: Validate auth (admin role required)
    const auth = await validateAuth(req, "admin");

    // Step 5: Validate input via Zod
    const body = await req.json();
    const parsed = SetVariantPriceRequest.safeParse(body);
    if (!parsed.success) {
      const message = parsed.error.issues.map((i) => i.message).join("; ");
      return Response.json(
        fail("VALIDATION_ERROR", message),
        { status: 400, headers: corsHeaders },
      );
    }
    const input = parsed.data;

    // Verify auth company matches request company_id
    if (input.company_id !== auth.companyId) {
      return Response.json(
        fail("FORBIDDEN", "company_id does not match authenticated user"),
        { status: 403, headers: corsHeaders },
      );
    }

    // Step 6: Invoke RPC via service_role client
    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (!supabaseUrl || !supabaseServiceKey) {
      return Response.json(
        fail("SERVER_ERROR", "Missing Supabase service configuration"),
        { status: 500, headers: corsHeaders },
      );
    }

    const serviceClient = createClient(supabaseUrl, supabaseServiceKey);
    const { data, error } = await serviceClient.rpc(
      "set_variant_price",
      {
        p: {
          company_id: input.company_id,
          variant_id: input.variant_id,
          price: input.price,
          currency: input.currency,
          effective_from: input.effective_from ?? null,
        },
      },
    );

    if (error) {
      return Response.json(
        fail(error.code || "RPC_ERROR", error.message),
        { status: 400, headers: corsHeaders },
      );
    }

    // Step 8: Return EFResult<SetPriceResult>
    return Response.json(
      ok(data as SetPriceResult),
      { headers: corsHeaders },
    );
  } catch (err) {
    // validateAuth throws Response with EFResult error body
    if (err instanceof Response) return err;
    return Response.json(
      fail("SERVER_ERROR", err instanceof Error ? err.message : "Unknown error"),
      { status: 500, headers: corsHeaders },
    );
  }
});