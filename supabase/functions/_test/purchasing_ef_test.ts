// Deno test: purchasing Edge Functions
// (source: RP13 — EF test requirements; DP1 — single RPC call)
//
// Tests schema validation, auth rejection, admin RPC invocation,
// EFResult shape, and single-RPC-call contract for receive-purchase-order.

import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  CreatePurchaseOrderRequest,
  ReceivePurchaseOrderRequest,
  CancelPurchaseOrderRequest,
  ManageSupplierRequest,
} from "../_shared/purchasing_schemas.ts";
import type { PurchasingHandlerDeps } from "../_shared/purchasing_handler.ts";
import { handleCreatePurchaseOrder } from "../purchasing/create-purchase-order/index.ts";
import { handleReceivePurchaseOrder } from "../purchasing/receive-purchase-order/index.ts";
import { handleCancelPurchaseOrder } from "../purchasing/cancel-purchase-order/index.ts";
import { handleManageSupplier } from "../purchasing/manage-supplier/index.ts";
import { fail } from "../_shared/types.ts";

const COMPANY_ID = "00000000-0000-0000-0000-000000000001";
const BRANCH_ID = "00000000-0000-0000-0000-000000000002";
const SUPPLIER_ID = "00000000-0000-0000-0000-000000000003";
const VARIANT_ID = "00000000-0000-0000-0000-000000000004";
const PO_ID = "00000000-0000-0000-0000-000000000005";
const PO_ITEM_ID = "00000000-0000-0000-0000-000000000006";

