// Deno test: POS sales Edge Functions (PR3 + PR4)

import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { corsHeaders } from "../_shared/cors.ts";
import { AUTH_ERRORS, errorResponse } from "../_shared/auth.ts";
import {
  AuthorizeDiscountRequest,
  CancelSaleRequest,
  CreateSaleRequest,
} from "../_shared/pos_sales_schemas.ts";
import type { PosSalesHandlerDeps } from "../_shared/pos_sales_handler.ts";
import { fail } from "../_shared/types.ts";
import { handleAuthorizeDiscount } from "../pos-sales/authorize-discount/index.ts";
import { handleCancelSale } from "../pos-sales/cancel-sale/index.ts";
import { handleCreateSale } from "../pos-sales/create-sale/index.ts";

const COMPANY_ID = "00000000-0000-0000-0000-000000000001";
const BRANCH_ID = "00000000-0000-0000-0000-000000000002";
const SALE_ID = "00000000-0000-0000-0000-000000000003";
const CASHIER_ID = "00000000-0000-0000-0000-000000000004";
const SESSION_ID = "00000000-0000-0000-0000-000000000005";
const CUSTOMER_ID = "00000000-0000-0000-0000-000000000006";
const ADMIN_ID = "00000000-0000-0000-0000-000000000010";
const SPOOFED_COMPANY_ID = "00000000-0000-0000-0000-000000000099";
const SPOOFED_USER_ID = "00000000-0000-0000-0000-000000000088";

function makeRequest(path: string, body: Record<string, unknown>): Request {
  return new Request(`http://localhost${path}`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
}

function saleInput(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    branch_id: BRANCH_ID,
    items: [
      {
        variant_id: "00000000-0000-0000-0000-000000000007",
        quantity: 2,
        unit_price: 50,
        line_total: 100,
      },
    ],
    payments: [
      { payment_method: "cash", amount: 100 },
    ],
    ...overrides,
  };
}

function makeDeps(overrides: Partial<PosSalesHandlerDeps> = {}): PosSalesHandlerDeps {
  return {
    validateAuth: (_req, _requiredRole) =>
      Promise.resolve({
        user: { id: CASHIER_ID, email: "cashier@test.com" },
        companyId: COMPANY_ID,
        role: "cashier",
      }),
    createServiceClient: () => ({
      rpc: (rpcName: string, args: { p: Record<string, unknown> }) =>
        Promise.resolve({
          data: rpcName === "create_sale_transaction"
            ? {
              sale_id: SALE_ID,
              sale_number: 1,
              status: "completed",
              subtotal: 100,
              discount_amount: 0,
              tax_amount: 0,
              total: 100,
              cash_session_id: SESSION_ID,
            }
            : rpcName === "cancel_sale_transaction"
            ? {
              sale_id: SALE_ID,
              status: "cancelled",
              reversed_items: 2,
            }
            : {
              authorization_id: "00000000-0000-0000-0000-000000000008",
              sale_id: args.p.sale_id,
              authorized_at: "2025-01-01T00:00:00Z",
            },
          error: null,
        }),
    }),
    ...overrides,
  };
}

// ---------------------------------------------------------------------------
// CreateSaleRequest schema tests (PR3)
// ---------------------------------------------------------------------------

Deno.test("CreateSaleRequest: valid input passes and strips spoofed auth fields", () => {
  const result = CreateSaleRequest.safeParse({
    ...saleInput({ customer_id: CUSTOMER_ID }),
    actor_user_id: SPOOFED_USER_ID,
    company_id: SPOOFED_COMPANY_ID,
  });

  assertEquals(result.success, true);
  if (result.success) {
    assertEquals("actor_user_id" in result.data, false);
    assertEquals("company_id" in result.data, false);
  }
});

Deno.test("CreateSaleRequest: negative unit_price fails", () => {
  const result = CreateSaleRequest.safeParse(
    saleInput({
      items: [
        {
          variant_id: "00000000-0000-0000-0000-000000000007",
          quantity: 2,
          unit_price: -1,
        },
      ],
    }),
  );

  assertEquals(result.success, false);
});

Deno.test("CreateSaleRequest: invalid payment method fails", () => {
  const result = CreateSaleRequest.safeParse(
    saleInput({
      payments: [
        { payment_method: "crypto", amount: 100 },
      ],
    }),
  );

  assertEquals(result.success, false);
});

Deno.test("CreateSaleRequest: empty items array fails", () => {
  const result = CreateSaleRequest.safeParse(
    saleInput({ items: [] }),
  );

  assertEquals(result.success, false);
});

// ---------------------------------------------------------------------------
// CancelSaleRequest schema tests (PR3)
// ---------------------------------------------------------------------------

Deno.test("CancelSaleRequest: valid input passes and strips spoofed auth fields", () => {
  const result = CancelSaleRequest.safeParse({
    sale_id: SALE_ID,
    reason: "Customer changed mind",
    actor_user_id: SPOOFED_USER_ID,
    company_id: SPOOFED_COMPANY_ID,
  });

  assertEquals(result.success, true);
  if (result.success) {
    assertEquals("actor_user_id" in result.data, false);
    assertEquals("company_id" in result.data, false);
  }
});

