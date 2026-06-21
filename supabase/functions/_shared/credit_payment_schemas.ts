// Shared Zod input-validation schemas for credit payment Edge Functions.
// Client-supplied company_id/actor_user_id are intentionally omitted here;
// the Edge Function derives both from authenticated server context.
// (source: RCP7, D5, D12)

import { z } from "https://esm.sh/zod@3";

const uuidSchema = z.string().uuid("Must be a valid UUID");
const positiveAmount = z.number().positive("amount must be greater than zero");
const optionalText = z.string().trim().min(1).optional();

export const RegisterCustomerPaymentRequest = z.object({
  balance_id: uuidSchema,
  amount: positiveAmount,
  payment_method: z.enum(["cash", "card", "transfer"]),
  reference: optionalText,
});

export type RegisterCustomerPaymentRequest = z.infer<typeof RegisterCustomerPaymentRequest>;

export type RegisterCustomerPaymentResult = {
  payment_id: string;
  balance_id: string;
  amount_paid: number;
  new_paid_amount: number;
  new_remaining_amount: number;
  new_status: "pending" | "partial" | "paid";
};