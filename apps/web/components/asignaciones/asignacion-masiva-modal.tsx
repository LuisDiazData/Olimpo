"use client"

import { useState } from "react"
import { Button } from "@/components/ui/button"
import { Label } from "@/components/ui/label"
import { RAMO_LABELS } from "./types"
import { useAsignaciones } from "@/hooks/use-asignaciones"
import type { BulkAsignacionResult } from "./types"

interface AgenteItem {
  id: string
  nombre: string
  cua: string
}

interface AnalistaItem {
  id: string
  nombre: string
  email: string
  ramo: string
}

interface Props {
  agentes: AgenteItem[]
  analistas: AnalistaItem[]
  onClose: () => void
  onSuccess: () => void
}

type Step = "select" | "configure" | "done"

export function AsignacionMasivaModal({ agentes, analistas, onClose, onSuccess }: Props) {
  const [step, setStep] = useState<Step>("select")
  const [selected, setSelected] = useState<Set<string>>(new Set())
  const [search, setSearch] = useState("")
  const [ramo, setRamo] = useState<string>("vida")
  const [analistaId, setAnalistaId] = useState<string>("")
  const [notas, setNotas] = useState<string>("")
  const [isSubmitting, setIsSubmitting] = useState(false)
  const [submitError, setSubmitError] = useState<string | null>(null)
  const [submitResult, setSubmitResult] = useState<BulkAsignacionResult | null>(null)

  const { masiva } = useAsignaciones()

  const filtered = agentes.filter((a) =>
    !search ||
    a.nombre.toLowerCase().includes(search.toLowerCase()) ||
    a.cua.toLowerCase().includes(search.toLowerCase())
  )

  const analystsByRamo = analistas.filter((a) => a.ramo === ramo)

  function toggleAgente(id: string) {
    setSelected((prev) => {
      const next = new Set(prev)
      if (next.has(id)) next.delete(id)
      else next.add(id)
      return next
    })
  }

  function toggleAll() {
    if (selected.size === filtered.length) setSelected(new Set())
    else setSelected(new Set(filtered.map((a) => a.id)))
  }

  async function handleSubmit() {
    if (!analistaId) { setSubmitError("Selecciona un analista."); return }
    if (selected.size === 0) { setSubmitError("Selecciona al menos un agente."); return }
    setIsSubmitting(true)
    setSubmitError(null)
    try {
      const result = await masiva({
        agente_ids: Array.from(selected),
        ramo,
        analista_id: analistaId,
        notas: notas || undefined,
      })
      setSubmitResult(result)
      setStep("done")
    } catch (err: unknown) {
      setSubmitError((err as Error).message)
    } finally {
      setIsSubmitting(false)
    }
  }

  return (
    <>
      <div className="fixed inset-0 z-40 bg-black/40 backdrop-blur-sm" onClick={onClose} />

      {step === "select" && (
        <div className="fixed left-1/2 top-1/2 z-50 w-full max-w-lg -translate-x-1/2 -translate-y-1/2 rounded-xl bg-white shadow-xl">
          <div className="flex items-center justify-between border-b px-6 py-4">
            <h2 className="text-base font-semibold text-slate-900">
              Seleccionar agentes
              <span className="ml-2 rounded bg-blue-100 px-2 py-0.5 text-xs text-blue-700 font-medium">
                {selected.size} seleccionados
              </span>
            </h2>
            <button onClick={onClose} className="rounded-md p-1.5 text-slate-400 hover:bg-slate-100">
              <svg className="h-5 w-5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                <path strokeLinecap="round" strokeLinejoin="round" d="M6 18L18 6M6 6l12 12" />
              </svg>
            </button>
          </div>
          <div className="space-y-3 px-6 py-4 max-h-[60vh] overflow-y-auto">
            <input
              type="text"
              placeholder="Buscar por nombre o CUA..."
              value={search}
              onChange={(e) => setSearch(e.target.value)}
              className="flex w-full rounded-md border border-input bg-white px-3 py-2 text-sm"
              autoFocus
            />
            <div className="flex items-center gap-2 rounded-lg border bg-slate-50 px-3 py-2">
              <input
                type="checkbox"
                checked={selected.size === filtered.length && filtered.length > 0}
                onChange={toggleAll}
                className="h-4 w-4 rounded border-slate-300 text-slate-900"
              />
              <span className="text-sm text-slate-700 font-medium">Todos ({filtered.length})</span>
            </div>
            <div className="space-y-1">
              {filtered.map((a) => (
                <label key={a.id} className="flex cursor-pointer items-center gap-3 rounded-lg border px-3 py-2.5 hover:bg-slate-50">
                  <input
                    type="checkbox"
                    checked={selected.has(a.id)}
                    onChange={() => toggleAgente(a.id)}
                    className="h-4 w-4 rounded border-slate-300 text-slate-900"
                  />
                  <div className="min-w-0 flex-1">
                    <p className="text-sm font-medium text-slate-900 truncate">{a.nombre}</p>
                    <p className="text-xs font-mono text-slate-500">{a.cua}</p>
                  </div>
                </label>
              ))}
              {filtered.length === 0 && (
                <p className="py-8 text-center text-sm text-slate-400">No se encontraron agentes.</p>
              )}
            </div>
          </div>
          <div className="flex gap-3 border-t px-6 py-4">
            <Button variant="outline" onClick={onClose} className="flex-1">Cancelar</Button>
            <Button
              onClick={() => setStep("configure")}
              disabled={selected.size === 0}
              className="flex-1"
            >
              Continuar ({selected.size})
            </Button>
          </div>
        </div>
      )}

      {step === "configure" && (
        <div className="fixed left-1/2 top-1/2 z-50 w-full max-w-md -translate-x-1/2 -translate-y-1/2 rounded-xl bg-white shadow-xl">
          <div className="flex items-center justify-between border-b px-6 py-4">
            <h2 className="text-base font-semibold text-slate-900">
              Configurar asignación · {selected.size} agente(s)
            </h2>
            <button onClick={() => setStep("select")} className="rounded-md p-1.5 text-slate-400 hover:bg-slate-100">
              <svg className="h-5 w-5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                <path strokeLinecap="round" strokeLinejoin="round" d="M15.232 5.232l3.536 3.536M9 11l-5 5m5-5a7.954 7.954 0 014.078 2.022A8.001 8.001 0 0120 12c1.1 0 2.15-.45 3.002-1.2" />
              </svg>
            </button>
          </div>
          <div className="space-y-4 px-6 py-5">
            <div className="grid grid-cols-2 gap-4">
              <div className="space-y-1.5">
                <Label>Ramo *</Label>
                <select
                  value={ramo}
                  onChange={(e) => { setRamo(e.target.value); setAnalistaId("") }}
                  className="w-full rounded-md border border-input bg-white px-3 py-2 text-sm"
                >
                  {Object.entries(RAMO_LABELS).map(([val, label]) => (
                    <option key={val} value={val}>{label}</option>
                  ))}
                </select>
              </div>
              <div className="space-y-1.5">
                <Label>Analista *</Label>
                <select
                  value={analistaId}
                  onChange={(e) => setAnalistaId(e.target.value)}
                  className="w-full rounded-md border border-input bg-white px-3 py-2 text-sm"
                >
                  <option value="">Seleccionar...</option>
                  {analystsByRamo.map((a) => (
                    <option key={a.id} value={a.id}>{a.nombre}</option>
                  ))}
                </select>
              </div>
            </div>
            <div className="space-y-1.5">
              <Label>Notas</Label>
              <textarea
                value={notas}
                onChange={(e) => setNotas(e.target.value)}
                rows={2}
                className="flex w-full rounded-md border border-input bg-white px-3 py-2 text-sm resize-none"
              />
            </div>
            {submitError && (
              <div className="rounded-md bg-destructive/10 px-3 py-2 text-sm text-destructive">{submitError}</div>
            )}
            <div className="flex items-center gap-2">
              <Button
                onClick={handleSubmit}
                disabled={!analistaId || isSubmitting}
                className="flex-1"
              >
                {isSubmitting ? "Asignando..." : `Asignar a ${selected.size} agente(s)`}
              </Button>
              <Button variant="outline" onClick={() => setStep("select")} className="flex-1">
                Volver
              </Button>
            </div>
          </div>
        </div>
      )}

      {step === "done" && submitResult && (
        <div className="fixed left-1/2 top-1/2 z-50 w-full max-w-md -translate-x-1/2 -translate-y-1/2 rounded-xl bg-white shadow-xl">
          <div className="flex flex-col items-center gap-4 px-6 py-10 text-center">
            <div className="flex h-14 w-14 items-center justify-center rounded-full bg-emerald-50">
              <svg className="h-7 w-7 text-emerald-600" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M5 13l4 4L19 7" />
              </svg>
            </div>
            <div>
              <p className="text-base font-semibold text-slate-900">Asignación masiva completada</p>
              <div className="mt-3 flex gap-6  text-sm">
                <span className="text-emerald-600 font-semibold">{submitResult.creados} creados</span>
                {submitResult.saltados > 0 && (
                  <span className="text-amber-600 font-semibold">{submitResult.saltados} ya tenían asignación</span>
                )}
                {submitResult.errores > 0 && (
                  <span className="text-red-600 font-semibold">{submitResult.errores} errores</span>
                )}
              </div>
            </div>
            <Button onClick={() => { onSuccess(); onClose() }} className="w-full max-w-xs">
              Aceptar
            </Button>
          </div>
        </div>
      )}
    </>
  )
}
