// Shared Zod input-validation schemas for return-sale-item Edge Function.
// Client-supplied company_id/actor_user_id are intentionally omitted here;
// the Edge Function derives both from authenticated server context.
// (source: RR6, D6, D7 — matches credit_payment_schemas pattern)

import { z } from "https://esm.sh/zod@3";

const uuidSchema = z.string().uuid("Must be a valid UUID");
const optionalText = z.string().trim().min(1).optional();

const returnItemBatchSchema = z.object({
  original_batch_id: uuidSchema,
  qty: z.number().positive("batch qty must be greater than zero"),
});

const returnItemSchema = z.object({
  sale_item_id: uuidSchema,
  variant_id: uuidSchema,
  qty: z.number().positive("item qty must be greater than zero"),
  destination: z.enum(["inventario", "merma", "garantia", "desecho"]),
  unit_price: z.number().nonnegative("unit_price must be zero or positive"),
  batches: z.array(returnItemBatchSchema).min(1, "At least one batch is required per item"),
});

export const ReturnSaleItemRequest = z.object({
  branch_id: uuidSchema,
  sale_id: uuidSchema,
  type: z.enum(["total", "partial"]),
  reason: optionalText,
  items: z.array(returnItemSchema).min(1, "At least one item is required"),
});

export type ReturnSaleItemRequest = z.infer<typeof ReturnSaleItemRequest>;

export type ReturnSaleItemResult = {
  return_id: string;
  status: string;
  total_amount: number;
  items_count: number;
};