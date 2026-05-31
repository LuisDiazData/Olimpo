"use client"

import { useState } from "react"
import { X, AlertCircle } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Label } from "@/components/ui/label"
import { api } from "@/lib/api"

interface AnalistaItem {
  id: string
  nombre: string
  email: string
  ramo: string
  activo: boolean
}

interface Props {
  tramite: {
    id: string
    folio: string
    titulo: string
    ramo: string | null
    analista_nombre: string | null
  }
  analistas: AnalistaItem[]
  ramoUsuario: string | null
  onClose: () => void
  onReasignado: (nuevoNombre: string) => void
}

export function ReasignarTramiteModal({ tramite, analistas, ramoUsuario, onClose, onReasignado }: Props) {
  const filtered = analistas.filter((a) => {
    if (!a.activo) return false
    if (ramoUsuario && a.ramo !== ramoUsuario) return false
    return true
  })

  const [analistaId, setAnalistaId] = useState<string>("")
  const [motivo, setMotivo] = useState<string>("")
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState<string | null>(null)

  async function guardar() {
    if (!analistaId) return
    setSaving(true)
    setError(null)
    try {
      await api.post(`/tramites/${tramite.id}/asignar`, {
        analista_id: analistaId,
        motivo: motivo.trim() || null,
      })
      const nuevoNombre = filtered.find((a) => a.id === analistaId)?.nombre ?? ""
      onReasignado(nuevoNombre)
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
          <div>
            <h2 className="text-base font-semibold text-slate-900">Reasignar trámite</h2>
            <p className="mt-0.5 text-xs text-slate-500 font-mono">{tramite.folio}</p>
          </div>
          <button onClick={onClose} className="rounded-md p-1.5 text-slate-400 hover:bg-slate-100">
            <X className="h-5 w-5" />
          </button>
        </div>

        <div className="space-y-4 px-6 py-5">
          <div className="rounded-lg bg-slate-50 border px-4 py-3 space-y-1 text-sm">
            <p className="font-medium text-slate-900 truncate">{tramite.titulo}</p>
            {tramite.analista_nombre && (
              <p className="text-xs text-slate-500">
                Analista actual: <span className="font-medium text-slate-700">{tramite.analista_nombre}</span>
              </p>
            )}
          </div>

          <div className="space-y-1.5">
            <Label>Nuevo analista <span className="text-destructive">*</span></Label>
            {filtered.length === 0 ? (
              <p className="rounded-md border border-amber-200 bg-amber-50 px-3 py-2 text-sm text-amber-700">
                No hay analistas disponibles
              </p>
            ) : (
              <select
                value={analistaId}
                onChange={(e) => setAnalistaId(e.target.value)}
                className="w-full rounded-md border border-input bg-white px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-ring"
              >
                <option value="">Seleccionar analista...</option>
                {filtered.map((a) => (
                  <option key={a.id} value={a.id}>{a.nombre}</option>
                ))}
              </select>
            )}
          </div>

          <div className="space-y-1.5">
            <Label>Motivo</Label>
            <textarea
              value={motivo}
              onChange={(e) => setMotivo(e.target.value)}
              placeholder="Ej: Vacaciones del analista, exceso de carga de trabajo..."
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
            disabled={saving || !analistaId}
            className="flex-1"
          >
            {saving ? "Reasignando..." : "Reasignar"}
          </Button>
        </div>
      </div>
    </>
  )
}
