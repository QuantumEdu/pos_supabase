import { createClient } from "@/lib/supabase";
import { redirect } from "next/navigation";

export default async function ProductsPage() {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) redirect("/login");

  const { data: products } = await supabase
    .from("products")
    .select("id, name, category:categories(name), brand:brands(name)")
    .limit(50);

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
            className="block rounded-lg bg-blue-50 px-4 py-2 text-sm font-medium text-blue-700"
          >
            Productos
          </a>
          <a
            href="/pos"
            className="block rounded-lg px-4 py-2 text-sm font-medium text-zinc-600 transition hover:bg-zinc-100"
          >
            Punto de Venta
          </a>
        </nav>
      </aside>

      <main className="flex-1 overflow-auto">
        <header className="border-b bg-white px-8 py-4">
          <h1 className="text-xl font-semibold">Productos</h1>
        </header>

        <div className="p-8">
          <div className="overflow-hidden rounded-xl border bg-white">
            <table className="w-full text-sm">
              <thead>
                <tr className="border-b bg-zinc-50 text-left">
                  <th className="px-6 py-3 font-medium text-zinc-500">
                    Producto
                  </th>
                  <th className="px-6 py-3 font-medium text-zinc-500">
                    Categoría
                  </th>
                  <th className="px-6 py-3 font-medium text-zinc-500">
                    Marca
                  </th>
                </tr>
              </thead>
              <tbody>
                {products?.map((p) => (
                  <tr key={p.id} className="border-b last:border-0">
                    <td className="px-6 py-4">{p.name}</td>
                    <td className="px-6 py-4 text-zinc-500">
                      {(p.category as { name?: string })?.name ?? "—"}
                    </td>
                    <td className="px-6 py-4 text-zinc-500">
                      {(p.brand as { name?: string })?.name ?? "—"}
                    </td>
                  </tr>
                ))}
                {(!products || products.length === 0) && (
                  <tr>
                    <td
                      colSpan={3}
                      className="px-6 py-8 text-center text-zinc-400"
                    >
                      No hay productos registrados
                    </td>
                  </tr>
                )}
              </tbody>
            </table>
          </div>
        </div>
      </main>
    </div>
  );
}
