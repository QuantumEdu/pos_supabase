import Link from "next/link";
import { AppShell } from "@/components/app-shell";
import { requireUser } from "@/lib/auth";

export default async function PosPage() {
  const { supabase, user, role } = await requireUser();

  const [{ data: branches }, { data: branchSales }, { data: openSessions }] =
    await Promise.all([
      supabase.from("branches").select("id, name, address").order("name"),
      supabase.from("v_dashboard_sales_by_branch").select("branch_id, today_total"),
      supabase.from("cash_sessions").select("id, branch_id").eq("status", "open"),
    ]);

  const salesByBranch = new Map(
    (branchSales ?? []).map((entry) => [entry.branch_id, Number(entry.today_total ?? 0)]),
  );
  const openSessionsByBranch = new Set((openSessions ?? []).map((entry) => entry.branch_id));

  return (
    <AppShell title="Punto de Venta" userEmail={user.email} userRole={role} active="pos">
      <p className="mb-6 text-zinc-500">
        Seleccioná una sucursal para continuar con caja, stock y venta rápida.
      </p>

      <div className="grid grid-cols-1 gap-4 xl:grid-cols-3">
        {branches?.map((branch) => {
          const todayTotal = salesByBranch.get(branch.id) ?? 0;

          return (
            <Link
              key={branch.id}
              href={`/pos/${branch.id}`}
              className="rounded-xl border bg-white p-6 transition hover:shadow-md"
            >
              <div className="flex items-start justify-between gap-3">
                <div>
                  <h3 className="text-lg font-semibold">{branch.name}</h3>
                  <p className="mt-1 text-sm text-zinc-500">
                    {branch.address ?? "Sucursal activa"}
                  </p>
                </div>
                <span
                  className={`rounded-full px-3 py-1 text-xs font-medium ${
                    openSessionsByBranch.has(branch.id)
                      ? "bg-emerald-100 text-emerald-700"
                      : "bg-zinc-100 text-zinc-600"
                  }`}
                >
                  {openSessionsByBranch.has(branch.id) ? "Caja abierta" : "Sin caja abierta"}
                </span>
              </div>

              <div className="mt-6">
                <p className="text-sm text-zinc-500">Ventas de hoy</p>
                <p className="mt-1 text-2xl font-semibold">
                  ${todayTotal.toLocaleString("es-MX", { minimumFractionDigits: 2 })}
                </p>
              </div>
            </Link>
          );
        })}

        {(!branches || branches.length === 0) && (
          <p className="text-zinc-400">No hay sucursales disponibles</p>
        )}
      </div>
    </AppShell>
  );
}
