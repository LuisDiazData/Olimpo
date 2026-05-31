"use client"

import Link from "next/link"
import { useRouter, usePathname } from "next/navigation"
import { useCallback } from "react"
import {
  LayoutDashboard,
  Users,
  FileText,
  Bell,
  Settings,
  LogOut,
  Shield,
  Search,
  Command,
  GitFork,
} from "lucide-react"
import { Button } from "@/components/ui/button"
import { useCommandPalette } from "@/components/providers/command-palette-provider"
import { useUser } from "@/components/providers/user-provider"

const NAV_BY_ROLE: Record<string, { href: string; label: string; icon: React.ElementType }[]> = {
  director_general: [
    { href: "/dashboard", label: "Dashboard", icon: LayoutDashboard },
    { href: "/tramites", label: "Trámites", icon: FileText },
    { href: "/agentes", label: "Agentes", icon: Users },
    { href: "/asignaciones", label: "Asignaciones", icon: GitFork },
    { href: "/notificaciones", label: "Notificaciones", icon: Bell },
    { href: "/usuarios", label: "Usuarios", icon: Shield },
    { href: "/configuracion", label: "Configuración", icon: Settings },
  ],
  director_ops: [
    { href: "/dashboard", label: "Dashboard", icon: LayoutDashboard },
    { href: "/tramites", label: "Trámites", icon: FileText },
    { href: "/agentes", label: "Agentes", icon: Users },
    { href: "/asignaciones", label: "Asignaciones", icon: GitFork },
    { href: "/notificaciones", label: "Notificaciones", icon: Bell },
    { href: "/usuarios", label: "Usuarios", icon: Shield },
    { href: "/configuracion", label: "Configuración", icon: Settings },
  ],
  gerente: [
    { href: "/dashboard", label: "Dashboard", icon: LayoutDashboard },
    { href: "/tramites", label: "Trámites", icon: FileText },
    { href: "/agentes", label: "Agentes", icon: Users },
    { href: "/asignaciones", label: "Asignaciones", icon: GitFork },
    { href: "/notificaciones", label: "Notificaciones", icon: Bell },
  ],
  analista: [
    { href: "/dashboard", label: "Dashboard", icon: LayoutDashboard },
    { href: "/tramites", label: "Trámites", icon: FileText },
    { href: "/notificaciones", label: "Notificaciones", icon: Bell },
  ],
}

function initials(nombre: string): string {
  return nombre
    .split(" ")
    .slice(0, 2)
    .map((p) => p[0]?.toUpperCase() ?? "")
    .join("")
}

function rolLabel(rol: string): string {
  const map: Record<string, string> = {
    director_general: "Director General",
    director_ops: "Director de Operaciones",
    gerente: "Gerente",
    analista: "Analista",
  }
  return map[rol] ?? rol
}

export default function DashboardLayout({
  children,
}: {
  children: React.ReactNode
}) {
  const router = useRouter()
  const { setOpen } = useCommandPalette()
  const { perfil } = useUser()
  const openPalette = useCallback(() => setOpen(true), [setOpen])

  async function logout() {
    await fetch("/api/auth/logout", { method: "POST" })
    router.push("/login")
    router.refresh()
  }

  const pathname = usePathname()
  const rol = perfil?.rol ?? "analista"
  const navItems = NAV_BY_ROLE[rol] ?? NAV_BY_ROLE.analista
  const nombre = perfil?.nombre ?? perfil?.email?.split("@")[0] ?? "Usuario"
  const showSkeleton = !perfil
  const initialsStr = showSkeleton ? "…" : initials(nombre)
  const currentLabel = navItems.find((i) => pathname.startsWith(i.href))?.label ?? "Olimpo"

  return (
    <div className="flex min-h-screen bg-slate-50">
      <aside className="flex w-64 flex-col border-r bg-white">
        <div className="flex h-14 items-center gap-2.5 border-b px-6">
          <div className="flex h-8 w-8 items-center justify-center rounded-lg bg-slate-900">
            <Shield className="h-4 w-4 text-white" />
          </div>
          <span className="font-semibold text-slate-900">Olimpo</span>
        </div>

        <div className="px-3 py-3 border-b">
          <button
            onClick={openPalette}
            className="flex w-full items-center gap-2 rounded-lg border border-slate-200 bg-slate-50 px-3 py-2 text-sm text-slate-500 hover:border-slate-300 hover:bg-slate-100 transition-colors text-left"
          >
            <Search className="h-3.5 w-3.5 shrink-0" />
            <span className="flex-1">Buscar trámites, agentes...</span>
            <kbd className="hidden sm:inline-flex h-5 items-center gap-0.5 rounded border border-slate-200 bg-white px-1.5 text-xs text-slate-400 font-mono shadow-sm">
              <Command className="h-3 w-3" />K
            </kbd>
          </button>
        </div>

        <nav className="flex-1 space-y-1 px-3 py-4">
          {navItems.map((item) => (
            <Link
              key={item.href}
              href={item.href}
              className={`flex items-center gap-3 rounded-md px-3 py-2 text-sm font-medium transition-colors ${
                pathname.startsWith(item.href)
                  ? "bg-slate-100 text-slate-900"
                  : "text-slate-600 hover:bg-slate-100 hover:text-slate-900"
              }`}
            >
              <item.icon className="h-4 w-4" />
              {item.label}
            </Link>
          ))}
        </nav>

        <div className="border-t p-3">
          <div className="flex items-center gap-3 rounded-md px-3 py-2">
            <div className="flex h-8 w-8 items-center justify-center rounded-full bg-slate-200 shrink-0">
              {showSkeleton ? (
                <span className="text-xs text-slate-400">…</span>
              ) : (
                <span className="text-xs font-medium text-slate-600">{initialsStr}</span>
              )}
            </div>
            <div className="flex-1 min-w-0">
              <p className="text-sm font-medium text-slate-900 truncate">
                {showSkeleton ? "Cargando..." : nombre}
              </p>
              <p className="text-xs text-muted-foreground truncate">
                {showSkeleton ? "" : rolLabel(rol)}
              </p>
            </div>
            <Button variant="ghost" size="icon" onClick={logout}>
              <LogOut className="h-4 w-4" />
            </Button>
          </div>
        </div>
      </aside>

      <div className="flex flex-1 flex-col">
        <header className="flex h-14 items-center justify-between border-b bg-white px-6">
          <h1 className="text-sm font-medium text-slate-700">{currentLabel}</h1>
          <div className="flex items-center gap-2">
            <Button
              variant="ghost"
              size="sm"
              className="gap-1.5 text-slate-600"
              onClick={openPalette}
            >
              <Search className="h-4 w-4" />
              <span className="hidden sm:inline">Buscar</span>
              <kbd className="hidden sm:inline-flex h-4 items-center gap-0.5 rounded border border-slate-200 bg-slate-50 px-1 text-xs text-slate-400 font-mono shadow-sm">
                <Command className="h-3 w-3" />K
              </kbd>
            </Button>
            <Button variant="ghost" size="sm" className="gap-1.5 text-slate-600">
              <Bell className="h-4 w-4" />
            </Button>
          </div>
        </header>

        <main className="flex-1 p-6">{children}</main>
      </div>
    </div>
  )
}
