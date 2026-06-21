// Shared type definitions for Supabase Edge Functions
// (source: D12 — EF layout and contracts)
//
// Standard result wrapper used by all Edge Functions.
// Every EF MUST return EFResult<T> as the response body shape.

/** Standard result wrapper for all Edge Function responses */
export type EFResult<T> = {
  success: boolean;
  data?: T;
  error?: {
    code: string;
    message: string;
  };
};

/** Convenience constructor for a successful EFResult */
export function ok<T>(data: T): EFResult<T> {
  return { success: true, data };
}

/** Convenience constructor for a failed EFResult */
export function fail(
  code: string,
  message: string,
): EFResult<never> {
  return { success: false, error: { code, message } };
}