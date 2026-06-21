// Deno test: catalog set-variant-price EF
// (source: RC5, PR3 corrective follow-up — Test specs)
//
// Tests Zod input validation for set_variant_price EF invocation.
// Extends catalog_set_price.test.ts with additional coverage for
// the EF request shape and edge cases specifically relevant to
// the set-variant-price Edge Function.

import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { SetVariantPriceRequest } from "../_shared/catalog_schemas.ts";

// ---------------------------------------------------------------------------
// Additional Zod schema validation tests for set-variant-price EF
// ---------------------------------------------------------------------------

Deno.test("SetVariantPriceRequest: explicit effective_from passes validation", () => {
  const input = {
    company_id: "00000000-0000-0000-0000-000000000001",
    variant_id: "00000000-0000-0000-0000-000000000020",
    price: 150.00,
    currency: "USD",
    effective_from: "2026-07-01T00:00:00Z",
  };
  const result = SetVariantPriceRequest.safeParse(input);
  assertEquals(result.success, true);
  if (result.success) {
    assertEquals(result.data.effective_from, "2026-07-01T00:00:00Z");
    assertEquals(result.data.currency, "USD");
  }
});

Deno.test("SetVariantPriceRequest: price as integer passes validation", () => {
  const input = {
    company_id: "00000000-0000-0000-0000-000000000001",
    variant_id: "00000000-0000-0000-0000-000000000020",
    price: 100,
  };
  const result = SetVariantPriceRequest.safeParse(input);
  assertEquals(result.success, true);
});

Deno.test("SetVariantPriceRequest: extra keys are stripped", () => {
  const input = {
    company_id: "00000000-0000-0000-0000-000000000001",
    variant_id: "00000000-0000-0000-0000-000000000020",
    price: 50,
    extra_field: "should be stripped",
  };
  const result = SetVariantPriceRequest.safeParse(input);
  assertEquals(result.success, true);
  if (result.success) {
    assertEquals("extra_field" in result.data, false);
  }
});

Deno.test("SetVariantPriceRequest: string price fails validation", () => {
  const result = SetVariantPriceRequest.safeParse({
    company_id: "00000000-0000-0000-0000-000000000001",
    variant_id: "00000000-0000-0000-0000-000000000020",
    price: "fifty",
  });
  assertEquals(result.success, false);
});

Deno.test("SetVariantPriceRequest: empty company_id UUID fails", () => {
  const result = SetVariantPriceRequest.safeParse({
    company_id: "",
    variant_id: "00000000-0000-0000-0000-000000000020",
    price: 10,
  });
  assertEquals(result.success, false);
});