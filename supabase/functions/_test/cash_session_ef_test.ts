// Deno test: cash session Edge Functions (PR3 + PR4)

import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { corsHeaders } from "../_shared/cors.ts";
import { AUTH_ERRORS, errorResponse } from "../_shared/auth.ts";
import {
  CloseCashSessionRequest,
  ForceCloseCashSessionRequest,
  OpenCashSessionRequest,
  RecordManualMovementRequest,
} from "../_shared/cash_session_schemas.ts";
import type { CashSessionHandlerDeps } from "../_shared/cash_session_handler.ts";
import { fail } from "../_shared/types.ts";
import { handleCloseCashSession } from "../cash-session/close-session/index.ts";
import { handleOpenCashSession } from "../cash-session/open-session/index.ts";
import { handleRecordManualMovement } from "../cash-session/record-manual-movement/index.ts";
import { handleForceCloseCashSession } from "../cash-session/force-close-session/index.ts";

const COMPANY_ID = "00000000-0000-0000-0000-000000000001";
const BRANCH_ID = "00000000-0000-0000-0000-000000000002";
const SESSION_ID = "00000000-0000-0000-0000-000000000003";
const CASHIER_ID = "00000000-0000-0000-0000-000000000004";
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

function makeDeps(overrides: Partial<CashSessionHandlerDeps> = {}): CashSessionHandlerDeps {
  return {
    validateAuth: (_req, _requiredRole) => Promise.resolve({
      user: { id: CASHIER_ID, email: "cashier@test.com" },
      companyId: COMPANY_ID,
      role: "cashier",
    }),
    createServiceClient: () => ({
      rpc: (rpcName: string, args: { p: Record<string, unknown> }) => Promise.resolve({
        data: rpcName === "open_cash_session"
          ? {
            cash_session_id: SESSION_ID,
            movement_id: "00000000-0000-0000-0000-000000000005",
            status: "open",
            expected_cash_amount: args.p.opening_amount,
          }
          : {
            cash_session_id: SESSION_ID,
            status: "closed",
            expected_cash_amount: 120,
            counted_cash_amount: args.p.counted_cash_amount,
            difference_amount: Number(args.p.counted_cash_amount) - 120,
          },
        error: null,
      }),
    }),
    ...overrides,
  };
}

Deno.test("OpenCashSessionRequest: valid input passes and strips spoofed auth fields", () => {
  const result = OpenCashSessionRequest.safeParse({
    branch_id: BRANCH_ID,
    opening_amount: 100,
    actor_user_id: SPOOFED_USER_ID,
    company_id: SPOOFED_COMPANY_ID,
  });

  assertEquals(result.success, true);
  if (result.success) {
    assertEquals("actor_user_id" in result.data, false);
    assertEquals("company_id" in result.data, false);
  }
});

Deno.test("OpenCashSessionRequest: negative opening amount fails", () => {
  const result = OpenCashSessionRequest.safeParse({
    branch_id: BRANCH_ID,
    opening_amount: -1,
  });

  assertEquals(result.success, false);
});

Deno.test("CloseCashSessionRequest: valid input passes and strips spoofed auth fields", () => {
  const result = CloseCashSessionRequest.safeParse({
    cash_session_id: SESSION_ID,
    counted_cash_amount: 125,
    actor_user_id: SPOOFED_USER_ID,
    company_id: SPOOFED_COMPANY_ID,
  });

  assertEquals(result.success, true);
  if (result.success) {
    assertEquals("actor_user_id" in result.data, false);
    assertEquals("company_id" in result.data, false);
  }
});

Deno.test("CloseCashSessionRequest: negative counted amount fails", () => {
  const result = CloseCashSessionRequest.safeParse({
    cash_session_id: SESSION_ID,
    counted_cash_amount: -1,
  });

  assertEquals(result.success, false);
});

