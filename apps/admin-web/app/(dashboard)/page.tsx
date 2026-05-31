"use client"

import Link from "next/link"
import { useStats } from "@/hooks/use-tenants"
import { StatsCards } from "@/components/dashboard/stats-cards"
import { TenantBadge } from "@/components/promotoras/tenant-badge"

function formatDate(iso: string) {
  return new Date(iso).toLocaleDateString("es-MX", { day: "2-digit", month: "short", year: "numeric" })
}

export default function DashboardPage() {
  const { data: stats, isLoading, error } = useStats()

  if (isLoading) return <div className="text-sm text-muted-foreground">Cargando...</div>
  if (error || !stats) return <div className="text-sm text-destructive">Error al cargar estadísticas.</div>

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-xl font-semibold">Dashboard</h1>
        <p className="text-sm text-muted-foreground">Resumen de promotorías y licencias</p>
      </div>

      <StatsCards stats={stats} />

      <div>
        <h2 className="mb-3 text-sm font-semibold text-slate-700">Últimas altas</h2>
        <div className="rounded-lg border bg-white overflow-hidden">
          <table className="w-full text-sm">
            <thead className="bg-slate-50 text-left text-xs text-muted-foreground">
              <tr>
                <th className="px-4 py-3 font-medium">Promotoría</th>
                <th className="px-4 py-3 font-medium">Subdominio</th>
                <th className="px-4 py-3 font-medium">Estado</th>
                <th className="px-4 py-3 font-medium">Alta</th>
              </tr>
            </thead>
            <tbody className="divide-y">
              {stats.ultimas_altas.length === 0 && (
                <tr>
                  <td colSpan={4} className="px-4 py-6 text-center text-muted-foreground">
                    Sin promotorías registradas todavía.
                  </td>
                </tr>
              )}
              {stats.ultimas_altas.map((t) => (
                <tr key={t.id} className="hover:bg-slate-50">
                  <td className="px-4 py-3">
                    <Link href={`/promotoras/${t.id}`} className="font-medium hover:underline">
                      {t.nombre}
                    </Link>
                  </td>
                  <td className="px-4 py-3 text-muted-foreground">{t.subdominio}</td>
                  <td className="px-4 py-3">
                    <TenantBadge estado={t.estado_licencia} />
                  </td>
                  <td className="px-4 py-3 text-muted-foreground">{formatDate(t.created_at)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </div>
    </div>
  )
}
