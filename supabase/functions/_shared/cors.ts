// CORS headers for Supabase Edge Functions
// (source: D3, D5 — Edge Function authorization pattern)
//
// This helper provides the minimum CORS headers required for
// SPA clients to call Edge Functions from a different origin.
// For @supabase/supabase-js v2.95.0+, prefer importing from
// '@supabase/supabase-js/cors' directly. This file serves as
// a fallback for local development and earlier SDK versions.

export const corsHeaders: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};