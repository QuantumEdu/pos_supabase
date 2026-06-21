// Deno test: catalog update-product EF
// (source: RC4, PR3 corrective follow-up — Test specs)
//
// Tests Zod input validation for update_product.

import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { UpdateProductRequest } from "../_shared/catalog_schemas.ts";

// ---------------------------------------------------------------------------
// Zod schema validation tests
// ---------------------------------------------------------------------------

Deno.test("UpdateProductRequest: valid minimal input passes validation", () => {
  const input = {
    company_id: "00000000-0000-0000-0000-000000000001",
    product_id: "00000000-0000-0000-0000-000000000010",
    name: "Updated Product Name",
  };
  const result = UpdateProductRequest.safeParse(input);
  assertEquals(result.success, true);
  if (result.success) {
    assertEquals(result.data.company_id, "00000000-0000-0000-0000-000000000001");
    assertEquals(result.data.product_id, "00000000-0000-0000-0000-000000000010");
    assertEquals(result.data.name, "Updated Product Name");
  }
});

Deno.test("UpdateProductRequest: all optional fields pass validation", () => {
  const input = {
    company_id: "00000000-0000-0000-0000-000000000001",
    product_id: "00000000-0000-0000-0000-000000000010",
    name: "Updated Name",
    slug: "updated-slug",
    brand_id: "00000000-0000-0000-0000-000000000020",
    category_id: "00000000-0000-0000-0000-000000000030",
    description: "Updated description",
  };
  const result = UpdateProductRequest.safeParse(input);
  assertEquals(result.success, true);
  if (result.success) {
    assertEquals(result.data.name, "Updated Name");
    assertEquals(result.data.slug, "updated-slug");
    assertEquals(result.data.brand_id, "00000000-0000-0000-0000-000000000020");
    assertEquals(result.data.category_id, "00000000-0000-0000-0000-000000000030");
    assertEquals(result.data.description, "Updated description");
  }
});

Deno.test("UpdateProductRequest: nullable brand_id to clear reference", () => {
  const input = {
    company_id: "00000000-0000-0000-0000-000000000001",
    product_id: "00000000-0000-0000-0000-000000000010",
    brand_id: null,
  };
  const result = UpdateProductRequest.safeParse(input);
  assertEquals(result.success, true);
  if (result.success) {
    assertEquals(result.data.brand_id, null);
  }
});

Deno.test("UpdateProductRequest: nullable category_id to clear reference", () => {
  const input = {
    company_id: "00000000-0000-0000-0000-000000000001",
    product_id: "00000000-0000-0000-0000-000000000010",
    category_id: null,
  };
  const result = UpdateProductRequest.safeParse(input);
  assertEquals(result.success, true);
  if (result.success) {
    assertEquals(result.data.category_id, null);
  }
});

Deno.test("UpdateProductRequest: missing required fields fail", () => {
  // Missing product_id
  const noProductId = UpdateProductRequest.safeParse({
    company_id: "00000000-0000-0000-0000-000000000001",
  });
  assertEquals(noProductId.success, false);

  // Missing company_id
  const noCompanyId = UpdateProductRequest.safeParse({
    product_id: "00000000-0000-0000-0000-000000000010",
  });
  assertEquals(noCompanyId.success, false);
});

Deno.test("UpdateProductRequest: invalid UUID for product_id fails", () => {
  const result = UpdateProductRequest.safeParse({
    company_id: "00000000-0000-0000-0000-000000000001",
    product_id: "not-a-uuid",
    name: "Test",
  });
  assertEquals(result.success, false);
});

Deno.test("UpdateProductRequest: invalid UUID for brand_id fails", () => {
  const result = UpdateProductRequest.safeParse({
    company_id: "00000000-0000-0000-0000-000000000001",
    product_id: "00000000-0000-0000-0000-000000000010",
    brand_id: "not-a-uuid",
  });
  assertEquals(result.success, false);
});

Deno.test("UpdateProductRequest: extra keys are stripped by Zod", () => {
  const input = {
    company_id: "00000000-0000-0000-0000-000000000001",
    product_id: "00000000-0000-0000-0000-000000000010",
    name: "Test",
    extra_field: "should be stripped",
  };
  const result = UpdateProductRequest.safeParse(input);
  assertEquals(result.success, true);
  if (result.success) {
    assertEquals("extra_field" in result.data, false);
  }
});