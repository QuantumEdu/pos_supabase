-- Migration: 00003_rls_policies
-- Source: plan_2da §15, D5, R3
-- Requirements: R3 (RLS-first multi-tenant — zero cross-tenant leakage)
-- Purpose: Enable RLS and define policies on all operational tables.
--          Admin sees own-company data; cashier sees assigned-branch data.

-- ============================================================
-- ENABLE RLS ON ALL OPERATIONAL TABLES
-- (source: R3, D5)
-- ============================================================
ALTER TABLE public.companies ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.branches ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.company_users ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.branch_users ENABLE ROW LEVEL SECURITY;

-- ============================================================
-- COMPANIES RLS POLICIES
-- Admin can see their own company. Cashier can see their own company.
-- No cross-tenant access. (source: plan_2da §15.3, R3)
-- ============================================================
CREATE POLICY "companies_select_own"
  ON public.companies FOR SELECT
  TO authenticated
  USING (id = public.get_company_id());

CREATE POLICY "companies_update_own"
  ON public.companies FOR UPDATE
  TO authenticated
  USING (id = public.get_company_id() AND public.is_admin());

-- ============================================================
-- BRANCHES RLS POLICIES
-- Admin sees all branches of their company.
-- Cashier sees only their assigned branches. (source: plan_2da §15.2–15.4)
-- ============================================================
CREATE POLICY "branches_select_own_company"
  ON public.branches FOR SELECT
  TO authenticated
  USING (
    company_id = public.get_company_id()
    AND (
      public.is_admin()
      OR id = public.get_user_branch_id()
      OR EXISTS (
        SELECT 1 FROM public.branch_users bu
        WHERE bu.user_id = auth.uid()
          AND bu.branch_id = branches.id
          AND bu.company_id = public.get_company_id()
          AND bu.is_active = TRUE
      )
    )
  );

CREATE POLICY "branches_insert_admin"
  ON public.branches FOR INSERT
  TO authenticated
  WITH CHECK (
    company_id = public.get_company_id()
    AND public.is_admin()
  );

CREATE POLICY "branches_update_admin"
  ON public.branches FOR UPDATE
  TO authenticated
  USING (
    company_id = public.get_company_id()
    AND public.is_admin()
  );

-- ============================================================
-- PROFILES RLS POLICIES
-- Users can read their own profile. Admin can read profiles
-- of users in their company. (source: constitution.md §3, R3)
-- ============================================================
CREATE POLICY "profiles_read_own"
  ON public.profiles FOR SELECT
  TO authenticated
  USING (id = auth.uid());

CREATE POLICY "profiles_update_own"
  ON public.profiles FOR UPDATE
  TO authenticated
  USING (id = auth.uid());

-- ============================================================
-- COMPANY_USERS RLS POLICIES
-- Admin sees all users in their company. Cashier sees their own membership.
-- (source: plan_2da §15.3, R3)
-- ============================================================
CREATE POLICY "company_users_select_admin_or_self"
  ON public.company_users FOR SELECT
  TO authenticated
  USING (
    company_id = public.get_company_id()
    AND (
      public.is_admin()
      OR user_id = auth.uid()
    )
  );

CREATE POLICY "company_users_insert_admin"
  ON public.company_users FOR INSERT
  TO authenticated
  WITH CHECK (
    company_id = public.get_company_id()
    AND public.is_admin()
  );

CREATE POLICY "company_users_update_admin"
  ON public.company_users FOR UPDATE
  TO authenticated
  USING (
    company_id = public.get_company_id()
    AND public.is_admin()
  );

-- ============================================================
-- BRANCH_USERS RLS POLICIES
-- Admin sees all branch assignments in their company.
-- Cashier sees only their own branch assignments.
-- (source: plan_2da §15.4, R3)
-- ============================================================
CREATE POLICY "branch_users_select_admin_or_self"
  ON public.branch_users FOR SELECT
  TO authenticated
  USING (
    company_id = public.get_company_id()
    AND (
      public.is_admin()
      OR user_id = auth.uid()
    )
  );

CREATE POLICY "branch_users_insert_admin"
  ON public.branch_users FOR INSERT
  TO authenticated
  WITH CHECK (
    company_id = public.get_company_id()
    AND public.is_admin()
  );

CREATE POLICY "branch_users_update_admin"
  ON public.branch_users FOR UPDATE
  TO authenticated
  USING (
    company_id = public.get_company_id()
    AND public.is_admin()
  );

-- ============================================================
-- SERVICE ROLE POLICIES
-- Allow service_role (used by Edge Functions for RPC calls)
-- full access for transactional operations. RLS policies above
-- guard direct client access. (source: D4, R6)
-- ============================================================
CREATE POLICY "companies_service_all"
  ON public.companies FOR ALL
  TO service_role
  USING (TRUE)
  WITH CHECK (TRUE);

CREATE POLICY "branches_service_all"
  ON public.branches FOR ALL
  TO service_role
  USING (TRUE)
  WITH CHECK (TRUE);

CREATE POLICY "profiles_service_all"
  ON public.profiles FOR ALL
  TO service_role
  USING (TRUE)
  WITH CHECK (TRUE);

CREATE POLICY "company_users_service_all"
  ON public.company_users FOR ALL
  TO service_role
  USING (TRUE)
  WITH CHECK (TRUE);

CREATE POLICY "branch_users_service_all"
  ON public.branch_users FOR ALL
  TO service_role
  USING (TRUE)
  WITH CHECK (TRUE);