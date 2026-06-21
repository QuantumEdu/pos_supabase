// Deno test: catalog category CRUD EFs
// (source: RC2, D12 — Test specs)
//
// Tests Zod input validation for create/update/deactivate category.
// Category is hierarchical — parent_id can be null or a valid UUID.

import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  CreateCategoryRequest,
  UpdateCategoryRequest,
  DeactivateCategoryRequest,
} from "../_shared/catalog_schemas.ts";

// ---------------------------------------------------------------------------
// CreateCategoryRequest
// ---------------------------------------------------------------------------

Deno.test("CreateCategoryRequest: valid input without parent_id passes", () => {
  const input = {
    company_id: "00000000-0000-0000-0000-000000000001",
    name: "Root Category",
    slug: "root-category",
  };
  const result = CreateCategoryRequest.safeParse(input);
  assertEquals(result.success, true);
  if (result.success) {
    assertEquals(result.data.name, "Root Category");
    assertEquals(result.data.parent_id, undefined);
  }
});

Deno.test("CreateCategoryRequest: valid input with parent_id passes", () => {
  const input = {
    company_id: "00000000-0000-0000-0000-000000000001",
    name: "Child Category",
    slug: "child-category",
    parent_id: "00000000-0000-0000-0000-000000000002",
  };
  const result = CreateCategoryRequest.safeParse(input);
  assertEquals(result.success, true);
  if (result.success) {
    assertEquals(result.data.parent_id, "00000000-0000-0000-0000-000000000002");
  }
});

Deno.test("CreateCategoryRequest: missing name fails", () => {
  const result = CreateCategoryRequest.safeParse({
    company_id: "00000000-0000-0000-0000-000000000001",
    slug: "cat-slug",
  });
  assertEquals(result.success, false);
});

Deno.test("CreateCategoryRequest: missing slug fails", () => {
  const result = CreateCategoryRequest.safeParse({
    company_id: "00000000-0000-0000-0000-000000000001",
    name: "Category",
  });
  assertEquals(result.success, false);
});

Deno.test("CreateCategoryRequest: invalid parent_id UUID fails", () => {
  const result = CreateCategoryRequest.safeParse({
    company_id: "00000000-0000-0000-0000-000000000001",
    name: "Category",
    slug: "cat",
    parent_id: "not-a-uuid",
  });
  assertEquals(result.success, false);
});

// ---------------------------------------------------------------------------
// UpdateCategoryRequest
// ---------------------------------------------------------------------------

Deno.test("UpdateCategoryRequest: valid full update passes", () => {
  const input = {
    company_id: "00000000-0000-0000-0000-000000000001",
    id: "00000000-0000-0000-0000-000000000010",
    name: "Updated Category",
    slug: "updated-category",
    parent_id: "00000000-0000-0000-0000-000000000020",
  };
  const result = UpdateCategoryRequest.safeParse(input);
  assertEquals(result.success, true);
  if (result.success) {
    assertEquals(result.data.name, "Updated Category");
    assertEquals(result.data.parent_id, "00000000-0000-0000-0000-000000000020");
  }
});

Deno.test("UpdateCategoryRequest: null parent_id clears parent (reparent to root)", () => {
  const input = {
    company_id: "00000000-0000-0000-0000-000000000001",
    id: "00000000-0000-0000-0000-000000000010",
    parent_id: null,
  };
  const result = UpdateCategoryRequest.safeParse(input);
  // null should be accepted since UpdateCategoryRequest has nullable() on parent_id
  assertEquals(result.success, true);
  if (result.success) {
    assertEquals(result.data.parent_id, null);
  }
});

Deno.test("UpdateCategoryRequest: partial update with only name passes", () => {
  const input = {
    company_id: "00000000-0000-0000-0000-000000000001",
    id: "00000000-0000-0000-0000-000000000010",
    name: "New Name Only",
  };
  const result = UpdateCategoryRequest.safeParse(input);
  assertEquals(result.success, true);
  if (result.success) {
    assertEquals(result.data.name, "New Name Only");
    assertEquals(result.data.slug, undefined);
    assertEquals(result.data.parent_id, undefined);
  }
});

Deno.test("UpdateCategoryRequest: missing id fails", () => {
  const result = UpdateCategoryRequest.safeParse({
    company_id: "00000000-0000-0000-0000-000000000001",
    name: "No ID",
  });
  assertEquals(result.success, false);
});

// ---------------------------------------------------------------------------
// DeactivateCategoryRequest
// ---------------------------------------------------------------------------

Deno.test("DeactivateCategoryRequest: valid input passes", () => {
  const input = {
    company_id: "00000000-0000-0000-0000-000000000001",
    id: "00000000-0000-0000-0000-000000000010",
  };
  const result = DeactivateCategoryRequest.safeParse(input);
  assertEquals(result.success, true);
});

Deno.test("DeactivateCategoryRequest: invalid UUID fails", () => {
  const result = DeactivateCategoryRequest.safeParse({
    company_id: "bad-uuid",
    id: "also-bad",
  });
  assertEquals(result.success, false);
});