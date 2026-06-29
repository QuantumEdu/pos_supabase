import Link from "next/link";
import { LogoutButton } from "@/app/dashboard/logout-button";

const navigation = [
  { href: "/dashboard", label: "Dashboard", key: "dashboard" },
  { href: "/products", label: "Productos", key: "products" },
  { href: "/pos", label: "Punto de Venta", key: "pos" },
] as const;

export function AppShell({
  title,
  userEmail,
  userRole,
  active,
  children,
}: {
  title: string;
  userEmail: string | undefined;
  userRole?: string;
  active: (typeof navigation)[number]["key"];
  children: React.ReactNode;
}) {
  return (
    <div className="flex min-h-screen bg-zinc-50">
      <aside className="hidden w-64 flex-col border-r bg-white md:flex">
        <div className="border-b px-6 py-4">
          <h2 className="text-lg font-bold">Farmacia Salud</h2>
          <p className="text-xs text-zinc-500">{userEmail ?? "Sesión activa"}</p>
          {userRole && (
            <span className="mt-2 inline-flex rounded-full bg-zinc-100 px-2.5 py-1 text-[11px] font-medium uppercase tracking-[0.16em] text-zinc-600">
              {userRole}
            </span>
          )}
        </div>

        <nav className="flex-1 space-y-1 px-3 py-4">
          {navigation.map((item) => (
            <Link
              key={item.href}
              href={item.href}
              className={`block rounded-lg px-4 py-2 text-sm font-medium transition ${
                item.key === active
                  ? "bg-blue-50 text-blue-700"
                  : "text-zinc-600 hover:bg-zinc-100"
              }`}
            >
              {item.label}
            </Link>
          ))}
        </nav>

        <div className="border-t px-3 py-3">
          <LogoutButton />
        </div>
      </aside>

      <main className="flex-1 overflow-auto">
        <header className="border-b bg-white px-5 py-4 md:px-8">
          <div className="flex items-center justify-between gap-4">
            <div>
              <p className="text-xs uppercase tracking-[0.24em] text-zinc-400 md:hidden">
                Farmacia Salud
              </p>
              <h1 className="text-xl font-semibold">{title}</h1>
              {userRole && (
                <p className="mt-1 text-xs uppercase tracking-[0.16em] text-zinc-400 md:hidden">
                  {userRole}
                </p>
              )}
            </div>
            <div className="md:hidden">
              <LogoutButton compact />
            </div>
          </div>

          <nav className="mt-4 flex gap-2 overflow-x-auto md:hidden">
            {navigation.map((item) => (
              <Link
                key={item.href}
                href={item.href}
                className={`whitespace-nowrap rounded-full px-3 py-1.5 text-sm font-medium ${
                  item.key === active
                    ? "bg-blue-600 text-white"
                    : "bg-zinc-100 text-zinc-600"
                }`}
              >
                {item.label}
              </Link>
            ))}
          </nav>
        </header>

        <div className="p-5 md:p-8">{children}</div>
      </main>
    </div>
  );
}
