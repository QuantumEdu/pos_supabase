// Deno test: catalog deactivate-product EF
// (source: RC4, D12 — Test specs)
//
// Tests Zod input validation for deactivate-product.

import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { DeactivateProductRequest } from "../_shared/catalog_schemas.ts";

// ---------------------------------------------------------------------------
// Zod schema validation tests
// ---------------------------------------------------------------------------

Deno.test("DeactivateProductRequest: valid input passes validation", () => {
  const input = {
    company_id: "00000000-0000-0000-0000-000000000001",
    product_id: "00000000-0000-0000-0000-000000000010",
  };
  const result = DeactivateProductRequest.safeParse(input);
  assertEquals(result.success, true);
  if (result.success) {
    assertEquals(result.data.company_id, "00000000-0000-0000-0000-000000000001");
    assertEquals(result.data.product_id, "00000000-0000-0000-0000-000000000010");
  }
});

Deno.test("DeactivateProductRequest: missing product_id fails", () => {
  const result = DeactivateProductRequest.safeParse({
    company_id: "00000000-0000-0000-0000-000000000001",
  });
  assertEquals(result.success, false);
});

Deno.test("DeactivateProductRequest: invalid UUID fails", () => {
  const result = DeactivateProductRequest.safeParse({
    company_id: "not-a-uuid",
    product_id: "also-not-a-uuid",
  });
  assertEquals(result.success, false);
});

Deno.test("DeactivateProductRequest: extra keys are stripped by Zod", () => {
  const input = {
    company_id: "00000000-0000-0000-0000-000000000001",
    product_id: "00000000-0000-0000-0000-000000000010",
    extra_key: "should be ignored",
  };
  const result = DeactivateProductRequest.safeParse(input);
  // Zod object schemas strip unknown keys by default
  assertEquals(result.success, true);
  if (result.success) {
    assertEquals(Object.keys(result.data).length, 2);
  }
});