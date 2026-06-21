// Deno test: inventory receive-purchase EF
// (source: RI5, RI8, RI11 — Test specs)

import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { ReceivePurchaseRequest } from "../_shared/inventory_schemas.ts";
import { handleReceivePurchase } from "../inventory/receive-purchase/index.ts";
import { fail } from "../_shared/types.ts";
import type { InventoryHandlerDeps } from "../_shared/inventory_handler.ts";

const COMPANY_ID = "00000000-0000-0000-0000-000000000001";
const BRANCH_ID = "00000000-0000-0000-0000-000000000002";
const VARIANT_ID = "00000000-0000-0000-0000-000000000003";

function makeRequest(body: Record<string, unknown>): Request {
  return new Request("http://localhost/inventory/receive-purchase", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
}

function makeDeps(overrides: Partial<InventoryHandlerDeps> = {}): InventoryHandlerDeps {
  return {
    validateAuth: () => Promise.resolve({
      user: { id: "user-1", email: "admin@test.com" },
      companyId: COMPANY_ID,
      role: "admin",
    }),
    createServiceClient: () => ({
      rpc: (_rpcName: string, args: { p: Record<string, unknown> }) => Promise.resolve({
        data: {
          lot_id: "00000000-0000-0000-0000-000000000010",
          lot_code: "LOT-MAIN-20260611-0001",
          movement_id: "00000000-0000-0000-0000-000000000011",
          qty: args.p.qty,
        },
        error: null,
      }),
    }),
    ...overrides,
  };
}

Deno.test("ReceivePurchaseRequest: valid input passes validation", () => {
  const result = ReceivePurchaseRequest.safeParse({
    company_id: COMPANY_ID,
    branch_id: BRANCH_ID,
    variant_id: VARIANT_ID,
    qty: 5,
  });

  assertEquals(result.success, true);
});

Deno.test("ReceivePurchaseRequest: invalid qty fails validation", () => {
  const result = ReceivePurchaseRequest.safeParse({
    company_id: COMPANY_ID,
    branch_id: BRANCH_ID,
    variant_id: VARIANT_ID,
    qty: 0,
  });

  assertEquals(result.success, false);
});

Deno.test("receive-purchase EF: admin success returns EFResult shape", async () => {
  let capturedRpcName = "";
  let capturedPayload: Record<string, unknown> | undefined;

  const response = await handleReceivePurchase(
    makeRequest({
      company_id: COMPANY_ID,
      branch_id: BRANCH_ID,
      variant_id: VARIANT_ID,
      qty: 5,
    }),
    makeDeps({
      createServiceClient: () => ({
        rpc: (rpcName: string, args: { p: Record<string, unknown> }) => {
          capturedRpcName = rpcName;
          capturedPayload = args.p;
          return Promise.resolve({
            data: {
              lot_id: "00000000-0000-0000-0000-000000000010",
              lot_code: "LOT-MAIN-20260611-0001",
              movement_id: "00000000-0000-0000-0000-000000000011",
              qty: args.p.qty,
            },
            error: null,
          });
        },
      }),
    }),
  );

  const body = await response.json();
  assertEquals(response.status, 200);
  assertEquals(capturedRpcName, "receive_purchase_lot");
  assertEquals(capturedPayload?.company_id, COMPANY_ID);
  assertEquals(body.success, true);
  assertEquals(body.data.qty, 5);
  assertEquals(typeof body.data.lot_code, "string");
});

Deno.test("receive-purchase EF: unauthenticated request is rejected", async () => {
  const response = await handleReceivePurchase(
    makeRequest({
      company_id: COMPANY_ID,
      branch_id: BRANCH_ID,
      variant_id: VARIANT_ID,
      qty: 5,
    }),
    makeDeps({
      validateAuth: () => Promise.reject(Response.json(fail("UNAUTHORIZED", "Missing Authorization header"), { status: 401 })),
    }),
  );

  const body = await response.json();
  assertEquals(response.status, 401);
  assertEquals(body.success, false);
  assertEquals(body.error.code, "UNAUTHORIZED");
});

Deno.test("receive-purchase EF: cashier request is rejected", async () => {
  const response = await handleReceivePurchase(
    makeRequest({
      company_id: COMPANY_ID,
      branch_id: BRANCH_ID,
      variant_id: VARIANT_ID,
      qty: 5,
    }),
    makeDeps({
      validateAuth: () => Promise.reject(Response.json(fail("FORBIDDEN", "Insufficient permissions"), { status: 403 })),
    }),
  );

  const body = await response.json();
  assertEquals(response.status, 403);
  assertEquals(body.success, false);
  assertEquals(body.error.code, "FORBIDDEN");
});
