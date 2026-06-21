// Deno test: catalog brand CRUD EFs
// (source: RC1, D12 — Test specs)
//
// Tests Zod input validation for create/update/deactivate brand.

import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  CreateBrandRequest,
  UpdateBrandRequest,
  DeactivateBrandRequest,
} from "../_shared/catalog_schemas.ts";

// ---------------------------------------------------------------------------
// CreateBrandRequest
// ---------------------------------------------------------------------------

Deno.test("CreateBrandRequest: valid input passes validation", () => {
  const input = {
    company_id: "00000000-0000-0000-0000-000000000001",
    name: "Test Brand",
    slug: "test-brand",
  };
  const result = CreateBrandRequest.safeParse(input);
  assertEquals(result.success, true);
  if (result.success) {
    assertEquals(result.data.name, "Test Brand");
    assertEquals(result.data.slug, "test-brand");
  }
});

Deno.test("CreateBrandRequest: missing name fails validation", () => {
  const result = CreateBrandRequest.safeParse({
    company_id: "00000000-0000-0000-0000-000000000001",
    slug: "test-brand",
  });
  assertEquals(result.success, false);
});

Deno.test("CreateBrandRequest: missing slug fails validation", () => {
  const result = CreateBrandRequest.safeParse({
    company_id: "00000000-0000-0000-0000-000000000001",
    name: "Test Brand",
  });
  assertEquals(result.success, false);
});

Deno.test("CreateBrandRequest: empty name fails validation", () => {
  const result = CreateBrandRequest.safeParse({
    company_id: "00000000-0000-0000-0000-000000000001",
    name: "",
    slug: "test-brand",
  });
  assertEquals(result.success, false);
});

Deno.test("CreateBrandRequest: empty slug fails validation", () => {
  const result = CreateBrandRequest.safeParse({
    company_id: "00000000-0000-0000-0000-000000000001",
    name: "Test Brand",
    slug: "",
  });
  assertEquals(result.success, false);
});

// ---------------------------------------------------------------------------
// UpdateBrandRequest
// ---------------------------------------------------------------------------

Deno.test("UpdateBrandRequest: valid input with optional fields passes", () => {
  const input = {
    company_id: "00000000-0000-0000-0000-000000000001",
    id: "00000000-0000-0000-0000-000000000010",
    name: "Updated Brand",
    slug: "updated-brand",
  };
  const result = UpdateBrandRequest.safeParse(input);
  assertEquals(result.success, true);
  if (result.success) {
    assertEquals(result.data.name, "Updated Brand");
    assertEquals(result.data.slug, "updated-brand");
  }
});

Deno.test("UpdateBrandRequest: partial update with only name passes", () => {
  const input = {
    company_id: "00000000-0000-0000-0000-000000000001",
    id: "00000000-0000-0000-0000-000000000010",
    name: "New Name",
  };
  const result = UpdateBrandRequest.safeParse(input);
  assertEquals(result.success, true);
  if (result.success) {
    assertEquals(result.data.name, "New Name");
    assertEquals(result.data.slug, undefined);
  }
});

Deno.test("UpdateBrandRequest: missing id fails validation", () => {
  const result = UpdateBrandRequest.safeParse({
    company_id: "00000000-0000-0000-0000-000000000001",
    name: "Brand",
  });
  assertEquals(result.success, false);
});

// ---------------------------------------------------------------------------
// DeactivateBrandRequest
// ---------------------------------------------------------------------------

Deno.test("DeactivateBrandRequest: valid input passes validation", () => {
  const input = {
    company_id: "00000000-0000-0000-0000-000000000001",
    id: "00000000-0000-0000-0000-000000000010",
  };
  const result = DeactivateBrandRequest.safeParse(input);
  assertEquals(result.success, true);
  if (result.success) {
    assertEquals(result.data.id, "00000000-0000-0000-0000-000000000010");
  }
});

Deno.test("DeactivateBrandRequest: missing id fails validation", () => {
  const result = DeactivateBrandRequest.safeParse({
    company_id: "00000000-0000-0000-0000-000000000001",
  });
  assertEquals(result.success, false);
});

Deno.test("DeactivateBrandRequest: invalid UUID fails validation", () => {
  const result = DeactivateBrandRequest.safeParse({
    company_id: "00000000-0000-0000-0000-000000000001",
    id: "not-a-uuid",
  });
  assertEquals(result.success, false);
});