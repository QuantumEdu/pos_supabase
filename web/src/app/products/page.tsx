import { AppShell } from "@/components/app-shell";
import { requireUser } from "@/lib/auth";

export default async function ProductsPage() {
  const { supabase, user, role } = await requireUser();

  const [{ data: products }, { data: variants }, { data: activePrices }] =
    await Promise.all([
      supabase
        .from("products")
        .select("id, name, category:categories(name), brand:brands(name)")
        .order("name")
        .limit(50),
      supabase.from("product_variants").select("id, product_id").limit(500),
      supabase
        .from("product_prices")
        .select("variant_id, price")
        .is("effective_until", null)
        .limit(500),
    ]);

  const variantsByProduct = new Map<string, number>();
  for (const variant of variants ?? []) {
    variantsByProduct.set(
      variant.product_id,
      (variantsByProduct.get(variant.product_id) ?? 0) + 1,
    );
  }

  const pricedVariantIds = new Set((activePrices ?? []).map((item) => item.variant_id));

  return (
    <AppShell title="Productos" userEmail={user.email} userRole={role} active="products">
      <div className="mb-6 grid grid-cols-1 gap-4 md:grid-cols-3">
        <SummaryCard label="Productos" value={String(products?.length ?? 0)} />
        <SummaryCard label="Variantes" value={String(variants?.length ?? 0)} />
        <SummaryCard
          label="Variantes con precio activo"
          value={String(pricedVariantIds.size)}
        />
      </div>

      <div className="overflow-hidden rounded-xl border bg-white">
        <table className="w-full text-sm">
          <thead>
            <tr className="border-b bg-zinc-50 text-left">
              <th className="px-6 py-3 font-medium text-zinc-500">Producto</th>
              <th className="px-6 py-3 font-medium text-zinc-500">Categoría</th>
              <th className="px-6 py-3 font-medium text-zinc-500">Marca</th>
              <th className="px-6 py-3 font-medium text-zinc-500">Variantes</th>
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
                <td className="px-6 py-4 text-zinc-500">
                  {variantsByProduct.get(p.id) ?? 0}
                </td>
              </tr>
            ))}
            {(!products || products.length === 0) && (
              <tr>
                <td
                  colSpan={4}
                  className="px-6 py-8 text-center text-zinc-400"
                >
                  No hay productos registrados
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>
    </AppShell>
  );
}

function SummaryCard({ label, value }: { label: string; value: string }) {
  return (
    <div className="rounded-xl border bg-white p-5">
      <p className="text-sm text-zinc-500">{label}</p>
      <p className="mt-1 text-2xl font-semibold">{value}</p>
    </div>
  );
}