function makeRequest(body: Record<string, unknown>): Request {
  return new Request("http://localhost/purchasing/test", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
}

function makeDeps(overrides: Partial<PurchasingHandlerDeps> = {}): PurchasingHandlerDeps {
  return {
    validateAuth: () => Promise.resolve({
      user: { id: "user-1", email: "admin@test.com" },
      companyId: COMPANY_ID,
      role: "admin",
    }),
    createServiceClient: () => ({
      rpc: (_rpcName: string, _args: { p: Record<string, unknown> }) => Promise.resolve({
        data: { ok: true },
        error: null,
      }),
    }),
    ...overrides,
  };
}

// =========================================================================
// Schema Validation: CreatePurchaseOrderRequest
// =========================================================================

Deno.test("CreatePurchaseOrderRequest: valid input passes", () => {
  const result = CreatePurchaseOrderRequest.safeParse({
    company_id: COMPANY_ID,
    branch_id: BRANCH_ID,
    supplier_id: SUPPLIER_ID,
    order_number: "PO-001",
    items: [{ variant_id: VARIANT_ID, ordered_qty: 10, unit_cost: 100 }],
  });
  assertEquals(result.success, true);
});

Deno.test("CreatePurchaseOrderRequest: invalid UUID fails", () => {
  const result = CreatePurchaseOrderRequest.safeParse({
    company_id: "not-a-uuid",
    branch_id: BRANCH_ID,
    supplier_id: SUPPLIER_ID,
    order_number: "PO-001",
    items: [{ variant_id: VARIANT_ID, ordered_qty: 10, unit_cost: 100 }],
  });
  assertEquals(result.success, false);
});

Deno.test("CreatePurchaseOrderRequest: empty items fails", () => {
  const result = CreatePurchaseOrderRequest.safeParse({
    company_id: COMPANY_ID,
    branch_id: BRANCH_ID,
    supplier_id: SUPPLIER_ID,
    order_number: "PO-001",
    items: [],
  });
  assertEquals(result.success, false);
});

Deno.test("CreatePurchaseOrderRequest: zero qty fails", () => {
  const result = CreatePurchaseOrderRequest.safeParse({
    company_id: COMPANY_ID,
    branch_id: BRANCH_ID,
    supplier_id: SUPPLIER_ID,
    order_number: "PO-001",
    items: [{ variant_id: VARIANT_ID, ordered_qty: 0, unit_cost: 100 }],
  });
  assertEquals(result.success, false);
});

Deno.test("CreatePurchaseOrderRequest: tax_rate clamped 0-1", () => {
  const result = CreatePurchaseOrderRequest.safeParse({
    company_id: COMPANY_ID,
    branch_id: BRANCH_ID,
    supplier_id: SUPPLIER_ID,
    order_number: "PO-001",
    items: [{ variant_id: VARIANT_ID, ordered_qty: 10, unit_cost: 100, tax_rate: 1.5 }],
  });
  assertEquals(result.success, false);
});

// =========================================================================
// Schema Validation: ReceivePurchaseOrderRequest
// =========================================================================

Deno.test("ReceivePurchaseOrderRequest: valid input passes", () => {
  const result = ReceivePurchaseOrderRequest.safeParse({
    company_id: COMPANY_ID,
    branch_id: BRANCH_ID,
    purchase_order_id: PO_ID,
    receipt_number: "RCV-001",
    items: [{ purchase_order_item_id: PO_ITEM_ID, received_qty: 5 }],
  });
  assertEquals(result.success, true);
});

Deno.test("ReceivePurchaseOrderRequest: empty items fails", () => {
  const result = ReceivePurchaseOrderRequest.safeParse({
    company_id: COMPANY_ID,
    branch_id: BRANCH_ID,
    purchase_order_id: PO_ID,
    receipt_number: "RCV-001",
    items: [],
  });
  assertEquals(result.success, false);
});

Deno.test("ReceivePurchaseOrderRequest: zero received_qty fails", () => {
  const result = ReceivePurchaseOrderRequest.safeParse({
    company_id: COMPANY_ID,
    branch_id: BRANCH_ID,
    purchase_order_id: PO_ID,
    receipt_number: "RCV-001",
    items: [{ purchase_order_item_id: PO_ITEM_ID, received_qty: 0 }],
  });
  assertEquals(result.success, false);
});

// =========================================================================
// Schema Validation: CancelPurchaseOrderRequest
// =========================================================================

Deno.test("CancelPurchaseOrderRequest: valid input passes", () => {
  const result = CancelPurchaseOrderRequest.safeParse({
    company_id: COMPANY_ID,
    purchase_order_id: PO_ID,
  });
  assertEquals(result.success, true);
});

Deno.test("CancelPurchaseOrderRequest: missing purchase_order_id fails", () => {
  const result = CancelPurchaseOrderRequest.safeParse({
    company_id: COMPANY_ID,
  });
  assertEquals(result.success, false);
});

// =========================================================================
// Schema Validation: ManageSupplierRequest
// =========================================================================

Deno.test("ManageSupplierRequest: valid create passes", () => {
  const result = ManageSupplierRequest.safeParse({
    company_id: COMPANY_ID,
    action: "create",
    name: "ACME Corp",
    slug: "acme-corp",
  });
  assertEquals(result.success, true);
});

Deno.test("ManageSupplierRequest: valid deactivate passes", () => {
  const result = ManageSupplierRequest.safeParse({
    company_id: COMPANY_ID,
    action: "deactivate",
    supplier_id: SUPPLIER_ID,
  });
  assertEquals(result.success, true);
});

Deno.test("ManageSupplierRequest: invalid action fails", () => {
  const result = ManageSupplierRequest.safeParse({
    company_id: COMPANY_ID,
    action: "delete",
  });
  assertEquals(result.success, false);
});

// =========================================================================
// Unauthenticated tests (all 4 EFs)
// =========================================================================

Deno.test("create-purchase-order EF: unauthenticated -> 401", async () => {
  const response = await handleCreatePurchaseOrder(
    makeRequest({
      company_id: COMPANY_ID, branch_id: BRANCH_ID, supplier_id: SUPPLIER_ID,
      order_number: "PO-001",
      items: [{ variant_id: VARIANT_ID, ordered_qty: 10, unit_cost: 100 }],
    }),
    makeDeps({
      validateAuth: () => Promise.reject(
        Response.json(fail("UNAUTHORIZED", "Missing Authorization header"), { status: 401 }),
      ),
    }),
  );
  const body = await response.json();
  assertEquals(response.status, 401);
  assertEquals(body.success, false);
  assertEquals(body.error.code, "UNAUTHORIZED");
});

Deno.test("receive-purchase-order EF: unauthenticated -> 401", async () => {
  const response = await handleReceivePurchaseOrder(
    makeRequest({
      company_id: COMPANY_ID, branch_id: BRANCH_ID, purchase_order_id: PO_ID,
      receipt_number: "RCV-001",
      items: [{ purchase_order_item_id: PO_ITEM_ID, received_qty: 5 }],
    }),
    makeDeps({
      validateAuth: () => Promise.reject(
        Response.json(fail("UNAUTHORIZED", "Missing Authorization header"), { status: 401 }),
      ),
    }),
  );
  const body = await response.json();
  assertEquals(response.status, 401);
  assertEquals(body.success, false);
});

Deno.test("cancel-purchase-order EF: unauthenticated -> 401", async () => {
  const response = await handleCancelPurchaseOrder(
    makeRequest({ company_id: COMPANY_ID, purchase_order_id: PO_ID }),
    makeDeps({
      validateAuth: () => Promise.reject(
        Response.json(fail("UNAUTHORIZED", "Missing Authorization header"), { status: 401 }),
      ),
    }),
  );
  const body = await response.json();
  assertEquals(response.status, 401);
  assertEquals(body.success, false);
});

Deno.test("manage-supplier EF: unauthenticated -> 401", async () => {
  const response = await handleManageSupplier(
    makeRequest({ company_id: COMPANY_ID, action: "create", name: "ACME", slug: "acme" }),
    makeDeps({
      validateAuth: () => Promise.reject(
        Response.json(fail("UNAUTHORIZED", "Missing Authorization header"), { status: 401 }),
      ),
    }),
  );
  const body = await response.json();
  assertEquals(response.status, 401);
  assertEquals(body.success, false);
});

// =========================================================================
// Non-admin (cashier) tests (all 4 EFs)
// =========================================================================

Deno.test("create-purchase-order EF: cashier -> 403", async () => {
  const response = await handleCreatePurchaseOrder(
    makeRequest({
      company_id: COMPANY_ID, branch_id: BRANCH_ID, supplier_id: SUPPLIER_ID,
      order_number: "PO-001",
      items: [{ variant_id: VARIANT_ID, ordered_qty: 10, unit_cost: 100 }],
    }),
    makeDeps({
      validateAuth: () => Promise.reject(
        Response.json(fail("FORBIDDEN", "Insufficient permissions"), { status: 403 }),
      ),
    }),
  );
  const body = await response.json();
  assertEquals(response.status, 403);
  assertEquals(body.success, false);
  assertEquals(body.error.code, "FORBIDDEN");
});

Deno.test("receive-purchase-order EF: cashier -> 403", async () => {
  const response = await handleReceivePurchaseOrder(
    makeRequest({
      company_id: COMPANY_ID, branch_id: BRANCH_ID, purchase_order_id: PO_ID,
      receipt_number: "RCV-001",
      items: [{ purchase_order_item_id: PO_ITEM_ID, received_qty: 5 }],
    }),
    makeDeps({
      validateAuth: () => Promise.reject(
        Response.json(fail("FORBIDDEN", "Insufficient permissions"), { status: 403 }),
      ),
    }),
  );
  const body = await response.json();
  assertEquals(response.status, 403);
  assertEquals(body.success, false);
});

Deno.test("cancel-purchase-order EF: cashier -> 403", async () => {
  const response = await handleCancelPurchaseOrder(
    makeRequest({ company_id: COMPANY_ID, purchase_order_id: PO_ID }),
    makeDeps({
      validateAuth: () => Promise.reject(
        Response.json(fail("FORBIDDEN", "Insufficient permissions"), { status: 403 }),
      ),
    }),
  );
  const body = await response.json();
  assertEquals(response.status, 403);
  assertEquals(body.success, false);
});

Deno.test("manage-supplier EF: cashier -> 403", async () => {
  const response = await handleManageSupplier(
    makeRequest({ company_id: COMPANY_ID, action: "create", name: "ACME", slug: "acme" }),
    makeDeps({
      validateAuth: () => Promise.reject(
        Response.json(fail("FORBIDDEN", "Insufficient permissions"), { status: 403 }),
      ),
    }),
  );
  const body = await response.json();
  assertEquals(response.status, 403);
  assertEquals(body.success, false);
});

// =========================================================================
// Admin valid RPC name tests (all 4 EFs)
// =========================================================================

Deno.test("create-purchase-order EF: invokes create_purchase_order RPC", async () => {
  let capturedRpcName = "";
  const response = await handleCreatePurchaseOrder(
    makeRequest({
      company_id: COMPANY_ID, branch_id: BRANCH_ID, supplier_id: SUPPLIER_ID,
      order_number: "PO-001",
      items: [{ variant_id: VARIANT_ID, ordered_qty: 10, unit_cost: 100 }],
    }),
    makeDeps({
      createServiceClient: () => ({
        rpc: (rpcName: string, _args: { p: Record<string, unknown> }) => {
          capturedRpcName = rpcName;
          return Promise.resolve({
            data: { purchase_order_id: PO_ID, order_number: "PO-001", status: "draft", items_count: 1, total: 1000 },
            error: null,
          });
        },
      }),
    }),
  );
  const body = await response.json();
  assertEquals(response.status, 200);
  assertEquals(capturedRpcName, "create_purchase_order");
  assertEquals(body.success, true);
  assertEquals(body.data.status, "draft");
});

Deno.test("receive-purchase-order EF: invokes receive_purchase_transaction RPC", async () => {
  let capturedRpcName = "";
  const response = await handleReceivePurchaseOrder(
    makeRequest({
      company_id: COMPANY_ID, branch_id: BRANCH_ID, purchase_order_id: PO_ID,
      receipt_number: "RCV-001",
      items: [{ purchase_order_item_id: PO_ITEM_ID, received_qty: 5 }],
    }),
    makeDeps({
      createServiceClient: () => ({
        rpc: (rpcName: string, _args: { p: Record<string, unknown> }) => {
          capturedRpcName = rpcName;
          return Promise.resolve({
            data: { receipt_id: "rec-1", purchase_order_id: PO_ID, po_status: "partial", lot_results: [], items_processed: 1 },
            error: null,
          });
        },
      }),
    }),
  );
  const body = await response.json();
  assertEquals(response.status, 200);
  assertEquals(capturedRpcName, "receive_purchase_transaction");
  assertEquals(body.success, true);
  assertEquals(body.data.po_status, "partial");
});

Deno.test("cancel-purchase-order EF: invokes cancel_purchase_order RPC", async () => {
  let capturedRpcName = "";
  const response = await handleCancelPurchaseOrder(
    makeRequest({ company_id: COMPANY_ID, purchase_order_id: PO_ID }),
    makeDeps({
      createServiceClient: () => ({
        rpc: (rpcName: string, _args: { p: Record<string, unknown> }) => {
          capturedRpcName = rpcName;
          return Promise.resolve({
            data: { purchase_order_id: PO_ID, previous_status: "draft", cancelled: true },
            error: null,
          });
        },
      }),
    }),
  );
  const body = await response.json();
  assertEquals(response.status, 200);
  assertEquals(capturedRpcName, "cancel_purchase_order");
  assertEquals(body.success, true);
  assertEquals(body.data.cancelled, true);
});

Deno.test("manage-supplier EF: invokes manage_supplier RPC", async () => {
  let capturedRpcName = "";
  const response = await handleManageSupplier(
    makeRequest({ company_id: COMPANY_ID, action: "create", name: "ACME", slug: "acme" }),
    makeDeps({
      createServiceClient: () => ({
        rpc: (rpcName: string, _args: { p: Record<string, unknown> }) => {
          capturedRpcName = rpcName;
          return Promise.resolve({
            data: { supplier_id: SUPPLIER_ID, company_id: COMPANY_ID },
            error: null,
          });
        },
      }),
    }),
  );
  const body = await response.json();
  assertEquals(response.status, 200);
  assertEquals(capturedRpcName, "manage_supplier");
  assertEquals(body.success, true);
  assertEquals(body.data.supplier_id, SUPPLIER_ID);
});

// =========================================================================
// EFResult shape tests (all 4 EFs)
// =========================================================================

Deno.test("create-purchase-order EF: EFResult shape", async () => {
  const response = await handleCreatePurchaseOrder(
    makeRequest({
      company_id: COMPANY_ID, branch_id: BRANCH_ID, supplier_id: SUPPLIER_ID,
      order_number: "PO-001",
      items: [{ variant_id: VARIANT_ID, ordered_qty: 10, unit_cost: 100 }],
    }),
    makeDeps({
      createServiceClient: () => ({
        rpc: () => Promise.resolve({
          data: { purchase_order_id: PO_ID, order_number: "PO-001", status: "draft", items_count: 1, total: 1000 },
          error: null,
        }),
      }),
    }),
  );
  const body = await response.json();
  assertEquals(body.success, true);
  assertEquals(typeof body.data.purchase_order_id, "string");
  assertEquals(typeof body.data.items_count, "number");
});

Deno.test("receive-purchase-order EF: EFResult shape", async () => {
  const response = await handleReceivePurchaseOrder(
    makeRequest({
      company_id: COMPANY_ID, branch_id: BRANCH_ID, purchase_order_id: PO_ID,
      receipt_number: "RCV-001",
      items: [{ purchase_order_item_id: PO_ITEM_ID, received_qty: 5 }],
    }),
    makeDeps({
      createServiceClient: () => ({
        rpc: () => Promise.resolve({
          data: { receipt_id: "rec-1", purchase_order_id: PO_ID, po_status: "received", lot_results: [], items_processed: 1 },
          error: null,
        }),
      }),
    }),
  );
  const body = await response.json();
  assertEquals(body.success, true);
  assertEquals(typeof body.data.receipt_id, "string");
  assertEquals(typeof body.data.items_processed, "number");
});

Deno.test("cancel-purchase-order EF: EFResult shape", async () => {
  const response = await handleCancelPurchaseOrder(
    makeRequest({ company_id: COMPANY_ID, purchase_order_id: PO_ID }),
    makeDeps({
      createServiceClient: () => ({
        rpc: () => Promise.resolve({
          data: { purchase_order_id: PO_ID, previous_status: "draft", cancelled: true },
          error: null,
        }),
      }),
    }),
  );
  const body = await response.json();
  assertEquals(body.success, true);
  assertEquals(typeof body.data.cancelled, "boolean");
});

Deno.test("manage-supplier EF: EFResult shape", async () => {
  const response = await handleManageSupplier(
    makeRequest({ company_id: COMPANY_ID, action: "create", name: "ACME", slug: "acme" }),
    makeDeps({
      createServiceClient: () => ({
        rpc: () => Promise.resolve({
          data: { supplier_id: SUPPLIER_ID, company_id: COMPANY_ID },
          error: null,
        }),
      }),
    }),
  );
  const body = await response.json();
  assertEquals(body.success, true);
  assertEquals(typeof body.data.supplier_id, "string");
});

// =========================================================================
// Company mismatch test
// =========================================================================

Deno.test("create-purchase-order EF: company mismatch -> 403", async () => {
  const response = await handleCreatePurchaseOrder(
    makeRequest({
      company_id: "00000000-0000-0000-0000-000000000099",
      branch_id: BRANCH_ID, supplier_id: SUPPLIER_ID,
      order_number: "PO-001",
      items: [{ variant_id: VARIANT_ID, ordered_qty: 10, unit_cost: 100 }],
    }),
    makeDeps(),
  );
  const body = await response.json();
  assertEquals(response.status, 403);
  assertEquals(body.success, false);
  assertEquals(body.error.code, "FORBIDDEN");
});

// =========================================================================
// RPC error propagation test
// =========================================================================

Deno.test("cancel-purchase-order EF: RPC error -> 400", async () => {
  const response = await handleCancelPurchaseOrder(
    makeRequest({ company_id: COMPANY_ID, purchase_order_id: PO_ID }),
    makeDeps({
      createServiceClient: () => ({
        rpc: () => Promise.resolve({
          data: null,
          error: { code: "RPC_ERROR", message: "cannot cancel received purchase order" },
        }),
      }),
    }),
  );
  const body = await response.json();
  assertEquals(response.status, 400);
  assertEquals(body.success, false);
  assertEquals(body.error.code, "RPC_ERROR");
});

// =========================================================================
// receive-purchase-order single RPC call (no loop) test
// =========================================================================

Deno.test("receive-purchase-order EF: single RPC call, no client-side loop", async () => {
  let rpcCallCount = 0;
  const response = await handleReceivePurchaseOrder(
    makeRequest({
      company_id: COMPANY_ID,
      branch_id: BRANCH_ID,
      purchase_order_id: PO_ID,
      receipt_number: "RCV-001",
      items: [
        { purchase_order_item_id: PO_ITEM_ID, received_qty: 5 },
        { purchase_order_item_id: "00000000-0000-0000-0000-000000000007", received_qty: 3 },
        { purchase_order_item_id: "00000000-0000-0000-0000-000000000008", received_qty: 2 },
      ],
    }),
    makeDeps({
      createServiceClient: () => ({
        rpc: (_rpcName: string, _args: { p: Record<string, unknown> }) => {
          rpcCallCount++;
          return Promise.resolve({
            data: {
              receipt_id: "rec-1", purchase_order_id: PO_ID, po_status: "received",
              lot_results: [{ lot_id: "l1", lot_code: "LC", movement_id: "m1", qty: 5 }],
              items_processed: 3,
            },
            error: null,
          });
        },
      }),
    }),
  );
  const body = await response.json();
  assertEquals(response.status, 200);
  assertEquals(rpcCallCount, 1);
  assertEquals(body.data.items_processed, 3);
});
