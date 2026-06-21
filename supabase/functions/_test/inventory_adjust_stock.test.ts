// Deno test: inventory adjust-stock and reservation stubs
// (source: RI6, RI10, RI11 — Test specs)

import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  AdjustInventoryRequest,
  ReleaseReservationRequest,
  ReserveStockRequest,
} from "../_shared/inventory_schemas.ts";
import { handleAdjustStock } from "../inventory/adjust-stock/index.ts";
import { handleReleaseReservation } from "../inventory/release-reservation/index.ts";
import { handleReserveStock } from "../inventory/reserve-stock/index.ts";
import { fail } from "../_shared/types.ts";
import type { InventoryHandlerDeps } from "../_shared/inventory_handler.ts";

const COMPANY_ID = "00000000-0000-0000-0000-000000000001";
const BRANCH_ID = "00000000-0000-0000-0000-000000000002";
const VARIANT_ID = "00000000-0000-0000-0000-000000000003";

function makeRequest(path: string, body: Record<string, unknown>): Request {
  return new Request(`http://localhost${path}`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
}

function makeDeps(handler: (rpcName: string, args: { p: Record<string, unknown> }) => Promise<{ data: unknown; error: { code?: string; message: string } | null }>): InventoryHandlerDeps {
  return {
    validateAuth: () => Promise.resolve({
      user: { id: "user-1" },
      companyId: COMPANY_ID,
      role: "admin",
    }),
    createServiceClient: () => ({ rpc: handler }),
  };
}

Deno.test("AdjustInventoryRequest: positive and negative quantities pass, zero fails", () => {
  assertEquals(
    AdjustInventoryRequest.safeParse({
      company_id: COMPANY_ID,
      branch_id: BRANCH_ID,
      variant_id: VARIANT_ID,
      qty: 5,
      reason: "cycle count gain",
    }).success,
    true,
  );

  assertEquals(
    AdjustInventoryRequest.safeParse({
      company_id: COMPANY_ID,
      branch_id: BRANCH_ID,
      variant_id: VARIANT_ID,
      qty: -2,
      reason: "cycle count loss",
    }).success,
    true,
  );

  assertEquals(
    AdjustInventoryRequest.safeParse({
      company_id: COMPANY_ID,
      branch_id: BRANCH_ID,
      variant_id: VARIANT_ID,
      qty: 0,
      reason: "invalid",
    }).success,
    false,
  );
});

Deno.test("ReserveStockRequest and ReleaseReservationRequest: company_id is required", () => {
  assertEquals(ReserveStockRequest.safeParse({ company_id: COMPANY_ID }).success, true);
  assertEquals(ReleaseReservationRequest.safeParse({}).success, false);
});

Deno.test("adjust-stock EF: admin success returns movement payload", async () => {
  const response = await handleAdjustStock(
    makeRequest("/inventory/adjust-stock", {
      company_id: COMPANY_ID,
      branch_id: BRANCH_ID,
      variant_id: VARIANT_ID,
      qty: 5,
      reason: "cycle count gain",
    }),
    makeDeps(() => Promise.resolve({
      data: {
        lot_id: "00000000-0000-0000-0000-000000000010",
        lot_code: "ADJ-MAIN-20260611-0001",
        movement_id: "00000000-0000-0000-0000-000000000011",
        qty: 5,
      },
      error: null,
    })),
  );

  const body = await response.json();
  assertEquals(response.status, 200);
  assertEquals(body.success, true);
  assertEquals(body.data.lot_code, "ADJ-MAIN-20260611-0001");
});

Deno.test("adjust-stock EF: unauthenticated request is rejected", async () => {
  const response = await handleAdjustStock(
    makeRequest("/inventory/adjust-stock", {
      company_id: COMPANY_ID,
      branch_id: BRANCH_ID,
      variant_id: VARIANT_ID,
      qty: 5,
      reason: "cycle count gain",
    }),
    {
      validateAuth: () => Promise.reject(Response.json(fail("UNAUTHORIZED", "Missing Authorization header"), { status: 401 })),
    },
  );

  const body = await response.json();
  assertEquals(response.status, 401);
  assertEquals(body.error.code, "UNAUTHORIZED");
});

Deno.test("reservation stubs: reserve-stock and release-reservation return NOT_SUPPORTED", async () => {
  const reserveResponse = await handleReserveStock(
    makeRequest("/inventory/reserve-stock", { company_id: COMPANY_ID }),
    makeDeps(() => Promise.resolve({
      data: null,
      error: { code: "P0001", message: "Reservations are not supported in V1" },
    })),
  );

  const releaseResponse = await handleReleaseReservation(
    makeRequest("/inventory/release-reservation", { company_id: COMPANY_ID }),
    makeDeps(() => Promise.resolve({
      data: null,
      error: { code: "P0001", message: "Reservations are not supported in V1" },
    })),
  );

  const reserveBody = await reserveResponse.json();
  const releaseBody = await releaseResponse.json();

  assertEquals(reserveResponse.status, 400);
  assertEquals(reserveBody.error.code, "NOT_SUPPORTED");
  assertEquals(releaseResponse.status, 400);
  assertEquals(releaseBody.error.code, "NOT_SUPPORTED");
});
