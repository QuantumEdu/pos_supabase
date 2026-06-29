import Link from "next/link";
import { AppShell } from "@/components/app-shell";
import { requireUser } from "@/lib/auth";

export default async function DashboardPage() {
  const { supabase, user, role } = await requireUser();

  const [salesToday, lowStock, branches] = await Promise.all([
    supabase.from("v_dashboard_sales_today").select("*").limit(1).maybeSingle(),
    supabase.from("v_dashboard_low_stock").select("*"),
    supabase.from("branches").select("id, name"),
  ]);

  return (
    <AppShell title="Dashboard" userEmail={user.email} userRole={role} active="dashboard">
      <div className="mb-8 grid grid-cols-1 gap-6 md:grid-cols-3">
        <MetricCard
          title="Ventas Hoy"
          value={
            salesToday.data?.total_sales
              ? `$${Number(salesToday.data.total_sales).toLocaleString("es-MX", { minimumFractionDigits: 2 })}`
              : "$0.00"
          }
          subtitle={
            salesToday.data?.sales_count
              ? `${salesToday.data.sales_count} ventas`
              : "Sin ventas hoy"
          }
        />
        <MetricCard
          title="Productos con Stock Bajo"
          value={String(lowStock.data?.length ?? 0)}
          subtitle="Requieren reabastecimiento"
          alert={(lowStock.data?.length ?? 0) > 0}
        />
        <MetricCard
          title="Sucursales"
          value={String(branches.data?.length ?? 0)}
          subtitle="Sucursales activas"
        />
      </div>

      <h2 className="mb-4 text-lg font-semibold">Acciones rápidas</h2>
      <div className="grid grid-cols-1 gap-4 md:grid-cols-3">
        <Link
          href="/pos"
          className="rounded-xl border bg-white p-6 transition hover:shadow-md"
        >
          <h3 className="mb-2 text-lg font-semibold">Nueva Venta</h3>
          <p className="text-sm text-zinc-500">
            Elegí una sucursal y prepará una venta
          </p>
        </Link>
        <Link
          href="/products"
          className="rounded-xl border bg-white p-6 transition hover:shadow-md"
        >
          <h3 className="mb-2 text-lg font-semibold">Productos</h3>
          <p className="text-sm text-zinc-500">
            Revisá catálogo, variantes y precios activos
          </p>
        </Link>
        <Link
          href="/pos"
          className="rounded-xl border bg-white p-6 transition hover:shadow-md"
        >
          <h3 className="mb-2 text-lg font-semibold">Caja y sucursales</h3>
          <p className="text-sm text-zinc-500">
            Consultá el estado operativo por sucursal
          </p>
        </Link>
      </div>
    </AppShell>
  );
}

function MetricCard({
  title,
  value,
  subtitle,
  alert,
}: {
  title: string;
  value: string;
  subtitle: string;
  alert?: boolean;
}) {
  return (
    <div
      className={`rounded-xl border bg-white p-6 ${
        alert ? "border-red-200" : ""
      }`}
    >
      <h3 className="mb-1 text-sm font-medium text-zinc-500">{title}</h3>
      <p className={`text-3xl font-bold ${alert ? "text-red-600" : ""}`}>
        {value}
      </p>
      <p className="mt-1 text-xs text-zinc-400">{subtitle}</p>
    </div>
  );
}
