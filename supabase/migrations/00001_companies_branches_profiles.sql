-- Migration: 00001_companies_branches_profiles
-- Source: constitution.md §1–12, plan_2da §14
-- Requirements: R3 (RLS-first multi-tenant), R5 (traceability + logical deletion), R6 (transactional consistency)

-- ============================================================
-- COMPANIES
-- Multi-tenant root entity. Every operational table references company_id.
-- (source: constitution.md §10, R3)
-- ============================================================
CREATE TABLE public.companies (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name        TEXT NOT NULL,
  slug        TEXT NOT NULL UNIQUE,
  tax_id      TEXT,
  address     TEXT,
  phone       TEXT,
  email       TEXT,
  logo_url    TEXT,
  is_active   BOOLEAN NOT NULL DEFAULT TRUE,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_by  UUID,
  updated_by  UUID,
  deleted_at  TIMESTAMPTZ,
  deleted_by  UUID
);

COMMENT ON TABLE public.companies IS 'Multi-tenant root entity. Every operational record belongs to exactly one company. (source: constitution.md §10)';
COMMENT ON COLUMN public.companies.is_active IS 'Logical deletion flag. Inactive companies remain auditable. (source: constitution.md §4, R5)';
COMMENT ON COLUMN public.companies.created_at IS 'Audit timestamp — who created and when. (source: constitution.md §3)';

-- ============================================================
-- BRANCHES
-- Company-owned locations. Each branch has its own inventory, cash, and sales.
-- (source: plan_2da §15, R3)
-- ============================================================
CREATE TABLE public.branches (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id  UUID NOT NULL REFERENCES public.companies(id),
  name        TEXT NOT NULL,
  slug        TEXT NOT NULL,
  address     TEXT,
  phone       TEXT,
  is_active   BOOLEAN NOT NULL DEFAULT TRUE,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_by  UUID,
  updated_by  UUID,
  deleted_at  TIMESTAMPTZ,
  deleted_by  UUID
);

COMMENT ON TABLE public.branches IS 'Company-owned locations. Branch-scoped data includes inventory, cash sessions, and sales. (source: plan_2da §15)';
COMMENT ON COLUMN public.branches.company_id IS 'Enforces multi-tenant isolation — every branch belongs to one company. (source: R3)';

CREATE UNIQUE INDEX idx_branches_company_slug ON public.branches(company_id, slug);
CREATE INDEX idx_branches_company_id ON public.branches(company_id);

-- ============================================================
-- PROFILES
-- Links Supabase Auth users to application-level identity.
-- Contains display name and defaults; role assignment lives in company_users.
-- (source: constitution.md §3, R5)
-- ============================================================
CREATE TABLE public.profiles (
  id          UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  full_name   TEXT,
  avatar_url  TEXT,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.profiles IS 'Application-level user identity. Auth is handled by Supabase Auth; profiles hold display info. (source: constitution.md §3)';

-- ============================================================
-- COMPANY_USERS
-- Company membership and role. A user can belong to multiple companies.
-- Roles: admin (full access to company data), cashier (branch-scoped access).
-- (source: constitution.md §7, plan_2da §15.3–15.4, R3)
-- ============================================================
CREATE TABLE public.company_users (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     UUID NOT NULL REFERENCES public.profiles(id),
  company_id  UUID NOT NULL REFERENCES public.companies(id),
  role        TEXT NOT NULL CHECK (role IN ('admin', 'cashier')),
  is_active   BOOLEAN NOT NULL DEFAULT TRUE,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_by  UUID,
  updated_by  UUID,
  deleted_at  TIMESTAMPTZ,
  deleted_by  UUID,

  UNIQUE(user_id, company_id)
);

CREATE INDEX idx_company_users_user_id ON public.company_users(user_id);
CREATE INDEX idx_company_users_company_id ON public.company_users(company_id);

COMMENT ON TABLE public.company_users IS 'Company membership with role assignment. Admin sees own-company data; cashier sees assigned branches only. (source: plan_2da §15.3–15.4, R3)';
COMMENT ON COLUMN public.company_users.role IS 'Role within this company: admin (full company access) or cashier (branch-scoped). (source: constitution.md §7)';

-- ============================================================
-- BRANCH_USERS
-- Branch assignment for cashier-role users.
-- A cashier must belong to at least one branch to operate.
-- (source: plan_2da §15.4, R3)
-- ============================================================
CREATE TABLE public.branch_users (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     UUID NOT NULL REFERENCES public.profiles(id),
  branch_id   UUID NOT NULL REFERENCES public.branches(id),
  company_id  UUID NOT NULL REFERENCES public.companies(id),
  is_active   BOOLEAN NOT NULL DEFAULT TRUE,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_by  UUID,
  updated_by  UUID,
  deleted_at  TIMESTAMPTZ,
  deleted_by  UUID,

  UNIQUE(user_id, branch_id)
);

CREATE INDEX idx_branch_users_user_id ON public.branch_users(user_id);
CREATE INDEX idx_branch_users_branch_id ON public.branch_users(branch_id);
CREATE INDEX idx_branch_users_company_id ON public.branch_users(company_id);

COMMENT ON TABLE public.branch_users IS 'Branch assignment for cashier-role users. A cashier sees only data from their assigned branches. (source: plan_2da §15.4)';

-- ============================================================
-- UPDATED_AT TRIGGER
-- Auto-update updated_at on row modification.
-- (source: R5, constitution.md §3)
-- ============================================================
CREATE OR REPLACE FUNCTION public.set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = clock_timestamp();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Apply updated_at triggers to all audit-eligible tables
DO $$
DECLARE
  t TEXT;
BEGIN
  FOREACH t IN ARRAY ARRAY['companies', 'branches', 'profiles', 'company_users', 'branch_users']
  LOOP
    EXECUTE format(
      'CREATE TRIGGER set_updated_at BEFORE UPDATE ON public.%I
       FOR EACH ROW EXECUTE FUNCTION public.set_updated_at()',
      t
    );
  END LOOP;
END;
$$;