Deno.test("CancelSaleRequest: missing sale_id fails", () => {
  const result = CancelSaleRequest.safeParse({
    reason: "Customer changed mind",
  });

  assertEquals(result.success, false);
});

// ---------------------------------------------------------------------------
// AuthorizeDiscountRequest schema tests (PR4)
// ---------------------------------------------------------------------------

Deno.test("AuthorizeDiscountRequest: valid input passes and strips spoofed auth fields", () => {
  const result = AuthorizeDiscountRequest.safeParse({
    sale_id: SALE_ID,
    discount_percent: 10,
    discount_amount: 5,
    reason: "Manager override",
    actor_user_id: SPOOFED_USER_ID,
    company_id: SPOOFED_COMPANY_ID,
  });

  assertEquals(result.success, true);
  if (result.success) {
    assertEquals("actor_user_id" in result.data, false);
    assertEquals("company_id" in result.data, false);
  }
});

Deno.test("AuthorizeDiscountRequest: discount_percent > 100 fails", () => {
  const result = AuthorizeDiscountRequest.safeParse({
    sale_id: SALE_ID,
    discount_percent: 150,
    discount_amount: 5,
    reason: "Manager override",
  });

  assertEquals(result.success, false);
});

// ---------------------------------------------------------------------------
// create-sale Edge Function tests (PR3)
// ---------------------------------------------------------------------------

