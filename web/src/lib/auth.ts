import { createClient } from "@/lib/supabase";
import { redirect } from "next/navigation";

export async function requireUser() {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) {
    redirect("/login");
  }

  const role =
    typeof user.app_metadata?.role === "string"
      ? user.app_metadata.role
      : undefined;

  return { supabase, user, role };
}
