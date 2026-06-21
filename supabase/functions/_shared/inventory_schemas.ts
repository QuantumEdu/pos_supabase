// Shared Zod input-validation schemas for inventory Edge Functions
// (source: RI2-RI11, inventory domain design)

import { z } from "https://esm.sh/zod@3";

const uuidSchema = z.string().uuid("Must be a valid UUID");
const company_id = uuidSchema.describe("Company UUID — must match auth user's company");
const branch_id = uuidSchema;
const variant_id = uuidSchema;
const lot_id = uuidSchema;
const positiveQty = z.number().positive("qty must be greater than zero");
const optionalText = z.string().min(1).optional();

export const ReceivePurchaseRequest = z.object({
  company_id,
  branch_id,
  variant_id,
  qty: positiveQty,
  lot_code: optionalText,
  expiration_date: z.string().optional(),
  cost_per_unit: z.number().nonnegative("cost_per_unit must be zero or greater").optional(),
  reference_type: optionalText,
  reference_id: uuidSchema.optional(),
  notes: optionalText,
});

export type ReceivePurchaseRequest = z.infer<typeof ReceivePurchaseRequest>;

export const RecordSaleDeductionRequest = z.object({
  company_id,
  branch_id,
  variant_id,
  qty: positiveQty,
  reference_type: optionalText,
  reference_id: uuidSchema.optional(),
  notes: optionalText,
});

export type RecordSaleDeductionRequest = z.infer<typeof RecordSaleDeductionRequest>;

export const RecordSaleReturnRequest = z.object({
  company_id,
  branch_id,
  variant_id,
  lot_id,
  qty: positiveQty,
  reference_type: optionalText,
  reference_id: uuidSchema.optional(),
  notes: optionalText,
});

export type RecordSaleReturnRequest = z.infer<typeof RecordSaleReturnRequest>;

export const AdjustInventoryRequest = z.object({
  company_id,
  branch_id,
  variant_id,
  qty: z.number().refine((value) => value !== 0, "qty must not be zero"),
  reason: z.string().min(1, "reason is required"),
  lot_id: lot_id.optional(),
  lot_code: optionalText,
  notes: optionalText,
});

export type AdjustInventoryRequest = z.infer<typeof AdjustInventoryRequest>;

export const RecordWasteRequest = z.object({
  company_id,
  branch_id,
  variant_id,
  lot_id,
  qty: positiveQty,
  reason: z.string().min(1, "reason is required"),
  notes: optionalText,
});

export type RecordWasteRequest = z.infer<typeof RecordWasteRequest>;

export const RecordExpirationRequest = z.object({
  company_id,
  branch_id,
  variant_id,
  lot_id: lot_id.optional(),
  notes: optionalText,
});

export type RecordExpirationRequest = z.infer<typeof RecordExpirationRequest>;

export const ReserveStockRequest = z.object({
  company_id,
});

export type ReserveStockRequest = z.infer<typeof ReserveStockRequest>;

export const ReleaseReservationRequest = z.object({
  company_id,
});

export type ReleaseReservationRequest = z.infer<typeof ReleaseReservationRequest>;

export type ReceivePurchaseResult = {
  lot_id: string;
  lot_code: string;
  movement_id: string;
  qty: number;
};

export type InventoryMovementResult = {
  lot_id: string;
  movement_id: string;
  qty: number;
};

export type InventoryBatchMovementResult = {
  movement_ids: string[];
  lots_affected: Array<{
    lot_id: string;
    lot_code: string;
    deducted_qty: number;
  }>;
  qty_deducted?: number;
  qty?: number;
};

export type InventoryExpirationResult = {
  movement_ids: string[];
  expired_lots: Array<{
    lot_id: string;
    lot_code: string;
    expired_qty: number;
  }>;
  expired_count: number;
};
