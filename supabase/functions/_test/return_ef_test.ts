// Deno test: return-sale-item Edge Function (PR2)
// Validates the 8-step critical-op pattern for sale-item returns.
// (source: RR6, RR8, D6)

import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { corsHeaders } from "../_shared/cors.ts";
import { AUTH_ERRORS, errorResponse } from "../_shared/auth.ts";
import { ReturnSaleItemRequest } from "../_shared/return_schemas.ts";
import type { ReturnHandlerDeps } from "../_shared/return_handler.ts";
import { fail } from "../_shared/types.ts";
import { handleReturnSaleItem } from "../return-sale-item/index.ts";

// ---------------------------------------------------------------------------
// Test constants
// ---------------------------------------------------------------------------

const COMPANY_ID = "00000000-0000-0000-0000-000000000001";
const BRANCH_ID = "00000000-0000-0000-0000-000000000002";
const SALE_ID = "00000000-0000-0000-0000-000000000003";
const SALE_ITEM_ID = "00000000-0000-0000-0000-000000000004";
const VARIANT_ID = "00000000-0000-0000-0000-000000000005";
const BATCH_ID = "00000000-0000-0000-0000-000000000006";
const ADMIN_ID = "00000000-0000-0000-0000-000000000010";
const CASHIER_ID = "00000000-0000-0000-0000-000000000011";
const RETURN_ID = "00000000-0000-0000-0000-000000000020";
const SPOOFED_COMPANY_ID = "00000000-0000-0000-0000-000000000099";
const SPOOFED_USER_ID = "00000000-0000-0000-0000-000000000088";

