"use client"

import { useState, useCallback, useMemo } from "react"
import { Plus, Upload, Search, Users, UserCheck, UserX } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { useQuery, useQueryClient } from "@tanstack/react-query"
import { api } from "@/lib/api"
import type { AgenteRow } from "@/components/agentes/types"
import { AgentesTabla } from "@/components/agentes/agentes-tabla"
import { AgregarAgenteForm } from "@/components/agentes/agregar-agente-form"
import { ImportarAgentesModal } from "@/components/agentes/importar-agentes-modal"
import { AgenteDrawer } from "@/components/agentes/agente-drawer"
import { useUser } from "@/components/providers/user-provider"

const ROLES_ESCRITURA = ["director_general", "director_ops", "gerente"]

type FiltroEstatus = "activos" | "inactivos" | "todos"

const FILTROS: { key: FiltroEstatus; label: string }[] = [
  { key: "activos", label: "Activos" },
  { key: "todos", label: "Todos" },
  { key: "inactivos", label: "Inactivos" },
]

// ── Page ──────────────────────────────────────────────────────────────────────

export default function AgentesPage() {
  const { perfil } = useUser()
  const qc = useQueryClient()
  const puedeEscribir = perfil ? ROLES_ESCRITURA.includes(perfil.rol) : false

  const [search, setSearch] = useState("")
  const [filtro, setFiltro] = useState<FiltroEstatus>("activos")
  const [showAgregar, setShowAgregar] = useState(false)
  const [showImportar, setShowImportar] = useState(false)
  const [selectedId, setSelectedId] = useState<string | null>(null)

  // Dos queries separadas para tener métricas precisas de activos e inactivos
  const { data, isLoading } = useQuery({
    queryKey: ["agentes", "activos"],
    queryFn: () => api.get<AgenteRow[]>("/agentes?limit=200&activo=true"),
    staleTime: 30_000,
  })

  const { data: inactivos } = useQuery({
    queryKey: ["agentes", "inactivos"],
    queryFn: () => api.get<AgenteRow[]>("/agentes?limit=200&activo=false"),
    staleTime: 30_000,
  })

  const handleSuccess = useCallback(() => {
    qc.invalidateQueries({ queryKey: ["agentes"] })
  }, [qc])

  const activos = data ?? []
  const inactivosList = inactivos ?? []
  const todos = useMemo(
    () => [...activos, ...inactivosList],
    [activos, inactivosList]
  )

  const poolBase: AgenteRow[] =
    filtro === "activos" ? activos : filtro === "inactivos" ? inactivosList : todos

  const rows = useMemo(() => {
    const q = search.trim().toLowerCase()
    if (!q) return poolBase
    return poolBase.filter(
      (r) =>
        r.nombre.toLowerCase().includes(q) ||
        r.cua.toLowerCase().includes(q) ||
        (r.nombre_comercial?.toLowerCase().includes(q) ?? false) ||
        (r.rfc?.toLowerCase().includes(q) ?? false)
    )
  }, [poolBase, search])

  const stats = [
    {
      icon: Users,
      label: "Total agentes",
      value: todos.length,
      color: "text-slate-700",
      bg: "bg-slate-50",
    },
    {
      icon: UserCheck,
      label: "Activos",
      value: activos.length,
      color: "text-emerald-700",
      bg: "bg-emerald-50",
    },
    {
      icon: UserX,
      label: "Inactivos",
      value: inactivosList.length,
      color: "text-red-600",
      bg: "bg-red-50",
    },
  ]

  return (
    <div className="space-y-6">

      {/* ── Encabezado ── */}
      <div className="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
        <div>
          <h2 className="text-xl font-bold text-slate-900">Agentes</h2>
          <p className="mt-0.5 text-sm text-muted-foreground">
            Catálogo de agentes de seguros de la promotoría
          </p>
        </div>
        {puedeEscribir && (
          <div className="flex shrink-0 gap-2">
            <Button
              variant="outline"
              size="sm"
              className="gap-1.5"
              onClick={() => setShowImportar(true)}
            >
              <Upload className="h-4 w-4" />
              Importar Excel
            </Button>
            <Button size="sm" className="gap-1.5" onClick={() => setShowAgregar(true)}>
              <Plus className="h-4 w-4" />
              Agregar agente
            </Button>
          </div>
        )}
      </div>

      {/* ── Métricas ── */}
      <div className="grid grid-cols-3 gap-3">
        {stats.map(({ icon: Icon, label, value, color, bg }) => (
          <div key={label} className={`rounded-xl border px-4 py-3 ${bg}`}>
            <div className="flex items-center gap-2">
              <Icon className={`h-4 w-4 ${color}`} />
              <p className={`text-xl font-bold ${color}`}>{value}</p>
            </div>
            <p className="mt-0.5 text-xs text-slate-500">{label}</p>
          </div>
        ))}
      </div>

      {/* ── Toolbar ── */}
      <div className="flex flex-col gap-3 sm:flex-row sm:items-center">
        {/* Búsqueda */}
        <div className="relative flex-1 max-w-sm">
          <Search className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-slate-400" />
          <Input
            placeholder="Buscar por nombre, CUA, RFC..."
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            className="pl-9"
          />
        </div>

        {/* Filtro estatus */}
        <div className="flex rounded-lg border bg-slate-100 p-1">
          {FILTROS.map(({ key, label }) => (
            <button
              key={key}
              onClick={() => setFiltro(key)}
              className={`rounded-md px-3 py-1.5 text-xs font-medium transition-colors ${
                filtro === key
                  ? "bg-white text-slate-900 shadow-sm"
                  : "text-slate-500 hover:text-slate-700"
              }`}
            >
              {label}
            </button>
          ))}
        </div>

        {/* Contador de resultados */}
        {(search || filtro !== "todos") && (
          <p className="shrink-0 text-xs text-slate-500">
            {rows.length === 1 ? "1 resultado" : `${rows.length} resultados`}
          </p>
        )}
      </div>

      {/* ── Tabla ── */}
      {isLoading ? (
        <div className="flex items-center justify-center py-20 text-sm text-slate-400">
          Cargando agentes...
        </div>
      ) : (
        <AgentesTabla
          rows={rows}
          onSelect={(row) => setSelectedId(row.id)}
          canEdit={puedeEscribir}
        />
      )}

      {/* ── Modales ── */}
      <AgregarAgenteForm
        open={showAgregar}
        onClose={() => setShowAgregar(false)}
        onSuccess={handleSuccess}
      />
      <ImportarAgentesModal
        open={showImportar}
        onClose={() => setShowImportar(false)}
        onSuccess={handleSuccess}
      />
      <AgenteDrawer
        agenteId={selectedId}
        open={selectedId !== null}
        onClose={() => setSelectedId(null)}
        onUpdated={handleSuccess}
      />
    </div>
  )
}
