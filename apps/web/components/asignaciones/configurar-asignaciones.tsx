"use client"

import { useState, useMemo } from "react"
import { Search, AlertCircle, CheckCircle2, UserCheck, X } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { api } from "@/lib/api"
import type { AsignacionRow } from "./types"
import { RAMO_LABELS, RAMOS } from "./types"

interface AgenteItem {
  id: string
  nombre: string
  cua: string
  activo: boolean
}

interface AnalistaItem {
  id: string
  nombre: string
  ramo: string
}

interface Props {
  agentes: AgenteItem[]
  analistas: AnalistaItem[]
  asignaciones: AsignacionRow[]       // reglas activas — todas (cargadas por la página)
  onAsignado: () => void
  puedeEditar: boolean
}

// ── Component ────────────────────────────────────────────────────────────────

export function ConfigurarAsignaciones({
  agentes,
  analistas,
  asignaciones,
  onAsignado,
  puedeEditar,
}: Props) {
  const [ramo, setRamo] = useState<string>("vida")
  const [search, setSearch] = useState("")
  const [selected, setSelected] = useState<Set<string>>(new Set())

  // modal confirmar
  const [showModal, setShowModal] = useState(false)
  const [analistaId, setAnalistaId] = useState("")
  const [notas, setNotas] = useState("")
  const [saving, setSaving] = useState(false)
  const [saveError, setSaveError] = useState<string | null>(null)

  // ── Datos derivados ──────────────────────────────────────────────────────

  // Mapa agente_id → asignación activa para el ramo seleccionado
  const asignPorAgente = useMemo(
    () =>
      Object.fromEntries(
        asignaciones
          .filter((a) => a.ramo === ramo && a.activo)
          .map((a) => [a.agente_id, a])
      ),
    [asignaciones, ramo]
  )

  // Analistas del ramo seleccionado
  const analistasRamo = useMemo(
    () => analistas.filter((a) => a.ramo === ramo),
    [analistas, ramo]
  )

  // Agentes filtrados por búsqueda
  const agentesFiltrados = useMemo(() => {
    const q = search.trim().toLowerCase()
    return agentes.filter(
      (a) =>
        a.activo &&
        (!q || a.nombre.toLowerCase().includes(q) || a.cua.toLowerCase().includes(q))
    )
  }, [agentes, search])

  // Cuántos seleccionados ya tienen asignación (reasignación)
  const reasignaciones = useMemo(
    () => Array.from(selected).filter((id) => !!asignPorAgente[id]),
    [selected, asignPorAgente]
  )

  // ── Selección ────────────────────────────────────────────────────────────

  function toggleAgente(id: string) {
    setSelected((prev) => {
      const next = new Set(prev)
      if (next.has(id)) next.delete(id)
      else next.add(id)
      return next
    })
  }

  function toggleTodos() {
    const ids = new Set(agentesFiltrados.map((a) => a.id))
    const todosMarcados = agentesFiltrados.every((a) => selected.has(a.id))
    if (todosMarcados) {
      setSelected((prev) => {
        const next = new Set(prev)
        ids.forEach((id) => next.delete(id))
        return next
      })
    } else {
      setSelected((prev) => {
        const next = new Set(prev)
        ids.forEach((id) => next.add(id))
        return next
      })
    }
  }

  // ── Asignar ──────────────────────────────────────────────────────────────

  function openModal() {
    setAnalistaId("")
    setNotas("")
    setSaveError(null)
    setShowModal(true)
  }

  async function confirmarAsignacion() {
    if (!analistaId) { setSaveError("Selecciona un analista."); return }
    setSaving(true)
    setSaveError(null)

    const selectedArr = Array.from(selected)

    // Separar nuevos vs reasignaciones
    const toCreate: string[] = []
    const toUpdate: { id: string }[] = []

    for (const agenteId of selectedArr) {
      const existing = asignPorAgente[agenteId]
      if (existing) {
        toUpdate.push({ id: existing.id })
      } else {
        toCreate.push(agenteId)
      }
    }

    try {
      const requests: Promise<unknown>[] = []

      if (toCreate.length > 0) {
        requests.push(
          api.post("/asignaciones/bulk", {
            agente_ids: toCreate,
            ramo,
            analista_id: analistaId,
            notas: notas.trim() || undefined,
          })
        )
      }

      for (const { id } of toUpdate) {
        requests.push(
          api.patch(`/asignaciones/${id}`, {
            analista_id: analistaId,
            notas: notas.trim() || undefined,
          })
        )
      }

      await Promise.all(requests)

      setShowModal(false)
      setSelected(new Set())
      onAsignado()
    } catch (err: unknown) {
      setSaveError((err as Error).message)
    } finally {
      setSaving(false)
    }
  }

  // ── Render ───────────────────────────────────────────────────────────────

  const todosMarcados =
    agentesFiltrados.length > 0 && agentesFiltrados.every((a) => selected.has(a.id))

  return (
    <div className="space-y-4">

      {/* ── Tabs de ramo ── */}
      <div className="flex gap-1 rounded-xl border bg-slate-100 p-1 w-fit">
        {RAMOS.map((r) => {
          const _sinAnalista = agentes.filter(
            (a) => a.activo && !asignPorAgente[a.id]
          ).length
          return (
            <button
              key={r}
              onClick={() => { setRamo(r); setSelected(new Set()) }}
              className={`relative rounded-lg px-4 py-2 text-sm font-medium transition-colors ${
                ramo === r
                  ? "bg-white text-slate-900 shadow-sm"
                  : "text-slate-500 hover:text-slate-700"
              }`}
            >
              {RAMO_LABELS[r]}
              {ramo === r &&
                asignaciones.filter(
                  (a) => a.ramo === r && !a.activo
                ).length === 0 && (
                  <RamoStats ramo={r} asignaciones={asignaciones} total={agentes.filter((a) => a.activo).length} />
                )}
            </button>
          )
        })}
      </div>

      {/* ── Resumen del ramo ── */}
      <RamoResumen ramo={ramo} agentes={agentes} asignaciones={asignaciones} analistas={analistasRamo} />

      {/* ── Toolbar de búsqueda + acción ── */}
      <div className="flex items-center gap-3">
        <div className="relative flex-1 max-w-xs">
          <Search className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-slate-400" />
          <Input
            placeholder="Buscar por nombre o CUA..."
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            className="pl-9"
          />
        </div>

        {selected.size > 0 && puedeEditar && (
          <div className="flex items-center gap-2">
            <span className="rounded-full bg-blue-100 px-3 py-1 text-sm font-medium text-blue-700">
              {selected.size} seleccionado{selected.size !== 1 ? "s" : ""}
            </span>
            <Button size="sm" onClick={openModal} className="gap-1.5">
              <UserCheck className="h-4 w-4" />
              Asignar
            </Button>
            <button
              onClick={() => setSelected(new Set())}
              className="rounded p-1 text-slate-400 hover:text-slate-600"
              title="Limpiar selección"
            >
              <X className="h-4 w-4" />
            </button>
          </div>
        )}
      </div>

      {/* ── Lista de agentes ── */}
      <div className="rounded-xl border bg-white shadow-sm overflow-hidden">

        {/* Header de la lista */}
        <div className="flex items-center gap-3 border-b bg-slate-50 px-4 py-2.5">
          {puedeEditar && (
            <input
              type="checkbox"
              checked={todosMarcados}
              onChange={toggleTodos}
              className="h-4 w-4 rounded border-slate-300 accent-slate-900"
            />
          )}
          <span className="text-xs font-semibold uppercase tracking-wide text-slate-500 flex-1">
            Agente
          </span>
          <span className="text-xs font-semibold uppercase tracking-wide text-slate-500 w-48 hidden sm:block">
            Analista asignado · {RAMO_LABELS[ramo]}
          </span>
        </div>

        {/* Filas */}
        {agentesFiltrados.length === 0 ? (
          <div className="py-12 text-center text-sm text-slate-400">
            Sin agentes registrados.
          </div>
        ) : (
          <ul className="divide-y divide-slate-100">
            {agentesFiltrados.map((agente) => {
              const asig = asignPorAgente[agente.id]
              const analistaNombre = asig
                ? (analistas.find((a) => a.id === asig.analista_id)?.nombre ?? asig.analista_id)
                : null

              return (
                <li
                  key={agente.id}
                  className={`flex items-center gap-3 px-4 py-3 transition-colors ${
                    selected.has(agente.id) ? "bg-blue-50" : "hover:bg-slate-50"
                  }`}
                >
                  {puedeEditar && (
                    <input
                      type="checkbox"
                      checked={selected.has(agente.id)}
                      onChange={() => toggleAgente(agente.id)}
                      className="h-4 w-4 rounded border-slate-300 accent-slate-900 shrink-0"
                    />
                  )}

                  <div className="flex-1 min-w-0">
                    <p className="text-sm font-medium text-slate-900 truncate">{agente.nombre}</p>
                    <p className="text-xs font-mono text-slate-500">{agente.cua}</p>
                  </div>

                  <div className="shrink-0 hidden sm:flex items-center gap-2 w-48">
                    {analistaNombre ? (
                      <span className="inline-flex items-center gap-1.5 rounded-full bg-emerald-100 px-2.5 py-0.5 text-xs font-medium text-emerald-700 truncate max-w-full">
                        <CheckCircle2 className="h-3 w-3 shrink-0" />
                        {analistaNombre}
                      </span>
                    ) : (
                      <span className="inline-flex items-center gap-1.5 rounded-full bg-amber-100 px-2.5 py-0.5 text-xs font-medium text-amber-700">
                        <AlertCircle className="h-3 w-3 shrink-0" />
                        Sin analista
                      </span>
                    )}
                  </div>
                </li>
              )
            })}
          </ul>
        )}
      </div>

      {/* ── Modal de confirmación ── */}
      {showModal && (
        <ConfirmarModal
          selected={selected}
          ramo={ramo}
          reasignaciones={reasignaciones}
          analistas={analistasRamo}
          analistas_todos={analistas}
          asignPorAgente={asignPorAgente}
          agentes={agentes}
          analistaId={analistaId}
          notas={notas}
          saving={saving}
          error={saveError}
          onAnalistaChange={setAnalistaId}
          onNotasChange={setNotas}
          onCancel={() => setShowModal(false)}
          onConfirm={confirmarAsignacion}
        />
      )}
    </div>
  )
}

