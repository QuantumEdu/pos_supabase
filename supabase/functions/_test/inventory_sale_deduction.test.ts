// Deno test: inventory sale-deduction, sale-return, waste, expiration EFs
// (source: RI3, RI4, RI8, RI11 — Test specs)

import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  RecordExpirationRequest,
  RecordSaleDeductionRequest,
  RecordSaleReturnRequest,
  RecordWasteRequest,
} from "../_shared/inventory_schemas.ts";
import { handleRecordExpiration } from "../inventory/record-expiration/index.ts";
import { handleRecordSaleDeduction } from "../inventory/record-sale-deduction/index.ts";
import { handleRecordSaleReturn } from "../inventory/record-sale-return/index.ts";
import { handleRecordWaste } from "../inventory/record-waste/index.ts";
import { fail } from "../_shared/types.ts";
import type { InventoryHandlerDeps } from "../_shared/inventory_handler.ts";

const COMPANY_ID = "00000000-0000-0000-0000-000000000001";
const BRANCH_ID = "00000000-0000-0000-0000-000000000002";
const VARIANT_ID = "00000000-0000-0000-0000-000000000003";
const LOT_ID = "00000000-0000-0000-0000-000000000004";

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

Deno.test("RecordSaleDeductionRequest: valid input passes validation", () => {
  const result = RecordSaleDeductionRequest.safeParse({
    company_id: COMPANY_ID,
    branch_id: BRANCH_ID,
    variant_id: VARIANT_ID,
    qty: 3,
  });

  assertEquals(result.success, true);
});

Deno.test("RecordSaleDeductionRequest: missing qty fails validation", () => {
  const result = RecordSaleDeductionRequest.safeParse({
    company_id: COMPANY_ID,
    branch_id: BRANCH_ID,
    variant_id: VARIANT_ID,
  });

  assertEquals(result.success, false);
});

Deno.test("RecordSaleReturnRequest and RecordWasteRequest: required fields are enforced", () => {
  assertEquals(
    RecordSaleReturnRequest.safeParse({
      company_id: COMPANY_ID,
      branch_id: BRANCH_ID,
      variant_id: VARIANT_ID,
      lot_id: LOT_ID,
      qty: 1,
    }).success,
    true,
  );

  assertEquals(
    RecordWasteRequest.safeParse({
      company_id: COMPANY_ID,
      branch_id: BRANCH_ID,
      variant_id: VARIANT_ID,
      lot_id: LOT_ID,
      qty: 1,
    }).success,
    false,
  );
});

Deno.test("RecordExpirationRequest: optional lot_id is accepted", () => {
  const result = RecordExpirationRequest.safeParse({
    company_id: COMPANY_ID,
    branch_id: BRANCH_ID,
    variant_id: VARIANT_ID,
  });

  assertEquals(result.success, true);
});

Deno.test("record-sale-deduction EF: admin success returns FEFO result shape", async () => {
  const response = await handleRecordSaleDeduction(
    makeRequest("/inventory/record-sale-deduction", {
      company_id: COMPANY_ID,
      branch_id: BRANCH_ID,
      variant_id: VARIANT_ID,
      qty: 3,
    }),
    makeDeps((rpcName, args) => Promise.resolve({
      data: {
        movement_ids: ["movement-1"],
        lots_affected: [{ lot_id: LOT_ID, lot_code: "FEFO-LOT-A", deducted_qty: args.p.qty }],
        qty_deducted: args.p.qty,
      },
      error: rpcName === "record_sale_deduction" ? null : { message: "unexpected rpc" },
    })),
  );

  const body = await response.json();
  assertEquals(response.status, 200);
  assertEquals(body.success, true);
  assertEquals(body.data.lots_affected[0].lot_code, "FEFO-LOT-A");
});

Deno.test("record-sale-deduction EF: cashier request is rejected", async () => {
  const response = await handleRecordSaleDeduction(
    makeRequest("/inventory/record-sale-deduction", {
      company_id: COMPANY_ID,
      branch_id: BRANCH_ID,
      variant_id: VARIANT_ID,
      qty: 3,
    }),
    {
      validateAuth: () => Promise.reject(Response.json(fail("FORBIDDEN", "Insufficient permissions"), { status: 403 })),
    },
  );

  const body = await response.json();
  assertEquals(response.status, 403);
  assertEquals(body.error.code, "FORBIDDEN");
});

Deno.test("record-sale-return EF: admin success returns movement payload", async () => {
  const response = await handleRecordSaleReturn(
    makeRequest("/inventory/record-sale-return", {
      company_id: COMPANY_ID,
      branch_id: BRANCH_ID,
      variant_id: VARIANT_ID,
      lot_id: LOT_ID,
      qty: 2,
    }),
    makeDeps(() => Promise.resolve({
      data: { lot_id: LOT_ID, movement_id: "movement-2", qty: 2 },
      error: null,
    })),
  );

  const body = await response.json();
  assertEquals(response.status, 200);
  assertEquals(body.data.movement_id, "movement-2");
});

Deno.test("record-waste and record-expiration EFs: admin success returns EFResult shape", async () => {
  const wasteResponse = await handleRecordWaste(
    makeRequest("/inventory/record-waste", {
      company_id: COMPANY_ID,
      branch_id: BRANCH_ID,
      variant_id: VARIANT_ID,
      lot_id: LOT_ID,
      qty: 1,
      reason: "damaged",
    }),
    makeDeps(() => Promise.resolve({
      data: { lot_id: LOT_ID, movement_id: "movement-3", qty: 1 },
      error: null,
    })),
  );

  const expirationResponse = await handleRecordExpiration(
    makeRequest("/inventory/record-expiration", {
      company_id: COMPANY_ID,
      branch_id: BRANCH_ID,
      variant_id: VARIANT_ID,
      lot_id: LOT_ID,
    }),
    makeDeps(() => Promise.resolve({
      data: {
        movement_ids: ["movement-4"],
        expired_lots: [{ lot_id: LOT_ID, lot_code: "LOT-X", expired_qty: 5 }],
        expired_count: 1,
      },
      error: null,
    })),
  );

  const wasteBody = await wasteResponse.json();
  const expirationBody = await expirationResponse.json();

  assertEquals(wasteResponse.status, 200);
  assertEquals(wasteBody.success, true);
  assertEquals(expirationResponse.status, 200);
  assertEquals(expirationBody.data.expired_count, 1);
});
