-- Migration: 00002_rls_helpers
-- Source: plan_2da §15, D5
-- Requirements: R3 (RLS-first multi-tenant), R5 (traceability)
-- Purpose: SQL helper functions that extract company_id, user role, and branch_id
--          from JWT claims for use in RLS policies.

-- ============================================================
-- HELPER: get_company_id()
-- Returns the company_id from the authenticated user's JWT claims.
-- Used by RLS policies to enforce tenant isolation.
-- (source: plan_2da §15.1, D5, R3)
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_company_id()
RETURNS UUID
LANGUAGE sql
STABLE
SECURITY DEFINER
AS $$
  SELECT (auth.jwt() -> 'app_metadata' ->> 'company_id')::uuid;
$$;

COMMENT ON FUNCTION public.get_company_id() IS 'Extracts company_id from JWT claims for RLS tenant isolation. (source: plan_2da §15.1, D5)';

-- ============================================================
-- HELPER: get_user_role()
-- Returns the role for the current user within the current company context.
-- Falls back to checking company_users if JWT claim is not set.
-- Possible returns: 'admin', 'cashier', or NULL (no membership).
-- (source: plan_2da §15.3–15.4, D5, R3)
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_user_role()
RETURNS TEXT
LANGUAGE sql
STABLE
SECURITY DEFINER
AS $$
  SELECT COALESCE(
    (auth.jwt() -> 'app_metadata' ->> 'role')::text,
    (
      SELECT cu.role
      FROM public.company_users cu
      WHERE cu.user_id = auth.uid()
        AND cu.company_id = public.get_company_id()
        AND cu.is_active = TRUE
      LIMIT 1
    )
  );
$$;

COMMENT ON FUNCTION public.get_user_role() IS 'Returns the current user role within the active company. Admin sees company-wide data; cashier sees branch-scoped data. (source: plan_2da §15.3–15.4)';

-- ============================================================
-- HELPER: get_user_branch_id()
-- Returns the branch_id from JWT claims for cashier-scoped queries.
-- Falls back to the first active branch assignment if claim is not set.
-- Returns NULL for admin-role users (no branch restriction).
-- (source: plan_2da §15.2, D5, R3)
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_user_branch_id()
RETURNS UUID
LANGUAGE sql
STABLE
SECURITY DEFINER
AS $$
  SELECT COALESCE(
    (auth.jwt() -> 'app_metadata' ->> 'branch_id')::uuid,
    (
      SELECT bu.branch_id
      FROM public.branch_users bu
      WHERE bu.user_id = auth.uid()
        AND bu.company_id = public.get_company_id()
        AND bu.is_active = TRUE
      LIMIT 1
    )
  );
$$;

COMMENT ON FUNCTION public.get_user_branch_id() IS 'Returns the branch_id for the current cashier user. Admin returns NULL (no branch restriction). (source: plan_2da §15.2)';

-- ============================================================
-- HELPER: is_admin()
-- Convenience function: returns TRUE if current user has admin role
-- in the current company context.
-- ============================================================
CREATE OR REPLACE FUNCTION public.is_admin()
RETURNS BOOLEAN
LANGUAGE sql
STABLE
AS $$
  SELECT public.get_user_role() = 'admin';
$$;

COMMENT ON FUNCTION public.is_admin() IS 'Convenience: TRUE if the current user is an admin in the active company.';

-- ============================================================
-- HELPER: is_cashier()
-- Convenience function: returns TRUE if current user has cashier role
-- in the current company context.
-- ============================================================
CREATE OR REPLACE FUNCTION public.is_cashier()
RETURNS BOOLEAN
LANGUAGE sql
STABLE
AS $$
  SELECT public.get_user_role() = 'cashier';
$$;

COMMENT ON FUNCTION public.is_cashier() IS 'Convenience: TRUE if the current user is a cashier in the active company.';

-- ============================================================
-- HELPER: is_active_company_user()
-- Returns TRUE if the given user has an active membership
-- in the given company. Used by POS sales RPCs.
-- ============================================================
CREATE OR REPLACE FUNCTION public.is_active_company_user(p_company_id UUID, p_user_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.company_users
    WHERE company_id = p_company_id
      AND user_id = p_user_id
      AND is_active = TRUE
  );
$$;

COMMENT ON FUNCTION public.is_active_company_user(UUID, UUID) IS 'Returns TRUE if the user has an active company_users membership. Used by POS sales RPCs for caller validation.';

-- ============================================================
-- HELPER: has_role()
-- Returns TRUE if the given user has a specific role in the
-- given company and their membership is active.
-- ============================================================
CREATE OR REPLACE FUNCTION public.has_role(p_company_id UUID, p_user_id UUID, p_role TEXT)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.company_users
    WHERE company_id = p_company_id
      AND user_id = p_user_id
      AND role = p_role
      AND is_active = TRUE
  );
$$;

COMMENT ON FUNCTION public.has_role(UUID, UUID, TEXT) IS 'Returns TRUE if the user has the specified role in the company and their membership is active.';