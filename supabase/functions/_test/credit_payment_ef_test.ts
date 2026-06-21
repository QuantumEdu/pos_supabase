// Deno test: register-payment Edge Function (PR2)
// Validates the 8-step critical-op pattern for credit-payment registration.
// (source: RCP7, RCP8, D5)

import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { corsHeaders } from "../_shared/cors.ts";
import { AUTH_ERRORS, errorResponse } from "../_shared/auth.ts";
import { RegisterCustomerPaymentRequest } from "../_shared/credit_payment_schemas.ts";
import type { CreditPaymentHandlerDeps } from "../_shared/credit_payment_handler.ts";
import { fail } from "../_shared/types.ts";
import { handleRegisterCustomerPayment } from "../register-payment/index.ts";

// ---------------------------------------------------------------------------
// Test constants
// ---------------------------------------------------------------------------

const COMPANY_ID = "00000000-0000-0000-0000-000000000001";
const BALANCE_ID = "00000000-0000-0000-0000-000000000002";
const ADMIN_ID = "00000000-0000-0000-0000-000000000010";
const CASHIER_ID = "00000000-0000-0000-0000-000000000004";
const SPOOFED_COMPANY_ID = "00000000-0000-0000-0000-000000000099";
const SPOOFED_USER_ID = "00000000-0000-0000-0000-000000000088";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function makeRequest(body: Record<string, unknown>): Request {
  return new Request("http://localhost/register-payment", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
}

function makeDeps(overrides: Partial<CreditPaymentHandlerDeps> = {}): CreditPaymentHandlerDeps {
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
            payment_id: "00000000-0000-0000-0000-000000000020",
            balance_id: args.p.balance_id,
            amount_paid: args.p.amount,
            new_paid_amount: args.p.amount,
            new_remaining_amount: 500 - Number(args.p.amount),
            new_status: Number(args.p.amount) >= 500 ? "paid" : "partial",
          },
          error: null,
        }),
    }),
    ...overrides,
  };
}

// ---------------------------------------------------------------------------
// Zod schema validation tests (step 5)
// ---------------------------------------------------------------------------

Deno.test("RegisterCustomerPaymentRequest: valid input passes and strips spoofed auth fields", () => {
  const result = RegisterCustomerPaymentRequest.safeParse({
    balance_id: BALANCE_ID,
    amount: 100,
    payment_method: "cash",
    reference: "Invoice #42",
    actor_user_id: SPOOFED_USER_ID,
    company_id: SPOOFED_COMPANY_ID,
  });

  assertEquals(result.success, true);
  if (result.success) {
    assertEquals("actor_user_id" in result.data, false);
    assertEquals("company_id" in result.data, false);
    assertEquals(result.data.balance_id, BALANCE_ID);
    assertEquals(result.data.amount, 100);
    assertEquals(result.data.payment_method, "cash");
    assertEquals(result.data.reference, "Invoice #42");
  }
});

Deno.test("RegisterCustomerPaymentRequest: valid input without optional reference", () => {
  const result = RegisterCustomerPaymentRequest.safeParse({
    balance_id: BALANCE_ID,
    amount: 50,
    payment_method: "card",
  });

  assertEquals(result.success, true);
  if (result.success) {
    assertEquals(result.data.reference, undefined);
  }
});

Deno.test("RegisterCustomerPaymentRequest: invalid payment_method fails", () => {
  const result = RegisterCustomerPaymentRequest.safeParse({
    balance_id: BALANCE_ID,
    amount: 100,
    payment_method: "credit",
  });

  assertEquals(result.success, false);
});

Deno.test("RegisterCustomerPaymentRequest: zero amount fails (must be positive)", () => {
  const result = RegisterCustomerPaymentRequest.safeParse({
    balance_id: BALANCE_ID,
    amount: 0,
    payment_method: "cash",
  });

  assertEquals(result.success, false);
});

Deno.test("RegisterCustomerPaymentRequest: negative amount fails", () => {
  const result = RegisterCustomerPaymentRequest.safeParse({
    balance_id: BALANCE_ID,
    amount: -10,
    payment_method: "cash",
  });

  assertEquals(result.success, false);
});

Deno.test("RegisterCustomerPaymentRequest: invalid UUID for balance_id fails", () => {
  const result = RegisterCustomerPaymentRequest.safeParse({
    balance_id: "not-a-uuid",
    amount: 100,
    payment_method: "cash",
  });

  assertEquals(result.success, false);
});

Deno.test("RegisterCustomerPaymentRequest: missing balance_id fails", () => {
  const result = RegisterCustomerPaymentRequest.safeParse({
    amount: 100,
    payment_method: "cash",
  });

  assertEquals(result.success, false);
});

Deno.test("RegisterCustomerPaymentRequest: blank reference is rejected (trim.min(1))", () => {
  const result = RegisterCustomerPaymentRequest.safeParse({
    balance_id: BALANCE_ID,
    amount: 100,
    payment_method: "transfer",
    reference: "   ",
  });

  assertEquals(result.success, false);
});

