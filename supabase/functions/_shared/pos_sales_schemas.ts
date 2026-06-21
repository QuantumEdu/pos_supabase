// Shared Zod input-validation schemas for POS sales Edge Functions.
// Client-supplied company_id/actor_user_id are intentionally omitted here;
// the Edge Function derives both from authenticated server context.

import { z } from "https://esm.sh/zod@3";

const uuidSchema = z.string().uuid("Must be a valid UUID");
const optionalText = z.string().trim().min(1).optional();
const nonNegativeAmount = z.number().nonnegative("amount must be zero or greater");
const positiveAmount = z.number().positive("amount must be greater than zero");

// ---------------------------------------------------------------------------
// CreateSale
// ---------------------------------------------------------------------------

export const CreateSaleRequest = z.object({
  branch_id: uuidSchema,
  cashier_user_id: uuidSchema.optional(),
  customer_id: uuidSchema.optional(),
  items: z.array(
    z.object({
      variant_id: uuidSchema,
      quantity: z.number().positive("quantity must be greater than zero"),
      unit_price: nonNegativeAmount,
      discount_percent: z.number().default(0),
      discount_amount: z.number().default(0),
      tax_percent: z.number().default(0),
      tax_amount: z.number().default(0),
      is_manual_price: z.boolean().default(false),
    }),
  ).min(1, "items must contain at least one line"),
  payments: z.array(
    z.object({
      payment_method: z.enum(["cash", "card", "transfer", "credit"]),
      amount: positiveAmount,
      reference: optionalText,
    }),
  ).min(1, "payments must contain at least one entry"),
});

export type CreateSaleRequest = z.infer<typeof CreateSaleRequest>;

// ---------------------------------------------------------------------------
// CancelSale
// ---------------------------------------------------------------------------

export const CancelSaleRequest = z.object({
  sale_id: uuidSchema,
  reason: optionalText,
});

export type CancelSaleRequest = z.infer<typeof CancelSaleRequest>;

// ---------------------------------------------------------------------------
// AuthorizeDiscount
// ---------------------------------------------------------------------------

export const AuthorizeDiscountRequest = z.object({
  sale_id: uuidSchema,
  discount_percent: z.number().min(0, "discount_percent must be >= 0").max(100, "discount_percent must be <= 100"),
  discount_amount: nonNegativeAmount,
  reason: z.string().trim().min(1, "reason is required"),
});

export type AuthorizeDiscountRequest = z.infer<typeof AuthorizeDiscountRequest>;

// ---------------------------------------------------------------------------
// Result types
// ---------------------------------------------------------------------------

export type CreateSaleResult = {
  sale_id: string;
  sale_number: number;
  status: string;
  subtotal: number;
  discount_amount: number;
  tax_amount: number;
  total: number;
  cash_session_id: string;
};

export type CancelSaleResult = {
  sale_id: string;
  status: "cancelled";
  reversed_items: number;
};

export type AuthorizeDiscountResult = {
  authorization_id: string;
  sale_id: string;
  authorized_at: string;
};