const VALID_INPUT = {
  branch_id: BRANCH_ID,
  sale_id: SALE_ID,
  type: "partial",
  reason: "Customer changed mind",
  items: [{
    sale_item_id: SALE_ITEM_ID,
    variant_id: VARIANT_ID,
    qty: 2,
    destination: "inventario",
    unit_price: 25.50,
    batches: [{
      original_batch_id: BATCH_ID,
      qty: 2,
    }],
  }],
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function makeRequest(body: Record<string, unknown>): Request {
  return new Request("http://localhost/return-sale-item", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
}

function makeDeps(overrides: Partial<ReturnHandlerDeps> = {}): ReturnHandlerDeps {
  return {
    validateAuth: (_req, _requiredRole) =>
      Promise.resolve({
        user: { id: ADMIN_ID, email: "admin@test.com" },
        companyId: COMPANY_ID,
        role: "admin",
      }),
    createServiceClient: () => ({
      rpc: (_rpcName: string, args: { p: Record<string, unknown> }) =>
        Promise.resolve({
          data: {
            return_id: RETURN_ID,
            status: "pending",
            total_amount: 51.00,
            items_count: 1,
          },
          error: null,
        }),
    }),
    ...overrides,
  };
}

// ---------------------------------------------------------------------------
// Zod schema validation tests
// ---------------------------------------------------------------------------

Deno.test("ReturnSaleItemRequest: valid input passes", () => {
  const result = ReturnSaleItemRequest.safeParse(VALID_INPUT);
  assertEquals(result.success, true);
  if (result.success) {
    assertEquals(result.data.branch_id, BRANCH_ID);
    assertEquals(result.data.sale_id, SALE_ID);
    assertEquals(result.data.type, "partial");
    assertEquals(result.data.reason, "Customer changed mind");
    assertEquals(result.data.items.length, 1);
    assertEquals(result.data.items[0].destination, "inventario");
    assertEquals(result.data.items[0].batches.length, 1);
  }
});

Deno.test("ReturnSaleItemRequest: valid input without optional reason", () => {
  const { reason: _, ...withoutReason } = VALID_INPUT;
  const result = ReturnSaleItemRequest.safeParse(withoutReason);
  assertEquals(result.success, true);
  if (result.success) {
    assertEquals(result.data.reason, undefined);
  }
});

Deno.test("ReturnSaleItemRequest: valid total type", () => {
  const result = ReturnSaleItemRequest.safeParse({
    ...VALID_INPUT,
    type: "total",
  });
  assertEquals(result.success, true);
});

Deno.test("ReturnSaleItemRequest: spoofed auth fields are stripped", () => {
  const result = ReturnSaleItemRequest.safeParse({
    ...VALID_INPUT,
    actor_user_id: SPOOFED_USER_ID,
    company_id: SPOOFED_COMPANY_ID,
  });
  assertEquals(result.success, true);
  if (result.success) {
    assertEquals("actor_user_id" in result.data, false);
    assertEquals("company_id" in result.data, false);
  }
});

Deno.test("ReturnSaleItemRequest: all four destinations accepted", () => {
  for (const dest of ["inventario", "merma", "garantia", "desecho"] as const) {
    const result = ReturnSaleItemRequest.safeParse({
      ...VALID_INPUT,
      items: [{ ...VALID_INPUT.items[0], destination: dest }],
    });
    assertEquals(result.success, true, `Destination "${dest}" should be valid`);
  }
});

Deno.test("ReturnSaleItemRequest: invalid destination fails", () => {
  const result = ReturnSaleItemRequest.safeParse({
    ...VALID_INPUT,
    items: [{ ...VALID_INPUT.items[0], destination: "bodega" }],
  });
  assertEquals(result.success, false);
});

Deno.test("ReturnSaleItemRequest: invalid type fails", () => {
  const result = ReturnSaleItemRequest.safeParse({
    ...VALID_INPUT,
    type: "full",
  });
  assertEquals(result.success, false);
});

Deno.test("ReturnSaleItemRequest: missing sale_id fails", () => {
  const { sale_id: _, ...without } = VALID_INPUT;
  const result = ReturnSaleItemRequest.safeParse(without);
  assertEquals(result.success, false);
});

Deno.test("ReturnSaleItemRequest: missing branch_id fails", () => {
  const { branch_id: _, ...without } = VALID_INPUT;
  const result = ReturnSaleItemRequest.safeParse(without);
  assertEquals(result.success, false);
});

Deno.test("ReturnSaleItemRequest: empty items array fails", () => {
  const result = ReturnSaleItemRequest.safeParse({
    ...VALID_INPUT,
    items: [],
  });
  assertEquals(result.success, false);
});

Deno.test("ReturnSaleItemRequest: item with empty batches fails", () => {
  const result = ReturnSaleItemRequest.safeParse({
    ...VALID_INPUT,
    items: [{ ...VALID_INPUT.items[0], batches: [] }],
  });
  assertEquals(result.success, false);
});

Deno.test("ReturnSaleItemRequest: negative qty fails", () => {
  const result = ReturnSaleItemRequest.safeParse({
    ...VALID_INPUT,
    items: [{ ...VALID_INPUT.items[0], qty: -1 }],
  });
  assertEquals(result.success, false);
});

Deno.test("ReturnSaleItemRequest: zero qty fails", () => {
  const result = ReturnSaleItemRequest.safeParse({
    ...VALID_INPUT,
    items: [{ ...VALID_INPUT.items[0], qty: 0 }],
  });
  assertEquals(result.success, false);
});

Deno.test("ReturnSaleItemRequest: negative unit_price fails", () => {
  const result = ReturnSaleItemRequest.safeParse({
    ...VALID_INPUT,
    items: [{ ...VALID_INPUT.items[0], unit_price: -5 }],
  });
  assertEquals(result.success, false);
});

Deno.test("ReturnSaleItemRequest: blank reason fails (trim.min(1))", () => {
  const result = ReturnSaleItemRequest.safeParse({
    ...VALID_INPUT,
    reason: "   ",
  });
  assertEquals(result.success, false);
});

Deno.test("ReturnSaleItemRequest: invalid UUID for sale_id fails", () => {
  const result = ReturnSaleItemRequest.safeParse({
    ...VALID_INPUT,
    sale_id: "not-a-uuid",
  });
  assertEquals(result.success, false);
});

// ---------------------------------------------------------------------------
// 8-step EF validation tests
// ---------------------------------------------------------------------------

Deno.test("return-sale-item EF: CORS preflight returns 200 with CORS headers", async () => {
  const req = new Request("http://localhost/return-sale-item", { method: "OPTIONS" });
  const response = await handleReturnSaleItem(req, makeDeps());

  assertEquals(response.status, 200);
  assertEquals(
    response.headers.get("Access-Control-Allow-Origin"),
    corsHeaders["Access-Control-Allow-Origin"],
  );
});

Deno.test("return-sale-item EF: unauthenticated request rejected at step 2 with CORS headers", async () => {
  const response = await handleReturnSaleItem(
    makeRequest(VALID_INPUT),
    makeDeps({
      validateAuth: () => Promise.reject(errorResponse(401, AUTH_ERRORS.NO_AUTH_HEADER)),
    }),
  );

  const body = await response.json();
  assertEquals(response.status, 401);
  assertEquals(body.success, false);
  assertEquals(body.error.code, "UNAUTHORIZED");
  assertEquals(
    response.headers.get("Access-Control-Allow-Origin"),
    corsHeaders["Access-Control-Allow-Origin"],
  );
});

Deno.test("return-sale-item EF: non-admin role rejected at step 4 (FORBIDDEN) with CORS headers", async () => {
  const response = await handleReturnSaleItem(
    makeRequest(VALID_INPUT),
    makeDeps({
      validateAuth: () => Promise.reject(errorResponse(403, AUTH_ERRORS.INSUFFICIENT_ROLE)),
    }),
  );

  const body = await response.json();
  assertEquals(response.status, 403);
  assertEquals(body, fail("FORBIDDEN", "Insufficient permissions"));
  assertEquals(
    response.headers.get("Access-Control-Allow-Origin"),
    corsHeaders["Access-Control-Allow-Origin"],
  );
});

Deno.test("return-sale-item EF: cashier role is rejected (admin-only)", async () => {
  const response = await handleReturnSaleItem(
    makeRequest(VALID_INPUT),
    makeDeps({
      validateAuth: () => Promise.reject(errorResponse(403, AUTH_ERRORS.INSUFFICIENT_ROLE)),
    }),
  );

  assertEquals(response.status, 403);
});

Deno.test("return-sale-item EF: admin role is allowed", async () => {
  let roleChecked = false;

  const response = await handleReturnSaleItem(
    makeRequest(VALID_INPUT),
    makeDeps({
      validateAuth: (_req, requiredRole) => {
        roleChecked = true;
        assertEquals(requiredRole, ["admin"]);
        return Promise.resolve({
          user: { id: ADMIN_ID, email: "admin@test.com" },
          companyId: COMPANY_ID,
          role: "admin",
        });
      },
    }),
  );

  const body = await response.json();
  assertEquals(roleChecked, true);
  assertEquals(response.status, 200);
  assertEquals(body.success, true);
});

Deno.test("return-sale-item EF: invalid Zod input rejected at step 5", async () => {
  const response = await handleReturnSaleItem(
    makeRequest({
      branch_id: "not-a-uuid",
      sale_id: "not-a-uuid",
      type: "full",
      items: [],
    }),
    makeDeps(),
  );

  const body = await response.json();
  assertEquals(response.status, 400);
  assertEquals(body.success, false);
  assertEquals(body.error.code, "VALIDATION_ERROR");
});

Deno.test("return-sale-item EF: correct RPC name and server-derived payload (step 5-6)", async () => {
  let capturedRpcName = "";
  let capturedPayload: Record<string, unknown> | undefined;

  const response = await handleReturnSaleItem(
    makeRequest({
      ...VALID_INPUT,
      actor_user_id: SPOOFED_USER_ID,
      company_id: SPOOFED_COMPANY_ID,
    }),
    makeDeps({
      createServiceClient: () => ({
        rpc: (rpcName: string, args: { p: Record<string, unknown> }) => {
          capturedRpcName = rpcName;
          capturedPayload = args.p;
          return Promise.resolve({
            data: {
              return_id: RETURN_ID,
              status: "pending",
              total_amount: 51.00,
              items_count: 1,
            },
            error: null,
          });
        },
      }),
    }),
  );

  const body = await response.json();
  assertEquals(response.status, 200);
  assertEquals(capturedRpcName, "return_sale_item_transaction");
  // Server-derived fields override client-spoofed values
  assertEquals(capturedPayload?.company_id, COMPANY_ID);
  assertEquals(capturedPayload?.actor_user_id, ADMIN_ID);
  // Client fields preserved
  assertEquals(capturedPayload?.branch_id, BRANCH_ID);
  assertEquals(capturedPayload?.sale_id, SALE_ID);
  assertEquals(capturedPayload?.type, "partial");
  assertEquals(capturedPayload?.reason, "Customer changed mind");
  assertEquals(body.success, true);
  assertEquals(body.data.return_id, RETURN_ID);
  assertEquals(body.data.status, "pending");
  assertEquals(body.data.items_count, 1);
});

Deno.test("return-sale-item EF: RPC error returned as EFResult error", async () => {
  const response = await handleReturnSaleItem(
    makeRequest(VALID_INPUT),
    makeDeps({
      createServiceClient: () => ({
        rpc: () =>
          Promise.resolve({
            data: null,
            error: { code: "VALIDATION_ERROR", message: "Sale is cancelled" },
          }),
      }),
    }),
  );

  const body = await response.json();
  assertEquals(response.status, 400);
  assertEquals(body.success, false);
  assertEquals(body.error.code, "VALIDATION_ERROR");
});

Deno.test("return-sale-item EF: missing service config returns 500", async () => {
  const response = await handleReturnSaleItem(
    makeRequest(VALID_INPUT),
    makeDeps({
      createServiceClient: () => null,
    }),
  );

  const body = await response.json();
  assertEquals(response.status, 500);
  assertEquals(body.success, false);
  assertEquals(body.error.code, "SERVER_ERROR");
});