"use client"

import { useState } from "react"
import Link from "next/link"
import { Plus, Search } from "lucide-react"
import { useTenants } from "@/hooks/use-tenants"
import { TenantBadge } from "@/components/promotoras/tenant-badge"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"

function formatDate(iso: string | null) {
  if (!iso) return "—"
  return new Date(iso).toLocaleDateString("es-MX", { day: "2-digit", month: "short", year: "numeric" })
}

export default function PromotorasPage() {
  const { data: tenants, isLoading, error } = useTenants()
  const [search, setSearch] = useState("")

  const filtered = (tenants ?? []).filter(
    (t) =>
      t.nombre.toLowerCase().includes(search.toLowerCase()) ||
      t.subdominio.toLowerCase().includes(search.toLowerCase())
  )

  return (
    <div className="space-y-4">
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-xl font-semibold">Promotorías</h1>
          <p className="text-sm text-muted-foreground">Todos los clientes registrados</p>
        </div>
        <Button asChild size="sm">
          <Link href="/promotoras/nueva">
            <Plus className="h-4 w-4" />
            Nueva promotoría
          </Link>
        </Button>
      </div>

      <div className="relative max-w-xs">
        <Search className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground" />
        <Input
          placeholder="Buscar por nombre o subdominio..."
          value={search}
          onChange={(e) => setSearch(e.target.value)}
          className="pl-9"
        />
      </div>

      {isLoading && <div className="text-sm text-muted-foreground">Cargando...</div>}
      {error && <div className="text-sm text-destructive">Error al cargar promotorías.</div>}

      {!isLoading && !error && (
        <div className="rounded-lg border bg-white overflow-hidden">
          <table className="w-full text-sm">
            <thead className="bg-slate-50 text-left text-xs text-muted-foreground">
              <tr>
                <th className="px-4 py-3 font-medium">Promotoría</th>
                <th className="px-4 py-3 font-medium">Subdominio</th>
                <th className="px-4 py-3 font-medium">Plan</th>
                <th className="px-4 py-3 font-medium">Estado</th>
                <th className="px-4 py-3 font-medium">Vencimiento</th>
                <th className="px-4 py-3 font-medium">Director</th>
              </tr>
            </thead>
            <tbody className="divide-y">
              {filtered.length === 0 && (
                <tr>
                  <td colSpan={6} className="px-4 py-8 text-center text-muted-foreground">
                    {search ? "Sin resultados para tu búsqueda." : "Sin promotorías registradas."}
                  </td>
                </tr>
              )}
              {filtered.map((t) => (
                <tr key={t.id} className="hover:bg-slate-50">
                  <td className="px-4 py-3">
                    <Link href={`/promotoras/${t.id}`} className="font-medium hover:underline">
                      {t.nombre}
                    </Link>
                  </td>
                  <td className="px-4 py-3 text-muted-foreground">{t.subdominio}</td>
                  <td className="px-4 py-3 capitalize">{t.tipo_plan}</td>
                  <td className="px-4 py-3">
                    <TenantBadge estado={t.estado_licencia} />
                  </td>
                  <td className="px-4 py-3 text-muted-foreground">
                    {formatDate(t.fecha_vencimiento_licencia)}
                  </td>
                  <td className="px-4 py-3 text-muted-foreground">
                    {t.usuario_maestro_email ?? <span className="italic">Sin director</span>}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  )
}
