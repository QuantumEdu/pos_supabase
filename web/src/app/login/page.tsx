import { createClient } from "@/lib/supabase-client";
import { AuthForm } from "./auth-form";

export default function LoginPage() {
  return (
    <div className="flex min-h-screen items-center justify-center bg-zinc-50">
      <div className="w-full max-w-sm rounded-xl border bg-white p-8 shadow-sm">
        <h1 className="mb-6 text-center text-2xl font-bold">Farmacia Salud</h1>
        <p className="mb-6 text-center text-sm text-zinc-500">
          Inicia sesión para continuar
        </p>
        <AuthForm />
      </div>
    </div>
  );
}