Deno.test("open-session EF: unauthenticated request includes CORS headers", async () => {
  const response = await handleOpenCashSession(
    makeRequest("/cash-session/open-session", {
      branch_id: BRANCH_ID,
      opening_amount: 100,
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

Deno.test("open-session EF: forbidden role includes CORS headers", async () => {
  const response = await handleOpenCashSession(
    makeRequest("/cash-session/open-session", {
      branch_id: BRANCH_ID,
      opening_amount: 100,
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

Deno.test("open-session EF: cashier allowed, correct RPC name, and server-derived payload", async () => {
  let capturedRpcName = "";
  let capturedPayload: Record<string, unknown> | undefined;

  const response = await handleOpenCashSession(
    makeRequest("/cash-session/open-session", {
      branch_id: BRANCH_ID,
      opening_amount: 100,
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
              cash_session_id: SESSION_ID,
              movement_id: "00000000-0000-0000-0000-000000000005",
              status: "open",
              expected_cash_amount: args.p.opening_amount,
            },
            error: null,
          });
        },
      }),
    }),
  );

  const body = await response.json();
  assertEquals(response.status, 200);
  assertEquals(capturedRpcName, "open_cash_session");
  assertEquals(capturedPayload?.company_id, COMPANY_ID);
  assertEquals(capturedPayload?.actor_user_id, CASHIER_ID);
  assertEquals(capturedPayload?.branch_id, BRANCH_ID);
  assertEquals(body.success, true);
  assertEquals(body.data.cash_session_id, SESSION_ID);
});

Deno.test("open-session EF: admin allowed to open for cashier", async () => {
  const response = await handleOpenCashSession(
    makeRequest("/cash-session/open-session", {
      branch_id: BRANCH_ID,
      cashier_user_id: CASHIER_ID,
      opening_amount: 80,
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
  assertEquals(body.data.status, "open");
});

Deno.test("close-session EF: cashier allowed, correct RPC name, and EFResult shape", async () => {
  let capturedRpcName = "";
  let capturedPayload: Record<string, unknown> | undefined;

  const response = await handleCloseCashSession(
    makeRequest("/cash-session/close-session", {
      cash_session_id: SESSION_ID,
      counted_cash_amount: 125,
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
              cash_session_id: SESSION_ID,
              status: "closed",
              expected_cash_amount: 120,
              counted_cash_amount: args.p.counted_cash_amount,
              difference_amount: Number(args.p.counted_cash_amount) - 120,
            },
            error: null,
          });
        },
      }),
    }),
  );

  const body = await response.json();
  assertEquals(response.status, 200);
  assertEquals(capturedRpcName, "close_cash_session");
  assertEquals(capturedPayload?.company_id, COMPANY_ID);
  assertEquals(capturedPayload?.actor_user_id, CASHIER_ID);
  assertEquals(capturedPayload?.cash_session_id, SESSION_ID);
  assertEquals(body.success, true);
  assertEquals(body.data.status, "closed");
  assertEquals(body.data.counted_cash_amount, 125);
});

Deno.test("close-session EF: admin auth is allowed by handler", async () => {
  const response = await handleCloseCashSession(
    makeRequest("/cash-session/close-session", {
      cash_session_id: SESSION_ID,
      counted_cash_amount: 125,
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
});

Deno.test("close-session EF: admin reaches RPC before RPC semantics apply", async () => {
  let rpcCalled = false;
  let capturedPayload: Record<string, unknown> | undefined;

  const response = await handleCloseCashSession(
    makeRequest("/cash-session/close-session", {
      cash_session_id: SESSION_ID,
      counted_cash_amount: 125,
    }),
    {
      validateAuth: (_req, requiredRole) => {
        assertEquals(requiredRole, ["cashier", "admin"]);
        return Promise.resolve({
          user: { id: ADMIN_ID, email: "admin@test.com" },
          companyId: COMPANY_ID,
          role: "admin",
        });
      },
      createServiceClient: () => ({
        rpc: (_rpcName, args) => {
          rpcCalled = true;
          capturedPayload = args.p;
          return Promise.resolve({
            data: {
              cash_session_id: SESSION_ID,
              status: "closed",
              expected_cash_amount: 120,
              counted_cash_amount: args.p.counted_cash_amount,
              difference_amount: Number(args.p.counted_cash_amount) - 120,
            },
            error: null,
          });
        },
      }),
    },
  );

  const body = await response.json();
  assertEquals(response.status, 200);
  assertEquals(rpcCalled, true);
  assertEquals(capturedPayload?.actor_user_id, ADMIN_ID);
  assertEquals(capturedPayload?.company_id, COMPANY_ID);
  assertEquals(body.success, true);
});

// ---------------------------------------------------------------------------
// RecordManualMovement tests (PR4)
// ---------------------------------------------------------------------------

function makeManualMovementDeps(
  overrides: Partial<CashSessionHandlerDeps> = {},
): CashSessionHandlerDeps {
  return {
    validateAuth: (_req, _requiredRole) => Promise.resolve({
      user: { id: CASHIER_ID, email: "cashier@test.com" },
      companyId: COMPANY_ID,
      role: "cashier",
    }),
    createServiceClient: () => ({
      rpc: (_rpcName, args) => Promise.resolve({
        data: {
          cash_session_id: SESSION_ID,
          movement_id: "00000000-0000-0000-0000-000000000006",
          movement_type: args.p.movement_type,
          expected_cash_amount: args.p.amount + 100,
        },
        error: null,
      }),
    }),
    ...overrides,
  };
}

Deno.test("RecordManualMovementRequest: valid input passes and strips spoofed auth fields", () => {
  const result = RecordManualMovementRequest.safeParse({
    cash_session_id: SESSION_ID,
    movement_type: "manual_cash_in",
    amount: 50,
    actor_user_id: SPOOFED_USER_ID,
    company_id: SPOOFED_COMPANY_ID,
  });

  assertEquals(result.success, true);
  if (result.success) {
    assertEquals("actor_user_id" in result.data, false);
    assertEquals("company_id" in result.data, false);
  }
});

Deno.test("RecordManualMovementRequest: invalid movement type fails", () => {
  const result = RecordManualMovementRequest.safeParse({
    cash_session_id: SESSION_ID,
    movement_type: "invalid_type",
    amount: 50,
  });

  assertEquals(result.success, false);
});

Deno.test("RecordManualMovementRequest: zero amount fails (must be positive)", () => {
  const result = RecordManualMovementRequest.safeParse({
    cash_session_id: SESSION_ID,
    movement_type: "manual_cash_in",
    amount: 0,
  });

  assertEquals(result.success, false);
});

Deno.test("ForceCloseCashSessionRequest: valid input passes and strips spoofed auth fields", () => {
  const result = ForceCloseCashSessionRequest.safeParse({
    cash_session_id: SESSION_ID,
    counted_cash_amount: 100,
    reason: "Emergency close",
    actor_user_id: SPOOFED_USER_ID,
    company_id: SPOOFED_COMPANY_ID,
  });

  assertEquals(result.success, true);
  if (result.success) {
    assertEquals("actor_user_id" in result.data, false);
    assertEquals("company_id" in result.data, false);
  }
});

Deno.test("ForceCloseCashSessionRequest: negative counted amount fails", () => {
  const result = ForceCloseCashSessionRequest.safeParse({
    cash_session_id: SESSION_ID,
    counted_cash_amount: -1,
  });

  assertEquals(result.success, false);
});

Deno.test("record-manual-movement EF: unauthenticated request includes CORS headers", async () => {
  const response = await handleRecordManualMovement(
    makeRequest("/cash-session/record-manual-movement", {
      cash_session_id: SESSION_ID,
      movement_type: "manual_cash_in",
      amount: 50,
    }),
    {
      validateAuth: () => Promise.reject(errorResponse(401, AUTH_ERRORS.NO_AUTH_HEADER)),
    },
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

Deno.test("record-manual-movement EF: forbidden role includes CORS headers", async () => {
  const response = await handleRecordManualMovement(
    makeRequest("/cash-session/record-manual-movement", {
      cash_session_id: SESSION_ID,
      movement_type: "manual_cash_in",
      amount: 50,
    }),
    {
      validateAuth: () => Promise.reject(errorResponse(403, AUTH_ERRORS.INSUFFICIENT_ROLE)),
    },
  );

  const body = await response.json();
  assertEquals(response.status, 403);
  assertEquals(body, fail("FORBIDDEN", "Insufficient permissions"));
  assertEquals(
    response.headers.get("Access-Control-Allow-Origin"),
    corsHeaders["Access-Control-Allow-Origin"],
  );
});

Deno.test("record-manual-movement EF: cashier allowed, correct RPC name, server-derived payload, and movement_type tracked", async () => {
  let capturedRpcName = "";
  let capturedPayload: Record<string, unknown> | undefined;

  const response = await handleRecordManualMovement(
    makeRequest("/cash-session/record-manual-movement", {
      cash_session_id: SESSION_ID,
      movement_type: "manual_cash_out",
      amount: 30,
      reason: "Petty cash withdrawal",
    }),
    makeManualMovementDeps({
      createServiceClient: () => ({
        rpc: (rpcName, args) => {
          capturedRpcName = rpcName;
          capturedPayload = args.p;
          return Promise.resolve({
            data: {
              cash_session_id: SESSION_ID,
              movement_id: "00000000-0000-0000-0000-000000000006",
              movement_type: args.p.movement_type,
              expected_cash_amount: 100 - args.p.amount,
            },
            error: null,
          });
        },
      }),
    }),
  );

  const body = await response.json();
  assertEquals(response.status, 200);
  assertEquals(capturedRpcName, "record_cash_movement");
  assertEquals(capturedPayload?.company_id, COMPANY_ID);
  assertEquals(capturedPayload?.actor_user_id, CASHIER_ID);
  assertEquals(capturedPayload?.movement_type, "manual_cash_out");
  assertEquals(capturedPayload?.amount, 30);
  assertEquals(body.success, true);
  assertEquals(body.data.movement_type, "manual_cash_out");
});

Deno.test("record-manual-movement EF: admin allowed", async () => {
  const response = await handleRecordManualMovement(
    makeRequest("/cash-session/record-manual-movement", {
      cash_session_id: SESSION_ID,
      movement_type: "manual_cash_in",
      amount: 100,
    }),
    {
      validateAuth: (_req, requiredRole) => {
        assertEquals(requiredRole, ["cashier", "admin"]);
        return Promise.resolve({
          user: { id: ADMIN_ID, email: "admin@test.com" },
          companyId: COMPANY_ID,
          role: "admin",
        });
      },
      createServiceClient: () => ({
        rpc: (_rpcName, args) => Promise.resolve({
          data: {
            cash_session_id: SESSION_ID,
            movement_id: "00000000-0000-0000-0000-000000000007",
            movement_type: args.p.movement_type,
            expected_cash_amount: 200,
          },
          error: null,
        }),
      }),
    },
  );

  const body = await response.json();
  assertEquals(response.status, 200);
  assertEquals(body.success, true);
  assertEquals(body.data.movement_type, "manual_cash_in");
});

// ---------------------------------------------------------------------------
// ForceCloseCashSession tests (PR4)
// ---------------------------------------------------------------------------

function makeForceCloseDeps(
  overrides: Partial<CashSessionHandlerDeps> = {},
): CashSessionHandlerDeps {
  return {
    validateAuth: (_req, _requiredRole) => Promise.resolve({
      user: { id: ADMIN_ID, email: "admin@test.com" },
      companyId: COMPANY_ID,
      role: "admin",
    }),
    createServiceClient: () => ({
      rpc: (_rpcName, args) => Promise.resolve({
        data: {
          cash_session_id: SESSION_ID,
          status: "closed",
          expected_cash_amount: 120,
          counted_cash_amount: args.p.counted_cash_amount,
          difference_amount: Number(args.p.counted_cash_amount) - 120,
          forced: true,
        },
        error: null,
      }),
    }),
    ...overrides,
  };
}

Deno.test("force-close-session EF: unauthenticated request includes CORS headers", async () => {
  const response = await handleForceCloseCashSession(
    makeRequest("/cash-session/force-close-session", {
      cash_session_id: SESSION_ID,
      counted_cash_amount: 100,
    }),
    {
      validateAuth: () => Promise.reject(errorResponse(401, AUTH_ERRORS.NO_AUTH_HEADER)),
    },
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

Deno.test("force-close-session EF: cashier forbidden (admin-only)", async () => {
  const response = await handleForceCloseCashSession(
    makeRequest("/cash-session/force-close-session", {
      cash_session_id: SESSION_ID,
      counted_cash_amount: 100,
    }),
    {
      validateAuth: () => Promise.reject(errorResponse(403, AUTH_ERRORS.INSUFFICIENT_ROLE)),
    },
  );

  const body = await response.json();
  assertEquals(response.status, 403);
  assertEquals(body, fail("FORBIDDEN", "Insufficient permissions"));
  assertEquals(
    response.headers.get("Access-Control-Allow-Origin"),
    corsHeaders["Access-Control-Allow-Origin"],
  );
});

Deno.test("force-close-session EF: requires admin role", async () => {
  let roleChecked = false;

  const response = await handleForceCloseCashSession(
    makeRequest("/cash-session/force-close-session", {
      cash_session_id: SESSION_ID,
      counted_cash_amount: 100,
      reason: "Emergency",
    }),
    {
      validateAuth: (_req, requiredRole) => {
        roleChecked = true;
        assertEquals(requiredRole, ["admin"]);
        return Promise.resolve({
          user: { id: ADMIN_ID, email: "admin@test.com" },
          companyId: COMPANY_ID,
          role: "admin",
        });
      },
      createServiceClient: () => ({
        rpc: (_rpcName, args) => Promise.resolve({
          data: {
            cash_session_id: SESSION_ID,
            status: "closed",
            expected_cash_amount: 120,
            counted_cash_amount: args.p.counted_cash_amount,
            difference_amount: Number(args.p.counted_cash_amount) - 120,
            forced: true,
          },
          error: null,
        }),
      }),
    },
  );

  const body = await response.json();
  assertEquals(roleChecked, true);
  assertEquals(response.status, 200);
  assertEquals(body.success, true);
  assertEquals(body.data.forced, true);
  assertEquals(body.data.status, "closed");
});

Deno.test("force-close-session EF: correct RPC name and server-derived payload", async () => {
  let capturedRpcName = "";
  let capturedPayload: Record<string, unknown> | undefined;

  const response = await handleForceCloseCashSession(
    makeRequest("/cash-session/force-close-session", {
      cash_session_id: SESSION_ID,
      counted_cash_amount: 100,
    }),
    {
      validateAuth: (_req, _requiredRole) => Promise.resolve({
        user: { id: ADMIN_ID, email: "admin@test.com" },
        companyId: COMPANY_ID,
        role: "admin",
      }),
      createServiceClient: () => ({
        rpc: (rpcName, args) => {
          capturedRpcName = rpcName;
          capturedPayload = args.p;
          return Promise.resolve({
            data: {
              cash_session_id: SESSION_ID,
              status: "closed",
              expected_cash_amount: 120,
              counted_cash_amount: args.p.counted_cash_amount,
              difference_amount: Number(args.p.counted_cash_amount) - 120,
              forced: true,
            },
            error: null,
          });
        },
      }),
    },
  );

  const body = await response.json();
  assertEquals(response.status, 200);
  assertEquals(capturedRpcName, "force_close_cash_session");
  assertEquals(capturedPayload?.company_id, COMPANY_ID);
  assertEquals(capturedPayload?.actor_user_id, ADMIN_ID);
  assertEquals(capturedPayload?.cash_session_id, SESSION_ID);
  assertEquals(body.success, true);
  assertEquals(body.data.forced, true);
  assertEquals(body.data.status, "closed");
});
