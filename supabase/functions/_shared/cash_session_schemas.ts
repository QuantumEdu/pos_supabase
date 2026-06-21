// Shared Zod input-validation schemas for cash session Edge Functions.
// Client-supplied company_id/actor_user_id are intentionally omitted here;
// the Edge Function derives both from authenticated server context.

import { z } from "https://esm.sh/zod@3";

const uuidSchema = z.string().uuid("Must be a valid UUID");
const optionalText = z.string().trim().min(1).optional();
const nonNegativeAmount = z.number().nonnegative("amount must be zero or greater");
const positiveAmount = z.number().positive("amount must be greater than zero");

export const OpenCashSessionRequest = z.object({
  branch_id: uuidSchema,
  cashier_user_id: uuidSchema.optional(),
  opening_amount: nonNegativeAmount,
  notes: optionalText,
});

export type OpenCashSessionRequest = z.infer<typeof OpenCashSessionRequest>;

export const CloseCashSessionRequest = z.object({
  cash_session_id: uuidSchema,
  counted_cash_amount: nonNegativeAmount,
  notes: optionalText,
});

export type CloseCashSessionRequest = z.infer<typeof CloseCashSessionRequest>;

export const RecordManualMovementRequest = z.object({
  cash_session_id: uuidSchema,
  movement_type: z.enum(["manual_cash_in", "manual_cash_out"]),
  amount: positiveAmount,
  reference_type: optionalText,
  reference_id: uuidSchema.optional(),
  reason: optionalText,
  notes: optionalText,
});

export type RecordManualMovementRequest = z.infer<typeof RecordManualMovementRequest>;

export const ForceCloseCashSessionRequest = z.object({
  cash_session_id: uuidSchema,
  counted_cash_amount: nonNegativeAmount,
  reason: optionalText,
  notes: optionalText,
});

export type ForceCloseCashSessionRequest = z.infer<typeof ForceCloseCashSessionRequest>;

export type OpenCashSessionResult = {
  cash_session_id: string;
  movement_id: string;
  status: "open";
  expected_cash_amount: number;
};

export type CloseCashSessionResult = {
  cash_session_id: string;
  status: "closed";
  expected_cash_amount: number;
  counted_cash_amount: number;
  difference_amount: number;
};

export type ManualCashMovementResult = {
  cash_session_id: string;
  movement_id: string;
  movement_type: "manual_cash_in" | "manual_cash_out";
  expected_cash_amount: number;
};

export type ForceCloseCashSessionResult = CloseCashSessionResult & {
  forced: true;
};
