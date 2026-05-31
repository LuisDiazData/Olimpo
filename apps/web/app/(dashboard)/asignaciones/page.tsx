"use client"

import { useState, useCallback, useMemo } from "react"
import { useQuery, useQueryClient } from "@tanstack/react-query"
import { api } from "@/lib/api"
import { useUser } from "@/components/providers/user-provider"
import { ConfigurarAsignaciones } from "@/components/asignaciones/configurar-asignaciones"
import { AsignacionesTabla } from "@/components/asignaciones/asignaciones-tabla"
import { EditarAsignacionModal } from "@/components/asignaciones/editar-asignacion-modal"
import { ReasignarTramitesMasivoModal } from "@/components/asignaciones/reasignar-tramites-masivo-modal"
import type { AsignacionRow } from "@/components/asignaciones/types"
import { RAMO_LABELS } from "@/components/asignaciones/types"
import { Button } from "@/components/ui/button"

const ROLES_ESCRITURA = ["director_general", "director_ops", "gerente"]

type Vista = "configurar" | "reglas"

interface AgenteItem { id: string; nombre: string; cua: string; activo: boolean }
interface AnalistaItem { id: string; nombre: string; email: string; ramo: string; activo: boolean }

// ── Page ──────────────────────────────────────────────────────────────────────

