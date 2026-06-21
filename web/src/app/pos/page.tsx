import { createClient } from "@/lib/supabase";
import { redirect } from "next/navigation";

export default async function PosPage() {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) redirect("/login");

  const { data: branches } = await supabase
    .from("branches")
    .select("id, name");

  return (
    <div className="flex min-h-screen bg-zinc-50">
      <aside className="flex w-64 flex-col border-r bg-white">
        <div className="border-b px-6 py-4">
          <h2 className="text-lg font-bold">Farmacia Salud</h2>
        </div>
        <nav className="flex-1 space-y-1 px-3 py-4">
          <a
            href="/dashboard"
            className="block rounded-lg px-4 py-2 text-sm font-medium text-zinc-600 transition hover:bg-zinc-100"
          >
            Dashboard
          </a>
          <a
            href="/products"
            className="block rounded-lg px-4 py-2 text-sm font-medium text-zinc-600 transition hover:bg-zinc-100"
          >
            Productos
          </a>
          <a
            href="/pos"
            className="block rounded-lg bg-blue-50 px-4 py-2 text-sm font-medium text-blue-700"
          >
            Punto de Venta
          </a>
        </nav>
      </aside>

      <main className="flex-1 overflow-auto">
        <header className="border-b bg-white px-8 py-4">
          <h1 className="text-xl font-semibold">Punto de Venta</h1>
        </header>

        <div className="p-8">
          <p className="mb-6 text-zinc-500">
            Seleccioná una sucursal para iniciar una venta.
          </p>

          <div className="grid grid-cols-1 gap-4 md:grid-cols-3">
            {branches?.map((b) => (
              <a
                key={b.id}
                href={`/pos/${b.id}`}
                className="rounded-xl border bg-white p-6 transition hover:shadow-md"
              >
                <h3 className="text-lg font-semibold">{b.name}</h3>
                <p className="mt-1 text-sm text-zinc-500">
                  Iniciar venta en esta sucursal
                </p>
              </a>
            ))}
            {(!branches || branches.length === 0) && (
              <p className="text-zinc-400">
                No hay sucursales disponibles
              </p>
            )}
          </div>
        </div>
      </main>
    </div>
  );
}
