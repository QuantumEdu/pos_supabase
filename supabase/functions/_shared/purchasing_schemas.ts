// Shared Zod input-validation schemas for purchasing Edge Functions
// (source: RP1-RP10, DP1-DP3 — purchasing domain EF contracts)

import { z } from "https://esm.sh/zod@3";

const uuidSchema = z.string().uuid("Must be a valid UUID");
const company_id = uuidSchema.describe("Company UUID — must match auth user's company");

// --- Purchase Order ---

const orderItemSchema = z.object({
  variant_id: uuidSchema,
  ordered_qty: z.number().positive("Ordered quantity must be positive"),
  unit_cost: z.number().min(0, "Unit cost must be non-negative"),
  tax_rate: z.number().min(0).max(1).default(0),
  tax_amount: z.number().min(0).default(0),
  subtotal: z.number().min(0).default(0),
});

export const CreatePurchaseOrderRequest = z.object({
  company_id,
  branch_id: uuidSchema,
  supplier_id: uuidSchema,
  order_number: z.string().min(1, "Order number is required"),
  order_date: z.string().optional(),
  expected_date: z.string().optional(),
  payment_method: z.string().optional(),
  notes: z.string().optional(),
  items: z.array(orderItemSchema).min(1, "At least one order item is required"),
});
export type CreatePurchaseOrderRequest = z.infer<typeof CreatePurchaseOrderRequest>;

// --- Receive Purchase ---

const receiptItemSchema = z.object({
  purchase_order_item_id: uuidSchema,
  received_qty: z.number().positive("Received quantity must be positive"),
  lot_code: z.string().optional(),
  expiration_date: z.string().optional(),
  unit_cost: z.number().min(0).optional(),
  tax_rate: z.number().min(0).max(1).optional(),
});

export const ReceivePurchaseOrderRequest = z.object({
  company_id,
  branch_id: uuidSchema,
  purchase_order_id: uuidSchema,
  receipt_number: z.string().min(1, "Receipt number is required"),
  receipt_date: z.string().optional(),
  notes: z.string().optional(),
  items: z.array(receiptItemSchema).min(1, "At least one receipt item is required"),
});
export type ReceivePurchaseOrderRequest = z.infer<typeof ReceivePurchaseOrderRequest>;

// --- Cancel Purchase Order ---

export const CancelPurchaseOrderRequest = z.object({
  company_id,
  purchase_order_id: uuidSchema,
  reason: z.string().optional(),
});
export type CancelPurchaseOrderRequest = z.infer<typeof CancelPurchaseOrderRequest>;

// --- Supplier Management ---

export const ManageSupplierRequest = z.object({
  company_id,
  action: z.enum(["create", "update", "deactivate"]),
  supplier_id: uuidSchema.optional(),
  name: z.string().min(1).optional(),
  slug: z.string().min(1).optional(),
  tax_id: z.string().optional(),
  contact_name: z.string().optional(),
  phone: z.string().optional(),
  email: z.string().email().optional().or(z.literal("")),
  address: z.string().optional(),
  notes: z.string().optional(),
});
export type ManageSupplierRequest = z.infer<typeof ManageSupplierRequest>;

// --- Result types ---

export type PurchaseOrderResult = {
  purchase_order_id: string;
  order_number: string;
  status: string;
  items_count: number;
  total: number;
};

export type ReceivePurchaseResult = {
  receipt_id: string;
  purchase_order_id: string;
  po_status: string;
  lot_results: Array<{
    lot_id: string;
    lot_code: string;
    movement_id: string;
    qty: number;
  }>;
  items_processed: number;
};

export type CancelPurchaseOrderResult = {
  purchase_order_id: string;
  previous_status: string;
  cancelled: boolean;
};

export type SupplierResult = {
  supplier_id: string;
  company_id: string;
  deactivated?: boolean;
};
