// Deno test: catalog unit CRUD EFs
// (source: RC3, D12 — Test specs)
//
// Tests Zod input validation for create/update/deactivate unit.
// Unit has optional abbreviation and name constraints.

import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  CreateUnitRequest,
  UpdateUnitRequest,
  DeactivateUnitRequest,
} from "../_shared/catalog_schemas.ts";

// ---------------------------------------------------------------------------
// CreateUnitRequest
// ---------------------------------------------------------------------------

Deno.test("CreateUnitRequest: valid input with abbreviation passes", () => {
  const input = {
    company_id: "00000000-0000-0000-0000-000000000001",
    name: "Kilogramos",
    abbreviation: "kg",
  };
  const result = CreateUnitRequest.safeParse(input);
  assertEquals(result.success, true);
  if (result.success) {
    assertEquals(result.data.name, "Kilogramos");
    assertEquals(result.data.abbreviation, "kg");
  }
});

Deno.test("CreateUnitRequest: valid input without abbreviation passes", () => {
  const input = {
    company_id: "00000000-0000-0000-0000-000000000001",
    name: "Unidad",
  };
  const result = CreateUnitRequest.safeParse(input);
  assertEquals(result.success, true);
  if (result.success) {
    assertEquals(result.data.abbreviation, undefined);
  }
});

Deno.test("CreateUnitRequest: missing name fails validation", () => {
  const result = CreateUnitRequest.safeParse({
    company_id: "00000000-0000-0000-0000-000000000001",
    abbreviation: "g",
  });
  assertEquals(result.success, false);
});

Deno.test("CreateUnitRequest: empty name fails validation", () => {
  const result = CreateUnitRequest.safeParse({
    company_id: "00000000-0000-0000-0000-000000000001",
    name: "",
  });
  assertEquals(result.success, false);
});

Deno.test("CreateUnitRequest: missing company_id fails validation", () => {
  const result = CreateUnitRequest.safeParse({
    name: "Gramos",
    abbreviation: "g",
  });
  assertEquals(result.success, false);
});

// ---------------------------------------------------------------------------
// UpdateUnitRequest
// ---------------------------------------------------------------------------

Deno.test("UpdateUnitRequest: valid input passes validation", () => {
  const input = {
    company_id: "00000000-0000-0000-0000-000000000001",
    id: "00000000-0000-0000-0000-000000000010",
    name: "Updated Unit",
    abbreviation: "uu",
  };
  const result = UpdateUnitRequest.safeParse(input);
  assertEquals(result.success, true);
  if (result.success) {
    assertEquals(result.data.name, "Updated Unit");
    assertEquals(result.data.abbreviation, "uu");
  }
});

Deno.test("UpdateUnitRequest: partial update with only name passes", () => {
  const input = {
    company_id: "00000000-0000-0000-0000-000000000001",
    id: "00000000-0000-0000-0000-000000000010",
    name: "New Name",
  };
  const result = UpdateUnitRequest.safeParse(input);
  assertEquals(result.success, true);
  if (result.success) {
    assertEquals(result.data.name, "New Name");
    assertEquals(result.data.abbreviation, undefined);
  }
});

Deno.test("UpdateUnitRequest: missing id fails validation", () => {
  const result = UpdateUnitRequest.safeParse({
    company_id: "00000000-0000-0000-0000-000000000001",
    name: "No ID Unit",
  });
  assertEquals(result.success, false);
});

Deno.test("UpdateUnitRequest: invalid id UUID fails", () => {
  const result = UpdateUnitRequest.safeParse({
    company_id: "00000000-0000-0000-0000-000000000001",
    id: "bad-uuid",
    name: "Unit",
  });
  assertEquals(result.success, false);
});

// ---------------------------------------------------------------------------
// DeactivateUnitRequest
// ---------------------------------------------------------------------------

Deno.test("DeactivateUnitRequest: valid input passes validation", () => {
  const input = {
    company_id: "00000000-0000-0000-0000-000000000001",
    id: "00000000-0000-0000-0000-000000000010",
  };
  const result = DeactivateUnitRequest.safeParse(input);
  assertEquals(result.success, true);
  if (result.success) {
    assertEquals(result.data.id, "00000000-0000-0000-0000-000000000010");
  }
});

Deno.test("DeactivateUnitRequest: missing id fails validation", () => {
  const result = DeactivateUnitRequest.safeParse({
    company_id: "00000000-0000-0000-0000-000000000001",
  });
  assertEquals(result.success, false);
});

Deno.test("DeactivateUnitRequest: invalid UUID fails validation", () => {
  const result = DeactivateUnitRequest.safeParse({
    company_id: "00000000-0000-0000-0000-000000000001",
    id: "not-a-uuid",
  });
  assertEquals(result.success, false);
});