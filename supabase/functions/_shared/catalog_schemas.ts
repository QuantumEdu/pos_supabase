// Shared Zod input-validation schemas for catalog Edge Functions
// (source: RC1–RC7, D12 — EF contracts)
//
// Each EF validates its request body with the appropriate schema
// before invoking the corresponding SECURITY DEFINER RPC.
// These schemas enforce the same constraints as the SQL layer
// (company_id, required fields, valid UUIDs) as a first gate.

import { z } from "https://esm.sh/zod@3";

// ---------------------------------------------------------------------------
// Re-usable sub-schemas
// ---------------------------------------------------------------------------

const uuidSchema = z.string().uuid("Must be a valid UUID");

/** company_id is required on every mutation — the RPC verifies ownership */
const company_id = uuidSchema.describe("Company UUID — must match auth user's company");

// ---------------------------------------------------------------------------
// Product schemas (RC4, RC5)
// ---------------------------------------------------------------------------

export const CreateProductRequest = z.object({
  company_id,
  name: z.string().min(1, "Product name is required"),
  slug: z.string().min(1, "Product slug is required"),
  brand_id: uuidSchema.optional(),
  category_id: uuidSchema.optional(),
  description: z.string().optional(),
  variant_name: z.string().min(1, "Variant name is required"),
  sku: z.string().optional(),
  barcode: z.string().optional(),
  unit_id: uuidSchema.optional(),
  price: z.number().positive("Price must be positive"),
  currency: z.string().default("MXN"),
  effective_from: z.string().optional(), // ISO datetime, defaults to now() in RPC
});

export type CreateProductRequest = z.infer<typeof CreateProductRequest>;

export const DeactivateProductRequest = z.object({
  company_id,
  product_id: uuidSchema,
});

export type DeactivateProductRequest = z.infer<typeof DeactivateProductRequest>;

export const UpdateProductRequest = z.object({
  company_id,
  product_id: uuidSchema,
  name: z.string().min(1).optional(),
  slug: z.string().min(1).optional(),
  brand_id: uuidSchema.nullable().optional(), // null to clear, undefined to keep
  category_id: uuidSchema.nullable().optional(), // null to clear, undefined to keep
  description: z.string().optional(),
});

export type UpdateProductRequest = z.infer<typeof UpdateProductRequest>;

export const SetVariantPriceRequest = z.object({
  company_id,
  variant_id: uuidSchema,
  price: z.number().positive("Price must be positive"),
  currency: z.string().default("MXN"),
  effective_from: z.string().optional(), // ISO datetime, defaults to now() in RPC
});

export type SetVariantPriceRequest = z.infer<typeof SetVariantPriceRequest>;

// ---------------------------------------------------------------------------
// Brand schemas (RC1)
// ---------------------------------------------------------------------------

export const CreateBrandRequest = z.object({
  company_id,
  name: z.string().min(1, "Brand name is required"),
  slug: z.string().min(1, "Brand slug is required"),
});

export type CreateBrandRequest = z.infer<typeof CreateBrandRequest>;

export const UpdateBrandRequest = z.object({
  company_id,
  id: uuidSchema,
  name: z.string().min(1).optional(),
  slug: z.string().min(1).optional(),
});

export type UpdateBrandRequest = z.infer<typeof UpdateBrandRequest>;

export const DeactivateBrandRequest = z.object({
  company_id,
  id: uuidSchema,
});

export type DeactivateBrandRequest = z.infer<typeof DeactivateBrandRequest>;

// ---------------------------------------------------------------------------
// Category schemas (RC2)
// ---------------------------------------------------------------------------

export const CreateCategoryRequest = z.object({
  company_id,
  name: z.string().min(1, "Category name is required"),
  slug: z.string().min(1, "Category slug is required"),
  parent_id: uuidSchema.optional(),
});

export type CreateCategoryRequest = z.infer<typeof CreateCategoryRequest>;

export const UpdateCategoryRequest = z.object({
  company_id,
  id: uuidSchema,
  name: z.string().min(1).optional(),
  slug: z.string().min(1).optional(),
  parent_id: uuidSchema.nullable().optional(), // null to clear, undefined to keep
});

export type UpdateCategoryRequest = z.infer<typeof UpdateCategoryRequest>;

export const DeactivateCategoryRequest = z.object({
  company_id,
  id: uuidSchema,
});

export type DeactivateCategoryRequest = z.infer<typeof DeactivateCategoryRequest>;

// ---------------------------------------------------------------------------
// Unit schemas (RC3)
// ---------------------------------------------------------------------------

export const CreateUnitRequest = z.object({
  company_id,
  name: z.string().min(1, "Unit name is required"),
  abbreviation: z.string().optional(),
});

export type CreateUnitRequest = z.infer<typeof CreateUnitRequest>;

export const UpdateUnitRequest = z.object({
  company_id,
  id: uuidSchema,
  name: z.string().min(1).optional(),
  abbreviation: z.string().optional(),
});

export type UpdateUnitRequest = z.infer<typeof UpdateUnitRequest>;

export const DeactivateUnitRequest = z.object({
  company_id,
  id: uuidSchema,
});

export type DeactivateUnitRequest = z.infer<typeof DeactivateUnitRequest>;

// ---------------------------------------------------------------------------
// Result types for EF responses
// ---------------------------------------------------------------------------

export type ProductResult = {
  product_id: string;
  variant_id: string;
  price_id: string;
  sku: string;
};

export type UpdateProductResult = {
  product_id: string;
  updated: boolean;
};

export type BrandResult = {
  id: string;
  company_id: string;
};

export type CategoryResult = {
  id: string;
  company_id: string;
};

export type UnitResult = {
  id: string;
  company_id: string;
};

export type DeactivateResult = {
  id: string;
  deactivated: boolean;
};

export type UpdateResult = {
  id: string;
  updated: boolean;
};

export type SetPriceResult = {
  price_id: string;
  variant_id: string;
  price: number;
  currency: string;
  effective_from: string;
  previous_price_closed: boolean;
};