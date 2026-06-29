import Link from "next/link";
import { notFound } from "next/navigation";
import { AppShell } from "@/components/app-shell";
import { requireUser } from "@/lib/auth";
import { PosTerminal } from "./pos-terminal";

export default async function BranchPosPage({
  params,
}: {
  params: Promise<{ branchId: string }>;
}) {
  const { branchId } = await params;
  const { supabase, user, role } = await requireUser();

  const [
    { data: branch },
    { data: sessions },
    { data: stockRows },
    { data: variants },
    { data: prices },
    { data: customers },
    { data: companyUsers },
    { data: outstandingBalances },
    { data: creditBalances },
    { data: recentSales },
    { data: recentSaleItems },
  ] =
    await Promise.all([
      supabase
        .from("branches")
        .select("id, name, address, phone")
        .eq("id", branchId)
        .maybeSingle(),
      supabase
        .from("cash_sessions")
        .select("id, opened_at, opening_amount, expected_cash_amount, cashier_user_id")
        .eq("branch_id", branchId)
        .eq("status", "open")
        .order("opened_at", { ascending: false })
        .limit(5),
      supabase
        .from("v_stock_available")
        .select("variant_id, physical_qty")
        .eq("branch_id", branchId)
        .order("physical_qty", { ascending: false })
        .limit(12),
      supabase
        .from("product_variants")
        .select("id, name, sku, product:products(name)")
        .order("name")
        .limit(200),
      supabase
        .from("product_prices")
        .select("variant_id, price, currency")
        .is("effective_until", null)
        .limit(200),
      supabase
        .from("customers")
        .select("id, name, phone, email")
        .order("name")
        .limit(200),
      supabase.from("company_users").select("user_id").limit(500),
      supabase
        .from("v_dashboard_outstanding_balances")
        .select("customer_id, remaining_amount"),
      supabase
        .from("customer_balances")
        .select(
          "id, customer_id, sale_id, total_amount, paid_amount, remaining_amount, status, created_at, sale:sales(branch_id, sale_number, total)",
        )
        .in("status", ["pending", "partial"])
        .order("created_at", { ascending: true })
        .limit(200),
      supabase
        .from("sales")
        .select("id, sale_number, total, status, created_at, customer_id")
        .eq("branch_id", branchId)
        .eq("status", "active")
        .order("created_at", { ascending: false })
        .limit(20),
      supabase
        .from("sale_items")
        .select(
          "id, sale_id, variant_id, quantity, unit_price, sale:sales!inner(branch_id, status, sale_number, created_at), variant:product_variants(name, product:products(name)), batches:sale_item_batches(id, quantity)",
        )
        .order("created_at", { ascending: false })
        .limit(200),
    ]);

  if (!branch) {
    notFound();
  }

  const stockByVariant = new Map(
    (stockRows ?? []).map((row) => [row.variant_id, Number(row.physical_qty ?? 0)]),
  );
  const priceByVariant = new Map(
    (prices ?? []).map((row) => [row.variant_id, { price: row.price, currency: row.currency }]),
  );

  const sellableVariants = (variants ?? [])
    .filter((variant) => stockByVariant.has(variant.id) || priceByVariant.has(variant.id))
    .map((variant) => ({
      id: variant.id,
      name: variant.name,
      sku: variant.sku,
      productName: (variant.product as { name?: string } | null)?.name ?? "Producto",
      stock: stockByVariant.get(variant.id) ?? 0,
      price: priceByVariant.get(variant.id)?.price ?? null,
      currency: priceByVariant.get(variant.id)?.currency ?? "MXN",
    }))
    .sort((a, b) => b.stock - a.stock || a.name.localeCompare(b.name))
    .slice(0, 12);

  const companyUserIds = new Set((companyUsers ?? []).map((item) => item.user_id));
  const outstandingByCustomer = new Map(
    (outstandingBalances ?? []).map((item) => [
      item.customer_id,
      Number(item.remaining_amount ?? 0),
    ]),
  );

  const supportedCustomers = (customers ?? [])
    .filter((customer) => companyUserIds.has(customer.id))
    .map((customer) => ({
      id: customer.id,
      name: customer.name,
      phone: customer.phone,
      email: customer.email,
      outstandingAmount: outstandingByCustomer.get(customer.id) ?? 0,
    }));

  const balancesByCustomer = new Map<string, Array<{
    id: string;
    saleId: string;
    saleNumber: number | null;
    totalAmount: number;
    paidAmount: number;
    remainingAmount: number;
    status: string;
    createdAt: string;
  }>>();

  for (const balance of creditBalances ?? []) {
    const sale = balance.sale as
      | { branch_id?: string; sale_number?: number | null; total?: number | null }
      | null;

    if (sale?.branch_id !== branchId) {
      continue;
    }

    const entries = balancesByCustomer.get(balance.customer_id) ?? [];
    entries.push({
      id: balance.id,
      saleId: balance.sale_id,
      saleNumber: sale?.sale_number ?? null,
      totalAmount: Number(balance.total_amount ?? 0),
      paidAmount: Number(balance.paid_amount ?? 0),
      remainingAmount: Number(balance.remaining_amount ?? 0),
      status: balance.status,
      createdAt: balance.created_at,
    });
    balancesByCustomer.set(balance.customer_id, entries);
  }

  const customersWithBalances = supportedCustomers.map((customer) => ({
    ...customer,
    balances: balancesByCustomer.get(customer.id) ?? [],
  }));

  const customerNames = new Map(
    customersWithBalances.map((customer) => [customer.id, customer.name]),
  );

  const cancelableSales = (recentSales ?? []).map((sale) => ({
    id: sale.id,
    saleNumber: sale.sale_number,
    total: Number(sale.total ?? 0),
    status: sale.status,
    createdAt: sale.created_at,
    customerName: sale.customer_id ? customerNames.get(sale.customer_id) ?? null : null,
  }));

  const returnableSaleItems = (recentSaleItems ?? [])
    .filter((item) => {
      const sale = item.sale as
        | { branch_id?: string; status?: string; sale_number?: number | null; created_at?: string | null }
        | null;

      return sale?.branch_id === branchId && sale?.status === "active";
    })
    .map((item) => {
      const sale = item.sale as
        | { branch_id?: string; status?: string; sale_number?: number | null; created_at?: string | null }
        | null;
      const variant = item.variant as
        | { name?: string | null; product?: { name?: string | null } | null }
        | null;

      return {
        id: item.id,
        saleId: item.sale_id,
        saleNumber: sale?.sale_number ?? null,
        createdAt: sale?.created_at ?? null,
        variantId: item.variant_id,
        quantity: Number(item.quantity ?? 0),
        unitPrice: Number(item.unit_price ?? 0),
        variantName: variant?.name ?? "Variante",
        productName: variant?.product?.name ?? "Producto",
        batches: ((item.batches as Array<{ id: string; quantity: number | string | null }> | null) ?? []).map(
          (batch) => ({
            id: batch.id,
            quantity: Number(batch.quantity ?? 0),
          }),
        ),
      };
    })
    .slice(0, 30);

  return (
    <AppShell
      title={`POS · ${branch.name}`}
      userEmail={user.email}
      userRole={role}
      active="pos"
    >
      <div className="mb-6 flex flex-wrap items-center gap-3">
        <Link
          href="/pos"
          className="rounded-full bg-zinc-100 px-3 py-1.5 text-sm text-zinc-600"
        >
          Volver a sucursales
        </Link>
        <span className="rounded-full bg-blue-50 px-3 py-1.5 text-sm text-blue-700">
          {sessions && sessions.length > 0 ? `${sessions.length} caja(s) abierta(s)` : "Sin caja abierta"}
        </span>
      </div>

      <div className="mb-6 rounded-2xl border bg-white p-6">
        <h2 className="text-lg font-semibold">Sucursal</h2>
        <dl className="mt-4 grid grid-cols-1 gap-4 text-sm md:grid-cols-3">
          <div>
            <dt className="text-zinc-400">Nombre</dt>
            <dd className="font-medium text-zinc-800">{branch.name}</dd>
          </div>
          <div>
            <dt className="text-zinc-400">Dirección</dt>
            <dd className="font-medium text-zinc-800">{branch.address ?? "No registrada"}</dd>
          </div>
          <div>
            <dt className="text-zinc-400">Teléfono</dt>
            <dd className="font-medium text-zinc-800">{branch.phone ?? "No registrado"}</dd>
          </div>
        </dl>
      </div>

      <PosTerminal
        branchId={branchId}
        currentUserRole={role}
        sessions={sessions ?? []}
        variants={sellableVariants}
        customers={customersWithBalances}
        sales={cancelableSales}
        returnableItems={returnableSaleItems}
      />
    </AppShell>
  );
}
