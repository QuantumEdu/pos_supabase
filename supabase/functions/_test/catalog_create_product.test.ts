// Deno test: catalog create-product EF
// (source: RC4, RC5, D12 — Test specs)
//
// Tests Zod input validation and EFResult shapes.
// Integration tests requiring a running Supabase instance are
// marked with { sanitizeResources: false, sanitizeOps: false } and
// are only actionable when SUPABASE_URL and SUPABASE_ANON_KEY are available.

import { assertEquals, assertExists } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { CreateProductRequest, DeactivateProductRequest } from "../_shared/catalog_schemas.ts";

// ---------------------------------------------------------------------------
// Zod schema validation tests
// ---------------------------------------------------------------------------

Deno.test("CreateProductRequest: valid input passes validation", () => {
  const input = {
    company_id: "00000000-0000-0000-0000-000000000001",
    name: "Test Product",
    slug: "test-product",
    variant_name: "Default",
    price: 99.99,
  };
  const result = CreateProductRequest.safeParse(input);
  assertEquals(result.success, true);
  if (result.success) {
    assertEquals(result.data.name, "Test Product");
    assertEquals(result.data.currency, "MXN"); // default
    assertEquals(result.data.price, 99.99);
  }
});

Deno.test("CreateProductRequest: missing required fields fail validation", () => {
  // Missing name
  const missingName = CreateProductRequest.safeParse({
    company_id: "00000000-0000-0000-0000-000000000001",
    slug: "test-product",
    variant_name: "Default",
    price: 10,
  });
  assertEquals(missingName.success, false);

  // Missing slug
  const missingSlug = CreateProductRequest.safeParse({
    company_id: "00000000-0000-0000-0000-000000000001",
    name: "Test Product",
    variant_name: "Default",
    price: 10,
  });
  assertEquals(missingSlug.success, false);

  // Missing variant_name
  const missingVariant = CreateProductRequest.safeParse({
    company_id: "00000000-0000-0000-0000-000000000001",
    name: "Test Product",
    slug: "test-product",
    price: 10,
  });
  assertEquals(missingVariant.success, false);

  // Missing price
  const missingPrice = CreateProductRequest.safeParse({
    company_id: "00000000-0000-0000-0000-000000000001",
    name: "Test Product",
    slug: "test-product",
    variant_name: "Default",
  });
  assertEquals(missingPrice.success, false);

  // Missing company_id
  const missingCompany = CreateProductRequest.safeParse({
    name: "Test Product",
    slug: "test-product",
    variant_name: "Default",
    price: 10,
  });
  assertEquals(missingCompany.success, false);
});

Deno.test("CreateProductRequest: negative price fails validation", () => {
  const result = CreateProductRequest.safeParse({
    company_id: "00000000-0000-0000-0000-000000000001",
    name: "Test Product",
    slug: "test-product",
    variant_name: "Default",
    price: -5,
  });
  assertEquals(result.success, false);
});

Deno.test("CreateProductRequest: invalid UUID fails validation", () => {
  const result = CreateProductRequest.safeParse({
    company_id: "not-a-uuid",
    name: "Test Product",
    slug: "test-product",
    variant_name: "Default",
    price: 10,
  });
  assertEquals(result.success, false);
});

Deno.test("CreateProductRequest: optional fields default correctly", () => {
  const input = {
    company_id: "00000000-0000-0000-0000-000000000001",
    name: "Test Product",
    slug: "test-product",
    variant_name: "Default",
    price: 50,
  };
  const result = CreateProductRequest.safeParse(input);
  assertEquals(result.success, true);
  if (result.success) {
    assertEquals(result.data.brand_id, undefined);
    assertEquals(result.data.category_id, undefined);
    assertEquals(result.data.description, undefined);
    assertEquals(result.data.sku, undefined);
    assertEquals(result.data.barcode, undefined);
    assertEquals(result.data.unit_id, undefined);
    assertEquals(result.data.currency, "MXN");
    assertEquals(result.data.effective_from, undefined);
  }
});

Deno.test("CreateProductRequest: all fields provided pass validation", () => {
  const input = {
    company_id: "00000000-0000-0000-0000-000000000001",
    name: "Full Product",
    slug: "full-product",
    brand_id: "00000000-0000-0000-0000-000000000002",
    category_id: "00000000-0000-0000-0000-000000000003",
    description: "A full product description",
    variant_name: "Large",
    sku: "PROD-1234",
    barcode: "1234567890123",
    unit_id: "00000000-0000-0000-0000-000000000004",
    price: 150.50,
    currency: "USD",
    effective_from: "2026-01-01T00:00:00Z",
  };
  const result = CreateProductRequest.safeParse(input);
  assertEquals(result.success, true);
  if (result.success) {
    assertEquals(result.data.brand_id, "00000000-0000-0000-0000-000000000002");
    assertEquals(result.data.currency, "USD");
    assertEquals(result.data.price, 150.50);
  }
});

Deno.test("DeactivateProductRequest: valid input passes validation", () => {
  const input = {
    company_id: "00000000-0000-0000-0000-000000000001",
    product_id: "00000000-0000-0000-0000-000000000010",
  };
  const result = DeactivateProductRequest.safeParse(input);
  assertEquals(result.success, true);
});

Deno.test("DeactivateProductRequest: missing required fields fail", () => {
  const missingProduct = DeactivateProductRequest.safeParse({
    company_id: "00000000-0000-0000-0000-000000000001",
  });
  assertEquals(missingProduct.success, false);

  const missingCompany = DeactivateProductRequest.safeParse({
    product_id: "00000000-0000-0000-0000-000000000010",
  });
  assertEquals(missingCompany.success, false);
});

// ---------------------------------------------------------------------------
// EFResult shape tests
// ---------------------------------------------------------------------------

Deno.test("EFResult ok shape", async () => {
  const { ok } = await import("../_shared/types.ts");
  const result = ok({ id: "abc", name: "test" });
  assertEquals(result.success, true);
  assertExists(result.data);
  assertEquals(result.data!.id, "abc");
  assertEquals(result.error, undefined);
});

Deno.test("EFResult fail shape", async () => {
  const { fail } = await import("../_shared/types.ts");
  const result = fail("VALIDATION_ERROR", "bad input");
  assertEquals(result.success, false);
  assertEquals(result.error!.code, "VALIDATION_ERROR");
  assertEquals(result.error!.message, "bad input");
  assertEquals(result.data, undefined);
});