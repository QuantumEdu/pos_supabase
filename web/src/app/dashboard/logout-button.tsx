"use client";

import { createClient } from "@/lib/supabase-client";
import { useRouter } from "next/navigation";

export function LogoutButton({ compact = false }: { compact?: boolean }) {
  const router = useRouter();
  const supabase = createClient();

  async function handleLogout() {
    await supabase.auth.signOut();
    router.push("/login");
    router.refresh();
  }

  return (
    <button
      onClick={handleLogout}
      className={compact
        ? "rounded-lg bg-zinc-100 px-3 py-2 text-sm text-zinc-600 transition hover:bg-zinc-200"
        : "w-full rounded-lg px-4 py-2 text-left text-sm text-zinc-600 transition hover:bg-zinc-100"}
    >
      Cerrar sesión
    </button>
  );
}
