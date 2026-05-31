import { redirect } from "next/navigation"
import { createServerClient } from "@supabase/ssr"

export default async function RootPage() {
  redirect("/dashboard")
}
