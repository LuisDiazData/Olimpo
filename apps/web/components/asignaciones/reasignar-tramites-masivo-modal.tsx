"use client"

import { useState } from "react"
import { AlertCircle, CheckCircle, Users } from "lucide-react"
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
  analistas: AnalistaItem[]
  onClose: () => void
  onSuccess: (result: ReasignacionMasivaResult) => void
}

interface ReasignacionMasivaResult {
  ok: boolean
  analista_origen_nombre: string
  analista_destino_nombre: string
  total_reasignados: number
  folios_reasignados: string[]
  mensaje?: string
}

export function ReasignarTramitesMasivoModal({ analistas, onClose, onSuccess }: Props) {
  const [origenId, setOrigenId] = useState<string>("")
  const [destinoId, setDestinoId] = useState<string>("")
  const [motivo, setMotivo] = useState<string>("")
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [done, setDone] = useState(false)
  const [result, setResult] = useState<ReasignacionMasivaResult | null>(null)

  const filtered = analistas.filter((a) => a.activo)

  const origenNombre = filtered.find((a) => a.id === origenId)?.nombre
  const destinoNombre = filtered.find((a) => a.id === destinoId)?.nombre

  async function handleSubmit() {
    if (!origenId || !destinoId) return
    setSaving(true)
    setError(null)
    try {
      const res = await api.post<ReasignacionMasivaResult>("/tramites/reasignar-masiva", {
        analista_origen_id: origenId,
        analista_destino_id: destinoId,
        motivo: motivo.trim() || null,
      })
      setResult(res)
      setDone(true)
    } catch (err: unknown) {
      setError((err as Error).message)
    } finally {
      setSaving(false)
    }
  }

  if (done && result) {
    return (
      <>
        <div className="fixed inset-0 z-40 bg-black/40 backdrop-blur-sm" onClick={onClose} />
        <div className="fixed left-1/2 top-1/2 z-50 w-full max-w-md -translate-x-1/2 -translate-y-1/2 rounded-xl bg-white shadow-xl">
          <div className="flex flex-col items-center gap-4 px-6 py-10 text-center">
            <div className="flex h-14 w-14 items-center justify-center rounded-full bg-emerald-50">
              <CheckCircle className="h-7 w-7 text-emerald-600" />
            </div>
            <div>
              <p className="text-base font-semibold text-slate-900">Reasignación completada</p>
              <p className="mt-1 text-sm text-slate-500">
                {result.total_reasignados} trámite{result.total_reasignados !== 1 ? "s" : ""} transferid{result.total_reasignados !== 1 ? "os" : "o"} de {result.analista_origen_nombre} a {result.analista_destino_nombre}
              </p>
            </div>
            <Button onClick={() => onSuccess(result)} className="w-full max-w-xs">
              Aceptar
            </Button>
          </div>
        </div>
      </>
    )
  }

  return (
    <>
      <div className="fixed inset-0 z-40 bg-black/40 backdrop-blur-sm" onClick={onClose} />
      <div className="fixed left-1/2 top-1/2 z-50 w-full max-w-md -translate-x-1/2 -translate-y-1/2 rounded-xl bg-white shadow-xl">
        <div className="flex items-center justify-between border-b px-6 py-4">
          <div className="flex items-center gap-2">
            <Users className="h-5 w-5 text-slate-500" />
            <h2 className="text-base font-semibold text-slate-900">Reasignar todos los trámites</h2>
          </div>
          <button onClick={onClose} className="rounded-md p-1.5 text-slate-400 hover:bg-slate-100">
            <svg className="h-5 w-5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
              <path strokeLinecap="round" strokeLinejoin="round" d="M6 18L18 6M6 6l12 12" />
            </svg>
          </button>
        </div>

        <div className="space-y-4 px-6 py-5">
          <p className="text-sm text-slate-500">
            Transfiere todos los trámites activos de un analista a otro. Útil cuando alguien se va de vacaciones o causa baja.
          </p>

          <div className="space-y-1.5">
            <Label>Analista origen (sus trámites se transferirán)</Label>
            <select
              value={origenId}
              onChange={(e) => { setOrigenId(e.target.value); setDestinoId("") }}
              className="w-full rounded-md border border-input bg-white px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-ring"
            >
              <option value="">Seleccionar analista...</option>
              {filtered.map((a) => (
                <option key={a.id} value={a.id}>{a.nombre} ({a.ramo})</option>
              ))}
            </select>
          </div>

          <div className="flex justify-center">
            <svg className="h-5 w-5 text-slate-300" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
              <path strokeLinecap="round" strokeLinejoin="round" d="M19 14l-7 7m0 0l-7-7m7 7V3" />
            </svg>
          </div>

          <div className="space-y-1.5">
            <Label>Analista destino (recibe los trámites)</Label>
            <select
              value={destinoId}
              onChange={(e) => setDestinoId(e.target.value)}
              disabled={!origenId}
              className="w-full rounded-md border border-input bg-white px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-ring disabled:opacity-50"
            >
              <option value="">Seleccionar analista...</option>
              {filtered
                .filter((a) => a.id !== origenId)
                .map((a) => (
                  <option key={a.id} value={a.id}>{a.nombre} ({a.ramo})</option>
                ))}
            </select>
          </div>

          <div className="space-y-1.5">
            <Label>Motivo</Label>
            <textarea
              value={motivo}
              onChange={(e) => setMotivo(e.target.value)}
              placeholder="Ej: Cobertura de vacaciones"
              rows={2}
              className="flex w-full rounded-md border border-input bg-white px-3 py-2 text-sm resize-none focus:outline-none focus:ring-2 focus:ring-ring"
            />
          </div>

          {origenNombre && destinoNombre && (
            <div className="rounded-lg bg-blue-50 border border-blue-100 px-4 py-3 text-sm text-blue-700">
              Se transferirán todos los trámites de <strong>{origenNombre}</strong> a <strong>{destinoNombre}</strong>
            </div>
          )}

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
            onClick={handleSubmit}
            disabled={saving || !origenId || !destinoId || origenId === destinoId}
            className="flex-1"
          >
            {saving ? "Reasignando..." : "Reasignar todos"}
          </Button>
        </div>
      </div>
    </>
  )
}
