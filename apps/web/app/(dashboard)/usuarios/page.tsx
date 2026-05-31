"use client"

import { useState, useCallback, useMemo } from "react"
import { Plus, Search, Shield, UserCheck, UserX } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { useQuery, useQueryClient } from "@tanstack/react-query"
import { api } from "@/lib/api"
import { UsuariosTabla, type UsuarioRow } from "@/components/usuarios/usuarios-tabla"
import { AgregarUsuarioModal } from "@/components/usuarios/agregar-usuario-modal"
import { UsuarioDrawer } from "@/components/usuarios/usuario-drawer"
import { useUser } from "@/components/providers/user-provider"

const ROLES_ESCRITURA = ["director_general", "director_ops", "gerente"]

type FiltroEstatus = "activos" | "inactivos" | "todos"

const FILTROS: { key: FiltroEstatus; label: string }[] = [
  { key: "activos", label: "Activos" },
  { key: "todos", label: "Todos" },
  { key: "inactivos", label: "Inactivos" },
]

export default function UsuariosPage() {
  const { perfil } = useUser()
  const qc = useQueryClient()
  const puedeEscribir = perfil ? ROLES_ESCRITURA.includes(perfil.rol) : false

  const [search, setSearch] = useState("")
  const [filtro, setFiltro] = useState<FiltroEstatus>("activos")
  const [showAgregar, setShowAgregar] = useState(false)
  const [selectedRow, setSelectedRow] = useState<UsuarioRow | null>(null)

  const { data: activos = [] } = useQuery({
    queryKey: ["usuarios", "activos"],
    queryFn: () => api.get<UsuarioRow[]>("/usuarios?activo=true&limit=200"),
    staleTime: 30_000,
  })

  const { data: inactivos = [] } = useQuery({
    queryKey: ["usuarios", "inactivos"],
    queryFn: () => api.get<UsuarioRow[]>("/usuarios?activo=false&limit=200"),
    staleTime: 30_000,
  })

  const todos = useMemo(() => [...activos, ...inactivos], [activos, inactivos])

  const handleSuccess = useCallback(() => {
    qc.invalidateQueries({ queryKey: ["usuarios"] })
  }, [qc])

  const handleDesactivar = useCallback(async (row: UsuarioRow) => {
    if (!confirm(`¿Desactivar al usuario ${row.nombre}? Ya no podrá iniciar sesión.`)) return
    try {
      await api.delete(`/usuarios/${row.id}`)
      handleSuccess()
    } catch (err: unknown) {
      alert((err as Error).message)
    }
  }, [handleSuccess])

  const poolBase: UsuarioRow[] =
    filtro === "activos" ? activos : filtro === "inactivos" ? inactivos : todos

  const rows = useMemo(() => {
    const q = search.trim().toLowerCase()
    if (!q) return poolBase
    return poolBase.filter(
      (r) =>
        r.nombre.toLowerCase().includes(q) ||
        r.email.toLowerCase().includes(q) ||
        r.rol.toLowerCase().includes(q) ||
        (r.ramo?.toLowerCase().includes(q) ?? false)
    )
  }, [poolBase, search])

  const stats = [
    {
      icon: Shield,
      label: "Total usuarios",
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
      value: inactivos.length,
      color: "text-red-600",
      bg: "bg-red-50",
    },
  ]

  return (
    <div className="space-y-6">
      <div className="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
        <div>
          <h2 className="text-xl font-bold text-slate-900">Usuarios</h2>
          <p className="mt-0.5 text-sm text-muted-foreground">
            Gestión de usuarios y permisos del sistema
          </p>
        </div>
        {puedeEscribir && (
          <Button size="sm" className="gap-1.5 shrink-0" onClick={() => setShowAgregar(true)}>
            <Plus className="h-4 w-4" />
            Agregar usuario
          </Button>
        )}
      </div>

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

      <div className="flex flex-col gap-3 sm:flex-row sm:items-center">
        <div className="relative flex-1 max-w-sm">
          <Search className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-slate-400" />
          <Input
            placeholder="Buscar por nombre, correo, rol..."
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            className="pl-9"
          />
        </div>

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

        {(search || filtro !== "todos") && (
          <p className="shrink-0 text-xs text-slate-500">
            {rows.length === 1 ? "1 resultado" : `${rows.length} resultados`}
          </p>
        )}
      </div>

      <UsuariosTabla
        rows={rows}
        onSelect={setSelectedRow}
        onDesactivar={handleDesactivar}
        canEdit={puedeEscribir}
      />

      <AgregarUsuarioModal
        open={showAgregar}
        onClose={() => setShowAgregar(false)}
        onSuccess={handleSuccess}
        rolCreador={perfil?.rol ?? ""}
        ramoCreador={perfil?.ramo}
      />

      <UsuarioDrawer
        row={selectedRow}
        open={selectedRow !== null}
        onClose={() => setSelectedRow(null)}
        onUpdated={handleSuccess}
        puedeEditar={puedeEscribir}
      />
    </div>
  )
}