"use client"

import { useRouter } from "next/navigation"
import { useTransition, useRef, useCallback } from "react"
import { Search, X, Loader2, LayoutList, LayoutGrid } from "lucide-react"
import { cn } from "@/lib/utils"
import type { VistaValue } from "./types"

const RAMO_OPTIONS = [
  { value: "", label: "Todos los ramos" },
  { value: "vida", label: "Vida" },
  { value: "gmm", label: "GMM" },
  { value: "autos", label: "Autos" },
  { value: "pyme", label: "PyME" },
]

const ESTADO_OPTIONS = [
  { value: "", label: "Todos los estados" },
  { value: "en_tramite", label: "En trámite" },
  { value: "activa", label: "Activa" },
  { value: "vencida", label: "Vencida" },
  { value: "cancelada", label: "Cancelada" },
]

const SELECT_CLASS =
  "h-8 rounded-md border bg-white px-2.5 text-sm text-slate-700 shadow-sm " +
  "focus:outline-none focus:ring-2 focus:ring-slate-300 cursor-pointer"

interface Props {
  vista: VistaValue
  ramo: string
  estado: string
  q: string
}

export function PolizasFiltros({ vista, ramo, estado, q }: Props) {
  const router = useRouter()
  const [isPending, startTransition] = useTransition()
  const qRef = useRef<HTMLInputElement>(null)

  const buildUrl = useCallback(
    (updates: Record<string, string>) => {
      const p = new URLSearchParams()
      if (vista !== "lista") p.set("vista", vista)
      if (ramo) p.set("ramo", ramo)
      if (estado) p.set("estado", estado)
      if (q) p.set("q", q)
      Object.entries(updates).forEach(([k, v]) => (v ? p.set(k, v) : p.delete(k)))
      p.delete("page")
      const qs = p.toString()
      return `/polizas${qs ? `?${qs}` : ""}`
    },
    [vista, ramo, estado, q]
  )

  const navigate = useCallback(
    (updates: Record<string, string>) => {
      startTransition(() => router.push(buildUrl(updates)))
    },
    [buildUrl, router]
  )

  const hasFilters = !!(ramo || estado || q)

  return (
    <div className="flex flex-wrap items-center gap-2">
      <select value={ramo} onChange={(e) => navigate({ ramo: e.target.value })} className={SELECT_CLASS}>
        {RAMO_OPTIONS.map((o) => (
          <option key={o.value} value={o.value}>
            {o.label}
          </option>
        ))}
      </select>

      <select value={estado} onChange={(e) => navigate({ estado: e.target.value })} className={SELECT_CLASS}>
        {ESTADO_OPTIONS.map((o) => (
          <option key={o.value} value={o.value}>
            {o.label}
          </option>
        ))}
      </select>

      {/* Búsqueda por número de póliza */}
      <form
        className="flex items-center gap-1.5"
        onSubmit={(e) => {
          e.preventDefault()
          navigate({ q: qRef.current?.value.trim() ?? "" })
        }}
      >
        <div className="relative">
          <Search className="pointer-events-none absolute left-2.5 top-1/2 h-3.5 w-3.5 -translate-y-1/2 text-slate-400" />
          <input
            ref={qRef}
            type="text"
            defaultValue={q}
            placeholder="Número de póliza"
            className={cn(
              "h-8 w-48 rounded-md border bg-white pl-8 pr-3 text-sm text-slate-700 shadow-sm",
              "placeholder:text-slate-400 focus:outline-none focus:ring-2 focus:ring-slate-300"
            )}
          />
        </div>
        <button
          type="submit"
          className="h-8 rounded-md bg-slate-900 px-3 text-xs font-medium text-white transition-colors hover:bg-slate-700"
        >
          Buscar
        </button>
      </form>

      {hasFilters && (
        <button
          onClick={() => startTransition(() => router.push("/polizas"))}
          className="flex h-8 items-center gap-1.5 rounded-md border px-3 text-xs text-slate-500 transition-colors hover:bg-slate-50 hover:text-slate-700"
        >
          <X className="h-3 w-3" />
          Limpiar filtros
        </button>
      )}

      {isPending && <Loader2 className="h-4 w-4 animate-spin text-slate-400" />}

      {/* View toggle */}
      <div className="ml-auto flex items-center overflow-hidden rounded-md border bg-white">
        <button
          onClick={() => navigate({ vista: "lista" })}
          title="Vista lista"
          className={cn(
            "flex h-8 w-8 items-center justify-center transition-colors",
            vista === "lista" ? "bg-slate-900 text-white" : "text-slate-500 hover:bg-slate-50"
          )}
        >
          <LayoutList className="h-4 w-4" />
        </button>
        <button
          onClick={() => navigate({ vista: "tarjetas" })}
          title="Vista tarjetas"
          className={cn(
            "flex h-8 w-8 items-center justify-center transition-colors",
            vista === "tarjetas" ? "bg-slate-900 text-white" : "text-slate-500 hover:bg-slate-50"
          )}
        >
          <LayoutGrid className="h-4 w-4" />
        </button>
      </div>
    </div>
  )
}