export default function AsignacionesPage() {
  const { perfil } = useUser()
  const qc = useQueryClient()
  const puedeEditar = perfil ? ROLES_ESCRITURA.includes(perfil.rol) : false

  const [vista, setVista] = useState<Vista>("configurar")
  const [filtroRamo, setFiltroRamo] = useState<string>("")
  const [editRow, setEditRow] = useState<AsignacionRow | null>(null)
  const [showReasignarMasivo, setShowReasignarMasivo] = useState(false)

  // ── Datos ────────────────────────────────────────────────────────────────

  const { data: agentesRaw = [] } = useQuery({
    queryKey: ["agentes", "activos"],
    queryFn: () => api.get<AgenteItem[]>("/agentes?limit=200&activo=true"),
    staleTime: 60_000,
  })

  const { data: usuariosRaw = [] } = useQuery({
    queryKey: ["usuarios", "analistas"],
    queryFn: () => api.get<AnalistaItem[]>("/usuarios?rol=analista&activo=true&limit=200"),
    staleTime: 60_000,
  })

  const { data: asignaciones = [], isLoading: cargandoAsig } = useQuery({
    queryKey: ["asignaciones", "todas"],
    queryFn: () => api.get<AsignacionRow[]>("/asignaciones?activo=true&limit=500"),
    staleTime: 30_000,
  })

  const invalidar = useCallback(() => {
    qc.invalidateQueries({ queryKey: ["asignaciones"] })
  }, [qc])

  // ── Mapas para resolución de nombres ─────────────────────────────────────

  const agentesMap = useMemo(
    () => Object.fromEntries(agentesRaw.map((a) => [a.id, { nombre: a.nombre, cua: a.cua }])),
    [agentesRaw]
  )

  const analistasMap = useMemo(
    () => Object.fromEntries(usuariosRaw.map((u) => [u.id, { nombre: u.nombre }])),
    [usuariosRaw]
  )

  // ── Filtrado para la vista de reglas ──────────────────────────────────────

  const asigFiltradas = useMemo(
    () =>
      filtroRamo
        ? asignaciones.filter((a) => a.ramo === filtroRamo)
        : asignaciones,
    [asignaciones, filtroRamo]
  )

  async function handleDesactivar(row: AsignacionRow) {
    if (!confirm(`¿Desactivar la asignación de ${agentesMap[row.agente_id]?.nombre ?? "este agente"}?`)) return
    await api.delete(`/asignaciones/${row.id}`)
    invalidar()
  }

  // ── Stats globales ────────────────────────────────────────────────────────

  const agentesActivos = agentesRaw.length
  const agentesAsignados = new Set(asignaciones.map((a) => a.agente_id)).size
  const reglasTotales = asignaciones.length

  return (
    <div className="space-y-6">

      {/* ── Encabezado ── */}
      <div>
        <h2 className="text-xl font-bold text-slate-900">Asignaciones</h2>
        <p className="mt-0.5 text-sm text-muted-foreground">
          Vincula agentes con analistas por ramo · el Agente IA usa estas reglas para asignar trámites
        </p>
      </div>

      {/* ── Métricas ── */}
      <div className="grid grid-cols-3 gap-3">
        <Stat label="Agentes activos" value={agentesActivos} />
        <Stat
          label="Con analista asignado"
          value={agentesAsignados}
          sub={agentesActivos > 0 ? `${Math.round((agentesAsignados / agentesActivos) * 100)}%` : undefined}
          color="text-emerald-700"
          bg="bg-emerald-50"
        />
        <Stat label="Reglas activas" value={reglasTotales} color="text-blue-700" bg="bg-blue-50" />
      </div>

      {/* ── Reasignación masiva ── */}
      {puedeEditar && (
        <div className="flex justify-end">
          <Button
            variant="outline"
            size="sm"
            onClick={() => setShowReasignarMasivo(true)}
          >
            Reasignar trámites de un analista
          </Button>
        </div>
      )}

      {/* ── Tabs de vista ── */}
      <div className="flex items-center gap-4 border-b">
        {(["configurar", "reglas"] as Vista[]).map((v) => (
          <button
            key={v}
            onClick={() => setVista(v)}
            className={`relative pb-3 text-sm font-medium transition-colors ${
              vista === v
                ? "text-blue-600 after:absolute after:bottom-0 after:left-0 after:right-0 after:h-0.5 after:bg-blue-600"
                : "text-slate-500 hover:text-slate-700"
            }`}
          >
            {v === "configurar" ? "Configurar asignaciones" : "Todas las reglas"}
          </button>
        ))}
      </div>

      {/* ── Configurar ── */}
      {vista === "configurar" && (
        <ConfigurarAsignaciones
          agentes={agentesRaw}
          analistas={usuariosRaw}
          asignaciones={asignaciones}
          onAsignado={invalidar}
          puedeEditar={puedeEditar}
        />
      )}

      {/* ── Reglas activas ── */}
      {vista === "reglas" && (
        <div className="space-y-4">
          {/* Filtro ramo */}
          <div className="flex items-center gap-3">
            <div className="flex rounded-lg border bg-slate-100 p-1">
              <button
                onClick={() => setFiltroRamo("")}
                className={`rounded-md px-3 py-1.5 text-xs font-medium transition-colors ${
                  !filtroRamo ? "bg-white text-slate-900 shadow-sm" : "text-slate-500 hover:text-slate-700"
                }`}
              >
                Todos
              </button>
              {Object.entries(RAMO_LABELS).map(([val, label]) => (
                <button
                  key={val}
                  onClick={() => setFiltroRamo(val)}
                  className={`rounded-md px-3 py-1.5 text-xs font-medium transition-colors ${
                    filtroRamo === val
                      ? "bg-white text-slate-900 shadow-sm"
                      : "text-slate-500 hover:text-slate-700"
                  }`}
                >
                  {label}
                </button>
              ))}
            </div>
            <p className="text-xs text-slate-500">
              {asigFiltradas.length} regla{asigFiltradas.length !== 1 ? "s" : ""}
            </p>
          </div>

          {cargandoAsig ? (
            <div className="flex items-center justify-center py-20 text-sm text-slate-400">
              Cargando...
            </div>
          ) : (
            <AsignacionesTabla
              rows={asigFiltradas}
              agentesMap={agentesMap}
              analistasMap={analistasMap}
              onEdit={puedeEditar ? setEditRow : undefined}
              onDelete={puedeEditar ? handleDesactivar : undefined}
              puedeEditar={puedeEditar}
            />
          )}
        </div>
      )}

      {/* ── Modal editar ── */}
      {editRow && (
        <EditarAsignacionModal
          row={editRow}
          agentesMap={agentesMap}
          analistas={usuariosRaw}
          onClose={() => setEditRow(null)}
          onSaved={invalidar}
        />
      )}

      {/* ── Modal reasignación masiva ── */}
      {showReasignarMasivo && (
        <ReasignarTramitesMasivoModal
          analistas={usuariosRaw}
          onClose={() => setShowReasignarMasivo(false)}
          onSuccess={() => {
            setShowReasignarMasivo(false)
            invalidar()
          }}
        />
      )}
    </div>
  )
}

// ── Stat card ─────────────────────────────────────────────────────────────────

function Stat({
  label,
  value,
  sub,
  color = "text-slate-900",
  bg = "bg-white",
}: {
  label: string
  value: number
  sub?: string
  color?: string
  bg?: string
}) {
  return (
    <div className={`rounded-xl border px-4 py-3 ${bg}`}>
      <div className="flex items-baseline gap-2">
        <p className={`text-2xl font-bold ${color}`}>{value}</p>
        {sub && <p className={`text-sm font-medium ${color} opacity-70`}>{sub}</p>}
      </div>
      <p className="mt-0.5 text-xs text-slate-500">{label}</p>
    </div>
  )
}