Deno.test("create-sale EF: unauthenticated request includes CORS headers", async () => {
  const response = await handleCreateSale(
    makeRequest("/pos-sales/create-sale", saleInput()),
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

Deno.test("create-sale EF: forbidden role includes CORS headers", async () => {
  const response = await handleCreateSale(
    makeRequest("/pos-sales/create-sale", saleInput()),
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

Deno.test("create-sale EF: cashier allowed, correct RPC name, and server-derived payload", async () => {
  let capturedRpcName = "";
  let capturedPayload: Record<string, unknown> | undefined;

  const response = await handleCreateSale(
    makeRequest("/pos-sales/create-sale", {
      ...saleInput(),
      actor_user_id: SPOOFED_USER_ID,
      company_id: SPOOFED_COMPANY_ID,
    }),
    makeDeps({
      createServiceClient: () => ({
        rpc: (rpcName, args) => {
            capturedRpcName = rpcName;
            capturedPayload = args.p;
            return Promise.resolve({
              data: {
                success: true,
                data: {
                  sale_id: SALE_ID,
                  sale_number: 1,
                  status: "completed",
                  subtotal: 100,
                  discount_amount: 0,
                  tax_amount: 0,
                  total: 100,
                  cash_session_id: SESSION_ID,
                },
              },
              error: null,
            });
        },
      }),
    }),
  );

  const body = await response.json();
  assertEquals(response.status, 200);
  assertEquals(capturedRpcName, "create_sale_transaction");
  assertEquals(capturedPayload?.company_id, COMPANY_ID);
  assertEquals(capturedPayload?.actor_user_id, CASHIER_ID);
  assertEquals(capturedPayload?.branch_id, BRANCH_ID);
  assertEquals((capturedPayload?.items as Array<Record<string, unknown>>)[0].line_total, 100);
  assertEquals(body.success, true);
  assertEquals(body.data.sale_id, SALE_ID);
  assertEquals(body.data.cash_session_id, SESSION_ID);
});

Deno.test("create-sale EF: RPC business failure becomes HTTP 400", async () => {
  const response = await handleCreateSale(
    makeRequest("/pos-sales/create-sale", saleInput()),
    makeDeps({
      createServiceClient: () => ({
        rpc: () => Promise.resolve({
          data: {
            success: false,
            code: "VALIDATION_ERROR",
            message: "No open cash session for this cashier in this branch",
          },
          error: null,
        }),
      }),
    }),
  );

  const body = await response.json();
  assertEquals(response.status, 400);
  assertEquals(body.success, false);
  assertEquals(body.error.code, "VALIDATION_ERROR");
});

Deno.test("create-sale EF: admin allowed to create sale for cashier", async () => {
  const response = await handleCreateSale(
    makeRequest("/pos-sales/create-sale", {
      ...saleInput({ cashier_user_id: CASHIER_ID }),
    }),
    makeDeps({
      validateAuth: (_req, requiredRole) => {
        assertEquals(requiredRole, ["cashier", "admin"]);
        return Promise.resolve({
          user: { id: ADMIN_ID, email: "admin@test.com" },
          companyId: COMPANY_ID,
          role: "admin",
        });
      },
    }),
  );

  const body = await response.json();
  assertEquals(response.status, 200);
  assertEquals(body.success, true);
  assertEquals(body.data.status, "completed");
});

// ---------------------------------------------------------------------------
// cancel-sale Edge Function tests (PR3)
// ---------------------------------------------------------------------------

Deno.test("cancel-sale EF: cashier allowed, correct RPC name, server-derived payload", async () => {
  let capturedRpcName = "";
  let capturedPayload: Record<string, unknown> | undefined;

  const response = await handleCancelSale(
    makeRequest("/pos-sales/cancel-sale", {
      sale_id: SALE_ID,
      reason: "Customer changed mind",
      actor_user_id: SPOOFED_USER_ID,
      company_id: SPOOFED_COMPANY_ID,
    }),
    makeDeps({
      createServiceClient: () => ({
        rpc: (rpcName, args) => {
          capturedRpcName = rpcName;
          capturedPayload = args.p;
          return Promise.resolve({
            data: {
              sale_id: SALE_ID,
              status: "cancelled",
              reversed_items: 2,
            },
            error: null,
          });
        },
      }),
    }),
  );

  const body = await response.json();
  assertEquals(response.status, 200);
  assertEquals(capturedRpcName, "cancel_sale_transaction");
  assertEquals(capturedPayload?.company_id, COMPANY_ID);
  assertEquals(capturedPayload?.actor_user_id, CASHIER_ID);
  assertEquals(capturedPayload?.sale_id, SALE_ID);
  assertEquals(body.success, true);
  assertEquals(body.data.status, "cancelled");
  assertEquals(body.data.reversed_items, 2);
});

Deno.test("cancel-sale EF: admin allowed", async () => {
  const response = await handleCancelSale(
    makeRequest("/pos-sales/cancel-sale", {
      sale_id: SALE_ID,
      reason: "Voided by manager",
    }),
    makeDeps({
      validateAuth: (_req, requiredRole) => {
        assertEquals(requiredRole, ["cashier", "admin"]);
        return Promise.resolve({
          user: { id: ADMIN_ID, email: "admin@test.com" },
          companyId: COMPANY_ID,
          role: "admin",
        });
      },
    }),
  );

  const body = await response.json();
  assertEquals(response.status, 200);
  assertEquals(body.success, true);
  assertEquals(body.data.status, "cancelled");
});

// ---------------------------------------------------------------------------
// authorize-discount Edge Function tests (PR4)
// ---------------------------------------------------------------------------

Deno.test("authorize-discount EF: unauthenticated request includes CORS headers", async () => {
  const response = await handleAuthorizeDiscount(
    makeRequest("/pos-sales/authorize-discount", {
      sale_id: SALE_ID,
      discount_percent: 10,
      discount_amount: 5,
      reason: "Manager override",
    }),
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

Deno.test("authorize-discount EF: cashier forbidden (admin-only)", async () => {
  const response = await handleAuthorizeDiscount(
    makeRequest("/pos-sales/authorize-discount", {
      sale_id: SALE_ID,
      discount_percent: 10,
      discount_amount: 5,
      reason: "Manager override",
    }),
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

Deno.test("authorize-discount EF: admin allowed, correct RPC name, server-derived payload", async () => {
  let capturedRpcName = "";
  let capturedPayload: Record<string, unknown> | undefined;

  const response = await handleAuthorizeDiscount(
    makeRequest("/pos-sales/authorize-discount", {
      sale_id: SALE_ID,
      discount_percent: 10,
      discount_amount: 5,
      reason: "Manager override",
      actor_user_id: SPOOFED_USER_ID,
      company_id: SPOOFED_COMPANY_ID,
    }),
    makeDeps({
      validateAuth: (_req, requiredRole) => {
        assertEquals(requiredRole, ["admin"]);
        return Promise.resolve({
          user: { id: ADMIN_ID, email: "admin@test.com" },
          companyId: COMPANY_ID,
          role: "admin",
        });
      },
      createServiceClient: () => ({
        rpc: (rpcName, args) => {
          capturedRpcName = rpcName;
          capturedPayload = args.p;
          return Promise.resolve({
            data: {
              authorization_id: "00000000-0000-0000-0000-000000000008",
              sale_id: args.p.sale_id,
              authorized_at: "2025-01-01T00:00:00Z",
            },
            error: null,
          });
        },
      }),
    }),
  );

  const body = await response.json();
  assertEquals(response.status, 200);
  assertEquals(capturedRpcName, "authorize_discount");
  assertEquals(capturedPayload?.company_id, COMPANY_ID);
  assertEquals(capturedPayload?.actor_user_id, ADMIN_ID);
  assertEquals(capturedPayload?.sale_id, SALE_ID);
  assertEquals(body.success, true);
  assertEquals(body.data.sale_id, SALE_ID);
  assertEquals(body.data.authorization_id, "00000000-0000-0000-0000-000000000008");
});

Deno.test("authorize-discount EF: requires admin role", async () => {
  let roleChecked = false;

  const response = await handleAuthorizeDiscount(
    makeRequest("/pos-sales/authorize-discount", {
      sale_id: SALE_ID,
      discount_percent: 10,
      discount_amount: 5,
      reason: "Manager override",
    }),
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
  assertEquals(body.data.sale_id, SALE_ID);
});