// ── Sub-components ────────────────────────────────────────────────────────────

function RamoStats({
  ramo,
  asignaciones,
  total,
}: {
  ramo: string
  asignaciones: AsignacionRow[]
  total: number
}) {
  const asignados = new Set(
    asignaciones.filter((a) => a.ramo === ramo && a.activo).map((a) => a.agente_id)
  ).size
  const sinAnalista = total - asignados
  if (sinAnalista === 0) return null
  return (
    <span className="ml-1.5 rounded-full bg-amber-100 px-1.5 py-0.5 text-xs font-semibold text-amber-700">
      {sinAnalista}
    </span>
  )
}

function RamoResumen({
  ramo,
  agentes,
  asignaciones,
  analistas,
}: {
  ramo: string
  agentes: { id: string; activo: boolean }[]
  asignaciones: AsignacionRow[]
  analistas: { id: string; nombre: string }[]
}) {
  const activosRamo = asignaciones.filter((a) => a.ramo === ramo && a.activo)
  const asignadosIds = new Set(activosRamo.map((a) => a.agente_id))
  const totalAgentes = agentes.filter((a) => a.activo).length
  const sinAnalista = totalAgentes - asignadosIds.size

  // Por analista
  const porAnalista: Record<string, number> = {}
  for (const a of activosRamo) {
    porAnalista[a.analista_id] = (porAnalista[a.analista_id] ?? 0) + 1
  }

  return (
    <div className="flex flex-wrap gap-3">
      {/* Total */}
      <div className="rounded-lg border bg-white px-3 py-2 text-center min-w-[80px]">
        <p className="text-lg font-bold text-slate-900">{totalAgentes}</p>
        <p className="text-xs text-slate-500">Total agentes</p>
      </div>

      {/* Sin analista */}
      {sinAnalista > 0 && (
        <div className="rounded-lg border border-amber-200 bg-amber-50 px-3 py-2 text-center min-w-[80px]">
          <p className="text-lg font-bold text-amber-700">{sinAnalista}</p>
          <p className="text-xs text-amber-600">Sin analista</p>
        </div>
      )}

      {/* Por analista */}
      {Object.entries(porAnalista).map(([analistaId, count]) => {
        const nombre = analistas.find((a) => a.id === analistaId)?.nombre ?? "Analista"
        return (
          <div key={analistaId} className="rounded-lg border bg-white px-3 py-2 text-center min-w-[80px]">
            <p className="text-lg font-bold text-slate-900">{count}</p>
            <p className="text-xs text-slate-500 truncate max-w-[100px]">{nombre}</p>
          </div>
        )
      })}
    </div>
  )
}

