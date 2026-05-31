"use client"

import { useState } from "react"
import { X, AlertCircle } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Label } from "@/components/ui/label"
import { api } from "@/lib/api"
import type { AsignacionRow } from "./types"
import { RAMO_LABELS } from "./types"

interface AnalistaItem {
  id: string
  nombre: string
  ramo: string
}

interface Props {
  row: AsignacionRow
  agentesMap: Record<string, { nombre: string; cua: string }>
  analistas: AnalistaItem[]
  onClose: () => void
  onSaved: () => void
}

export function EditarAsignacionModal({ row, agentesMap, analistas, onClose, onSaved }: Props) {
  const agente = agentesMap[row.agente_id]
  const analistasRamo = analistas.filter((a) => a.ramo === row.ramo)

  const [analistaId, setAnalistaId] = useState(row.analista_id)
  const [notas, setNotas] = useState(row.notas ?? "")
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState<string | null>(null)

  async function guardar() {
    setSaving(true)
    setError(null)
    try {
      await api.patch(`/asignaciones/${row.id}`, {
        analista_id: analistaId,
        notas: notas.trim() || null,
      })
      onSaved()
      onClose()
    } catch (err: unknown) {
      setError((err as Error).message)
    } finally {
      setSaving(false)
    }
  }

  return (
    <>
      <div className="fixed inset-0 z-40 bg-black/40 backdrop-blur-sm" onClick={onClose} />
      <div className="fixed left-1/2 top-1/2 z-50 w-full max-w-md -translate-x-1/2 -translate-y-1/2 rounded-xl bg-white shadow-xl">

        <div className="flex items-center justify-between border-b px-6 py-4">
          <h2 className="text-base font-semibold text-slate-900">Editar asignación</h2>
          <button onClick={onClose} className="rounded-md p-1.5 text-slate-400 hover:bg-slate-100">
            <X className="h-5 w-5" />
          </button>
        </div>

        <div className="space-y-4 px-6 py-5">
          {/* Info */}
          <div className="rounded-lg bg-slate-50 border px-4 py-3 space-y-1 text-sm">
            <div className="flex items-center gap-2">
              <span className="text-xs font-semibold text-slate-500 uppercase tracking-wide">Agente</span>
              <span className="font-medium text-slate-900">{agente?.nombre ?? row.agente_id}</span>
              {agente && <span className="font-mono text-xs text-slate-400">{agente.cua}</span>}
            </div>
            <div className="flex items-center gap-2">
              <span className="text-xs font-semibold text-slate-500 uppercase tracking-wide">Ramo</span>
              <span className="font-medium text-slate-900">{RAMO_LABELS[row.ramo] ?? row.ramo}</span>
            </div>
          </div>

          {/* Analista */}
          <div className="space-y-1.5">
            <Label>Analista <span className="text-destructive">*</span></Label>
            {analistasRamo.length === 0 ? (
              <p className="rounded-md border border-amber-200 bg-amber-50 px-3 py-2 text-sm text-amber-700">
                No hay analistas activos para el ramo {RAMO_LABELS[row.ramo]}.
              </p>
            ) : (
              <select
                value={analistaId}
                onChange={(e) => setAnalistaId(e.target.value)}
                className="w-full rounded-md border border-input bg-white px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-ring"
              >
                {analistasRamo.map((a) => (
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
              onChange={(e) => setNotas(e.target.value)}
              rows={2}
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
          <Button variant="outline" onClick={onClose} disabled={saving} className="flex-1">
            Cancelar
          </Button>
          <Button
            onClick={guardar}
            disabled={saving || !analistaId || analistasRamo.length === 0}
            className="flex-1"
          >
            {saving ? "Guardando..." : "Guardar cambios"}
          </Button>
        </div>
      </div>
    </>
  )
}
