// Deno test: catalog set-variant-price EF
// (source: RC5, D12 — Test specs)
//
// Tests Zod input validation for set_variant_price.

import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { SetVariantPriceRequest } from "../_shared/catalog_schemas.ts";

// ---------------------------------------------------------------------------
// Zod schema validation tests
// ---------------------------------------------------------------------------

Deno.test("SetVariantPriceRequest: valid input passes validation", () => {
  const input = {
    company_id: "00000000-0000-0000-0000-000000000001",
    variant_id: "00000000-0000-0000-0000-000000000020",
    price: 25.99,
  };
  const result = SetVariantPriceRequest.safeParse(input);
  assertEquals(result.success, true);
  if (result.success) {
    assertEquals(result.data.price, 25.99);
    assertEquals(result.data.currency, "MXN"); // default
  }
});

Deno.test("SetVariantPriceRequest: explicit currency and effective_from pass", () => {
  const input = {
    company_id: "00000000-0000-0000-0000-000000000001",
    variant_id: "00000000-0000-0000-0000-000000000020",
    price: 100,
    currency: "USD",
    effective_from: "2026-06-15T10:00:00Z",
  };
  const result = SetVariantPriceRequest.safeParse(input);
  assertEquals(result.success, true);
  if (result.success) {
    assertEquals(result.data.currency, "USD");
    assertEquals(result.data.effective_from, "2026-06-15T10:00:00Z");
  }
});

Deno.test("SetVariantPriceRequest: missing required fields fail", () => {
  // Missing price
  const noPrice = SetVariantPriceRequest.safeParse({
    company_id: "00000000-0000-0000-0000-000000000001",
    variant_id: "00000000-0000-0000-0000-000000000020",
  });
  assertEquals(noPrice.success, false);

  // Missing variant_id
  const noVariant = SetVariantPriceRequest.safeParse({
    company_id: "00000000-0000-0000-0000-000000000001",
    price: 10,
  });
  assertEquals(noVariant.success, false);

  // Missing company_id
  const noCompany = SetVariantPriceRequest.safeParse({
    variant_id: "00000000-0000-0000-0000-000000000020",
    price: 10,
  });
  assertEquals(noCompany.success, false);
});

Deno.test("SetVariantPriceRequest: negative price fails validation", () => {
  const result = SetVariantPriceRequest.safeParse({
    company_id: "00000000-0000-0000-0000-000000000001",
    variant_id: "00000000-0000-0000-0000-000000000020",
    price: -1,
  });
  assertEquals(result.success, false);
});

Deno.test("SetVariantPriceRequest: zero price fails validation", () => {
  const result = SetVariantPriceRequest.safeParse({
    company_id: "00000000-0000-0000-0000-000000000001",
    variant_id: "00000000-0000-0000-0000-000000000020",
    price: 0,
  });
  assertEquals(result.success, false);
});

Deno.test("SetVariantPriceRequest: invalid variant_id UUID fails", () => {
  const result = SetVariantPriceRequest.safeParse({
    company_id: "00000000-0000-0000-0000-000000000001",
    variant_id: "not-a-uuid",
    price: 10,
  });
  assertEquals(result.success, false);
});