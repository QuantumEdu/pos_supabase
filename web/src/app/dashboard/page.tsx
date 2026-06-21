import { createClient } from "@/lib/supabase";
import { redirect } from "next/navigation";
import { LogoutButton } from "./logout-button";

export default async function DashboardPage() {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) redirect("/login");

  // Fetch dashboard metrics from the reporting views
  const [salesToday, lowStock, branches] = await Promise.all([
    supabase.from("v_dashboard_sales_today").select("*").limit(1).maybeSingle(),
    supabase.from("v_dashboard_low_stock").select("*"),
    supabase.from("branches").select("id, name"),
  ]);

  return (
    <div className="flex min-h-screen bg-zinc-50">
      {/* Sidebar */}
      <aside className="flex w-64 flex-col border-r bg-white">
        <div className="border-b px-6 py-4">
          <h2 className="text-lg font-bold">Farmacia Salud</h2>
          <p className="text-xs text-zinc-500">{user.email}</p>
        </div>
        <nav className="flex-1 space-y-1 px-3 py-4">
          <SidebarLink href="/dashboard" active>Dashboard</SidebarLink>
          <SidebarLink href="/products">Productos</SidebarLink>
          <SidebarLink href="/pos">Punto de Venta</SidebarLink>
        </nav>
        <div className="border-t px-3 py-3">
          <LogoutButton />
        </div>
      </aside>

      {/* Content */}
      <main className="flex-1 overflow-auto">
        <header className="border-b bg-white px-8 py-4">
          <h1 className="text-xl font-semibold">Dashboard</h1>
        </header>

        <div className="p-8">
          {/* Metrics Cards */}
          <div className="mb-8 grid grid-cols-1 gap-6 md:grid-cols-3">
            <MetricCard
              title="Ventas Hoy"
              value={
                salesToday.data?.total_sales
                  ? `$${Number(salesToday.data.total_sales).toLocaleString("es-MX", { minimumFractionDigits: 2 })}`
                  : "$0.00"
              }
              subtitle={
                salesToday.data?.sale_count
                  ? `${salesToday.data.sale_count} ventas`
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

          {/* Quick Actions */}
          <h2 className="mb-4 text-lg font-semibold">Acciones rápidas</h2>
          <div className="grid grid-cols-1 gap-4 md:grid-cols-3">
            <a
              href="/pos"
              className="rounded-xl border bg-white p-6 transition hover:shadow-md"
            >
              <h3 className="mb-2 text-lg font-semibold">Nueva Venta</h3>
              <p className="text-sm text-zinc-500">
                Registrar una venta en el punto de venta
              </p>
            </a>
            <a
              href="/products"
              className="rounded-xl border bg-white p-6 transition hover:shadow-md"
            >
              <h3 className="mb-2 text-lg font-semibold">Productos</h3>
              <p className="text-sm text-zinc-500">
                Ver y gestionar el catálogo de productos
              </p>
            </a>
            <a
              href="/dashboard"
              className="rounded-xl border bg-white p-6 transition hover:shadow-md"
            >
              <h3 className="mb-2 text-lg font-semibold">Reportes</h3>
              <p className="text-sm text-zinc-500">
                Ver reportes de ventas y rendimiento
              </p>
            </a>
          </div>
        </div>
      </main>
    </div>
  );
}

function SidebarLink({
  href,
  active,
  children,
}: {
  href: string;
  active?: boolean;
  children: React.ReactNode;
}) {
  return (
    <a
      href={href}
      className={`block rounded-lg px-4 py-2 text-sm font-medium transition ${
        active
          ? "bg-blue-50 text-blue-700"
          : "text-zinc-600 hover:bg-zinc-100"
      }`}
    >
      {children}
    </a>
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
