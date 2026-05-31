"use client"

import { useRouter } from "next/navigation"
import { LogOut } from "lucide-react"
import { Button } from "@/components/ui/button"

export function Header({ title }: { title?: string }) {
  const router = useRouter()

  async function logout() {
    await fetch("/api/auth/logout", { method: "POST" })
    router.push("/login")
    router.refresh()
  }

  return (
    <header className="flex h-14 items-center justify-between border-b bg-white px-6">
      <span className="text-sm font-medium text-slate-700">{title ?? "Panel Superadmin"}</span>
      <Button variant="ghost" size="sm" onClick={logout} className="gap-2 text-slate-600">
        <LogOut className="h-4 w-4" />
        Salir
      </Button>
    </header>
  )
}
