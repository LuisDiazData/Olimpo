"use client"

import { useState } from "react"
import { Upload, X, CheckCircle2, AlertCircle } from "lucide-react"
import { Button } from "@/components/ui/button"
import { getSupabaseBrowserClient } from "@/lib/supabase"
import type { ImportResult } from "@/hooks/use-agentes"

interface Props {
  open: boolean
  onClose: () => void
  onSuccess: () => void
}

type Step = "upload" | "result"

function parseErrorDetail(data: unknown): string {
  if (typeof data === "string" && data.length > 0) return data
  if (Array.isArray(data)) {
    return data.map((e) => (e as { msg?: string }).msg || JSON.stringify(e)).join("; ")
  }
  if (typeof data === "object" && data !== null) {
    const obj = data as Record<string, unknown>
    if (typeof obj.detail === "string" && obj.detail.length > 0) return obj.detail
    if (Array.isArray(obj.detail)) {
      return obj.detail.map((e) => (e as { msg?: string }).msg || JSON.stringify(e)).join("; ")
    }
  }
  return "Error desconocido al importar"
}

export function ImportarAgentesModal({ open, onClose, onSuccess }: Props) {
  const [step, setStep] = useState<Step>("upload")
  const [file, setFile] = useState<File | null>(null)
  const [dragOver, setDragOver] = useState(false)
  const [isLoading, setIsLoading] = useState(false)
  const [serverError, setServerError] = useState<string | null>(null)
  const [result, setResult] = useState<ImportResult | null>(null)

  function reset() {
    setStep("upload")
    setFile(null)
    setDragOver(false)
    setIsLoading(false)
    setServerError(null)
    setResult(null)
  }

  function handleClose() {
    reset()
    onClose()
  }

  async function handleImport() {
    if (!file) return
    setIsLoading(true)
    setServerError(null)

    const API_URL = process.env.NEXT_PUBLIC_API_URL ?? "http://localhost:8000"
    const supabase = getSupabaseBrowserClient()
    const { data: { session } } = await supabase.auth.getSession()
    const token = session?.access_token ?? ""

    const form = new FormData()
    form.append("file", file)

    try {
      const res = await fetch(`${API_URL}/api/v1/agentes/import`, {
        method: "POST",
        headers: { Authorization: `Bearer ${token}` },
        body: form,
      })
      const data = await res.json()
      if (!res.ok) {
        throw new Error(parseErrorDetail(data))
      }
      setResult(data as ImportResult)
      setStep("result")
    } catch (err: unknown) {
      setServerError((err as Error).message)
    } finally {
      setIsLoading(false)
    }
  }

  async function handleDownloadTemplate() {
    const API_URL = process.env.NEXT_PUBLIC_API_URL ?? "http://localhost:8000"
    const supabase = getSupabaseBrowserClient()
    const { data: { session } } = await supabase.auth.getSession()
    const token = session?.access_token ?? ""

    const res = await fetch(`${API_URL}/api/v1/agentes/template`, {
      headers: { Authorization: `Bearer ${token}` },
    })
    if (!res.ok) {
      const data = await res.json().catch(() => ({}))
      throw new Error(parseErrorDetail((data as { detail?: unknown }).detail))
    }
    const blob = await res.blob()
    const url = URL.createObjectURL(blob)
    const a = document.createElement("a")
    a.href = url
    a.download = "olimpo_agentes_template.xlsx"
    a.click()
    URL.revokeObjectURL(url)
  }

  if (!open) return null

  return (
    <>
      <div className="fixed inset-0 z-40 bg-black/40 backdrop-blur-sm" onClick={handleClose} />
      <div className="fixed left-1/2 top-1/2 z-50 w-full max-w-lg -translate-x-1/2 -translate-y-1/2 rounded-xl bg-white shadow-xl">
        <div className="flex items-center justify-between border-b px-6 py-4">
          <h2 className="text-base font-semibold text-slate-900">Importar agentes desde Excel</h2>
          <button
            onClick={handleClose}
            className="rounded-md p-1.5 text-slate-400 hover:bg-slate-100 hover:text-slate-600 transition-colors"
          >
            <X className="h-5 w-5" />
          </button>
        </div>

        <div className="px-6 py-5">
          {step === "upload" && (
            <div className="space-y-5">
              <div className="flex gap-3 rounded-lg border border-amber-200 bg-amber-50 px-4 py-3 text-sm text-amber-800">
                <AlertCircle className="mt-0.5 h-4 w-4 shrink-0 text-amber-500" />
                <div>
                  Usa la plantilla oficial para evitar errores. Descárgala antes de llenar los datos.
                </div>
              </div>

              <button
                onClick={handleDownloadTemplate}
                className="text-sm text-blue-600 hover:text-blue-700 hover:underline"
              >
                Descargar plantilla oficial
              </button>

              <div
                className={`relative flex flex-col items-center justify-center rounded-lg border-2 border-dashed p-10 transition-colors ${
                  dragOver ? "border-blue-500 bg-blue-50" : "border-slate-200 hover:border-slate-300"
                }`}
                onDragOver={(e) => { e.preventDefault(); setDragOver(true) }}
                onDragLeave={() => setDragOver(false)}
                onDrop={(e) => {
                  e.preventDefault()
                  setDragOver(false)
                  const f = e.dataTransfer.files[0]
                  if (f) setFile(f)
                }}
              >
                <Upload className="h-8 w-8 text-slate-400" />
                <p className="mt-3 text-sm font-medium text-slate-700">
                  {file ? file.name : "Arrastra el archivo aquí, o"}
                </p>
                <label className="mt-1 cursor-pointer text-sm text-blue-600 hover:text-blue-700">
                  haz clic para seleccionar
                  <input
                    type="file"
                    accept=".xlsx,.xls"
                    className="sr-only"
                    onChange={(e) => { if (e.target.files?.[0]) setFile(e.target.files?.[0]) }}
                  />
                </label>
                <p className="mt-1 text-xs text-slate-400">Formatos: .xlsx, .xls</p>
              </div>

              {serverError && (
                <div className="rounded-md bg-destructive/10 px-3 py-2 text-sm text-destructive">
                  {serverError}
                </div>
              )}
            </div>
          )}

          {step === "result" && result && (
            <div className="space-y-4">
              <div className="grid grid-cols-4 gap-3">
                <div className="rounded-lg border bg-slate-50 px-4 py-3 text-center">
                  <p className="text-2xl font-bold text-slate-900">{result.total}</p>
                  <p className="text-xs text-slate-500">Total filas</p>
                </div>
                <div className="rounded-lg border bg-emerald-50 px-4 py-3 text-center">
                  <p className="text-2xl font-bold text-emerald-700">{result.exitosos}</p>
                  <p className="text-xs text-emerald-600">Exitosos</p>
                </div>
                <div className="rounded-lg border bg-red-50 px-4 py-3 text-center">
                  <p className="text-2xl font-bold text-red-700">{result.errores_duplicados + result.fallidos}</p>
                  <p className="text-xs text-red-600">Errores</p>
                </div>
                <div className="rounded-lg border bg-amber-50 px-4 py-3 text-center">
                  <p className="text-2xl font-bold text-amber-700">{result.errores_duplicados}</p>
                  <p className="text-xs text-amber-600">Duplicados</p>
                </div>
              </div>

              <div className="max-h-64 overflow-y-auto rounded-lg border">
                <table className="w-full text-xs">
                  <thead className="sticky top-0 bg-slate-50 text-left">
                    <tr>
                      <th className="px-3 py-2 font-semibold text-slate-600">Fila</th>
                      <th className="px-3 py-2 font-semibold text-slate-600">CUA</th>
                      <th className="px-3 py-2 font-semibold text-slate-600">Estado</th>
                      <th className="px-3 py-2 font-semibold text-slate-600">Detalle</th>
                    </tr>
                  </thead>
                  <tbody className="divide-y divide-slate-100">
                    {result.results.map((r, i) => (
                      <tr key={i} className="hover:bg-slate-50">
                        <td className="px-3 py-2 text-slate-500">{r.row}</td>
                        <td className="px-3 py-2 font-mono text-slate-700">{r.cua}</td>
                        <td className="px-3 py-2">
                          {r.success ? (
                            <span className="inline-flex items-center gap-1 text-emerald-600">
                              <CheckCircle2 className="h-3.5 w-3.5" /> OK
                            </span>
                          ) : (
                            <span className="inline-flex items-center gap-1 text-red-600">
                              <AlertCircle className="h-3.5 w-3.5" /> Error
                            </span>
                          )}
                        </td>
                        <td className="px-3 py-2 text-slate-500">{r.error ?? r.agente_id}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            </div>
          )}
        </div>

        <div className="flex gap-3 border-t px-6 py-4">
          {step === "upload" && (
            <>
              <Button variant="outline" onClick={handleClose} className="flex-1">Cancelar</Button>
              <Button onClick={handleImport} disabled={!file || isLoading} className="flex-1">
                {isLoading ? "Importando..." : "Importar"}
              </Button>
            </>
          )}
          {step === "result" && (
            <>
              <Button variant="outline" onClick={handleClose} className="flex-1">Cerrar</Button>
              <Button onClick={() => { reset(); onSuccess() }} className="flex-1">Aceptar</Button>
            </>
          )}
        </div>
      </div>
    </>
  )
}