Deno.test("RegisterCustomerPaymentRequest: all three payment methods accepted", () => {
  for (const method of ["cash", "card", "transfer"] as const) {
    const result = RegisterCustomerPaymentRequest.safeParse({
      balance_id: BALANCE_ID,
      amount: 50,
      payment_method: method,
    });
    assertEquals(result.success, true);
  }
});

// ---------------------------------------------------------------------------
// 8-step EF validation tests
// ---------------------------------------------------------------------------

Deno.test("register-payment EF: CORS preflight returns 200 with CORS headers", async () => {
  const req = new Request("http://localhost/register-payment", { method: "OPTIONS" });
  const response = await handleRegisterCustomerPayment(req, makeDeps());

  assertEquals(response.status, 200);
  assertEquals(
    response.headers.get("Access-Control-Allow-Origin"),
    corsHeaders["Access-Control-Allow-Origin"],
  );
});

Deno.test("register-payment EF: unauthenticated request rejected at step 2 with CORS headers", async () => {
  const response = await handleRegisterCustomerPayment(
    makeRequest({
      balance_id: BALANCE_ID,
      amount: 100,
      payment_method: "cash",
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

Deno.test("register-payment EF: non-admin role rejected at step 4 (FORBIDDEN) with CORS headers", async () => {
  const response = await handleRegisterCustomerPayment(
    makeRequest({
      balance_id: BALANCE_ID,
      amount: 100,
      payment_method: "cash",
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

Deno.test("register-payment EF: admin role is allowed", async () => {
  let roleChecked = false;

  const response = await handleRegisterCustomerPayment(
    makeRequest({
      balance_id: BALANCE_ID,
      amount: 100,
      payment_method: "cash",
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
});

Deno.test("register-payment EF: cashier role is rejected (admin-only)", async () => {
  const response = await handleRegisterCustomerPayment(
    makeRequest({
      balance_id: BALANCE_ID,
      amount: 100,
      payment_method: "cash",
    }),
    makeDeps({
      validateAuth: () => Promise.reject(errorResponse(403, AUTH_ERRORS.INSUFFICIENT_ROLE)),
    }),
  );

  assertEquals(response.status, 403);
});

Deno.test("register-payment EF: invalid input rejected at step 5 (Zod)", async () => {
  const response = await handleRegisterCustomerPayment(
    makeRequest({
      balance_id: "not-a-uuid",
      amount: -5,
      payment_method: "bitcoin",
    }),
    makeDeps(),
  );

  const body = await response.json();
  assertEquals(response.status, 400);
  assertEquals(body.success, false);
  assertEquals(body.error.code, "VALIDATION_ERROR");
});

Deno.test("register-payment EF: correct RPC name and server-derived payload (step 5-6)", async () => {
  let capturedRpcName = "";
  let capturedPayload: Record<string, unknown> | undefined;

  const response = await handleRegisterCustomerPayment(
    makeRequest({
      balance_id: BALANCE_ID,
      amount: 150,
      payment_method: "transfer",
      reference: "Bank transfer #REF123",
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
              payment_id: "00000000-0000-0000-0000-000000000020",
              balance_id: args.p.balance_id,
              amount_paid: args.p.amount,
              new_paid_amount: args.p.amount,
              new_remaining_amount: 350,
              new_status: "partial",
            },
            error: null,
          });
        },
      }),
    }),
  );

  const body = await response.json();
  assertEquals(response.status, 200);
  assertEquals(capturedRpcName, "register_customer_payment_transaction");
  assertEquals(capturedPayload?.company_id, COMPANY_ID);
  assertEquals(capturedPayload?.actor_user_id, ADMIN_ID);
  assertEquals(capturedPayload?.balance_id, BALANCE_ID);
  assertEquals(capturedPayload?.amount, 150);
  assertEquals(capturedPayload?.payment_method, "transfer");
  assertEquals(capturedPayload?.reference, "Bank transfer #REF123");
  assertEquals(body.success, true);
  assertEquals(body.data.payment_id, "00000000-0000-0000-0000-000000000020");
  assertEquals(body.data.new_status, "partial");
});

Deno.test("register-payment EF: RPC error returned as EFResult error", async () => {
  const response = await handleRegisterCustomerPayment(
    makeRequest({
      balance_id: BALANCE_ID,
      amount: 99999,
      payment_method: "cash",
    }),
    makeDeps({
      createServiceClient: () => ({
        rpc: () =>
          Promise.resolve({
            data: null,
            error: { code: "VALIDATION_ERROR", message: "Payment amount exceeds remaining balance" },
          }),
      }),
    }),
  );

  const body = await response.json();
  assertEquals(response.status, 400);
  assertEquals(body.success, false);
  assertEquals(body.error.code, "VALIDATION_ERROR");
});

Deno.test("register-payment EF: missing service config returns 500", async () => {
  const response = await handleRegisterCustomerPayment(
    makeRequest({
      balance_id: BALANCE_ID,
      amount: 100,
      payment_method: "cash",
    }),
    makeDeps({
      createServiceClient: () => null,
    }),
  );

  const body = await response.json();
  assertEquals(response.status, 500);
  assertEquals(body.success, false);
  assertEquals(body.error.code, "SERVER_ERROR");
});