function ConfirmarModal({
  selected,
  ramo,
  reasignaciones,
  analistas,
  analistas_todos,
  asignPorAgente,
  agentes,
  analistaId,
  notas,
  saving,
  error,
  onAnalistaChange,
  onNotasChange,
  onCancel,
  onConfirm,
}: {
  selected: Set<string>
  ramo: string
  reasignaciones: string[]
  analistas: { id: string; nombre: string }[]
  analistas_todos: { id: string; nombre: string; ramo: string }[]
  asignPorAgente: Record<string, AsignacionRow>
  agentes: { id: string; nombre: string; cua: string }[]
  analistaId: string
  notas: string
  saving: boolean
  error: string | null
  onAnalistaChange: (v: string) => void
  onNotasChange: (v: string) => void
  onCancel: () => void
  onConfirm: () => void
}) {
  const nuevos = selected.size - reasignaciones.length

  return (
    <>
      <div className="fixed inset-0 z-40 bg-black/40 backdrop-blur-sm" onClick={onCancel} />
      <div className="fixed left-1/2 top-1/2 z-50 w-full max-w-md -translate-x-1/2 -translate-y-1/2 rounded-xl bg-white shadow-xl">

        <div className="flex items-center justify-between border-b px-6 py-4">
          <h2 className="text-base font-semibold text-slate-900">
            Confirmar asignación · {RAMO_LABELS[ramo]}
          </h2>
          <button
            onClick={onCancel}
            className="rounded-md p-1.5 text-slate-400 hover:bg-slate-100"
          >
            <X className="h-5 w-5" />
          </button>
        </div>

        <div className="space-y-4 px-6 py-5">

          {/* Resumen */}
          <div className="flex gap-3">
            {nuevos > 0 && (
              <div className="flex-1 rounded-lg border bg-emerald-50 px-3 py-2 text-center">
                <p className="text-xl font-bold text-emerald-700">{nuevos}</p>
                <p className="text-xs text-emerald-600">Asignación nueva</p>
              </div>
            )}
            {reasignaciones.length > 0 && (
              <div className="flex-1 rounded-lg border bg-amber-50 px-3 py-2 text-center">
                <p className="text-xl font-bold text-amber-700">{reasignaciones.length}</p>
                <p className="text-xs text-amber-600">Reasignación</p>
              </div>
            )}
          </div>

          {/* Warning reasignaciones */}
          {reasignaciones.length > 0 && (
            <div className="rounded-lg border border-amber-200 bg-amber-50 px-4 py-3 space-y-1.5">
              <p className="text-xs font-semibold text-amber-800 flex items-center gap-1.5">
                <AlertCircle className="h-3.5 w-3.5" />
                Los siguientes agentes ya tienen analista — serán reasignados:
              </p>
              {reasignaciones.map((agenteId) => {
                const asig = asignPorAgente[agenteId]
                const agente = agentes.find((a) => a.id === agenteId)
                const analistaActual = analistas_todos.find((a) => a.id === asig?.analista_id)
                return (
                  <p key={agenteId} className="text-xs text-amber-700 pl-5">
                    <span className="font-medium">{agente?.nombre}</span>
                    {analistaActual && (
                      <span className="text-amber-600"> · actualmente: {analistaActual.nombre}</span>
                    )}
                  </p>
                )
              })}
            </div>
          )}

          {/* Analista */}
          <div className="space-y-1.5">
            <Label>
              Analista <span className="text-destructive">*</span>
            </Label>
            {analistas.length === 0 ? (
              <p className="rounded-md border border-amber-200 bg-amber-50 px-3 py-2 text-sm text-amber-700">
                No hay analistas activos para el ramo {RAMO_LABELS[ramo]}.
              </p>
            ) : (
              <select
                value={analistaId}
                onChange={(e) => onAnalistaChange(e.target.value)}
                className="w-full rounded-md border border-input bg-white px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-ring"
              >
                <option value="">Seleccionar analista...</option>
                {analistas.map((a) => (
                  <option key={a.id} value={a.id}>{a.nombre}</option>
                ))}
              </select>
            )}
          </div>

          {/* Notas */}
          <div className="space-y-1.5">
            <Label>Notas</Label>
            <textarea
              value={notas}
              onChange={(e) => onNotasChange(e.target.value)}
              rows={2}
              placeholder="Notas opcionales sobre esta asignación..."
              className="flex w-full rounded-md border border-input bg-white px-3 py-2 text-sm resize-none focus:outline-none focus:ring-2 focus:ring-ring"
            />
          </div>

          {error && (
            <div className="flex items-center gap-2 rounded-md bg-red-50 border border-red-200 px-3 py-2 text-sm text-red-700">
              <AlertCircle className="h-4 w-4 shrink-0" />
              {error}
            </div>
          )}
        </div>

        <div className="flex gap-3 border-t px-6 py-4">
          <Button variant="outline" onClick={onCancel} className="flex-1" disabled={saving}>
            Cancelar
          </Button>
          <Button
            onClick={onConfirm}
            disabled={saving || !analistaId || analistas.length === 0}
            className="flex-1"
          >
            {saving
              ? "Guardando..."
              : `Confirmar · ${selected.size} agente${selected.size !== 1 ? "s" : ""}`}
          </Button>
        </div>
      </div>
    </>
  )
}
