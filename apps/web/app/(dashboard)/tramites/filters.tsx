"use client"

import { useRouter } from "next/navigation"
import { useTransition, useRef, useCallback } from "react"
import { Search, X, Loader2, LayoutList, LayoutGrid } from "lucide-react"
import { cn } from "@/lib/utils"
import type { GerenteOption, TabValue, VistaValue } from "./types"

const RAMO_OPTIONS = [
  { value: "", label: "Todos los ramos" },
  { value: "vida", label: "Vida" },
  { value: "gmm", label: "GMM" },
  { value: "autos", label: "Autos" },
  { value: "pyme", label: "PyME" },
]

const ESTADO_OPTIONS = [
  { value: "", label: "Todos los estados" },
  { value: "recibido", label: "Recibido" },
  { value: "en_revision", label: "En revisión" },
  { value: "pendiente_documentos_agente", label: "Docs. pendientes" },
  { value: "turnado_a_gnp", label: "Turnado a GNP" },
  { value: "activado_gnp", label: "Activado por GNP" },
  { value: "complemento_en_revision", label: "Complemento en revisión" },
  { value: "escalado", label: "Escalado" },
  { value: "completado", label: "Completado" },
  { value: "rechazado_gnp", label: "Rechazado por GNP" },
  { value: "cancelado", label: "Cancelado" },
]

const PRIORIDAD_OPTIONS = [
  { value: "", label: "Todas las prioridades" },
  { value: "urgente", label: "Urgente" },
  { value: "alta", label: "Alta" },
  { value: "normal", label: "Normal" },
]

const SELECT_CLASS =
  "h-8 rounded-md border bg-white px-2.5 text-sm text-slate-700 shadow-sm " +
  "focus:outline-none focus:ring-2 focus:ring-slate-300 cursor-pointer"

interface Props {
  gerentes: GerenteOption[]
  tab: TabValue
  vista: VistaValue
  ramo: string
  gerenteId: string
  estado: string
  prioridad: string
  agenteQuery: string
  tramiteCount: number
  escaladosCount: number
}

export function TramitesFiltros({
  gerentes,
  tab,
  vista,
  ramo,
  gerenteId,
  estado,
  prioridad,
  agenteQuery,
  tramiteCount,
  escaladosCount,
}: Props) {
  const router = useRouter()
  const [isPending, startTransition] = useTransition()
  const agenteRef = useRef<HTMLInputElement>(null)

  const buildUrl = useCallback(
    (updates: Record<string, string>) => {
      const p = new URLSearchParams()
      if (tab !== "todos") p.set("tab", tab)
      if (vista !== "lista") p.set("vista", vista)
      if (ramo) p.set("ramo", ramo)
      if (gerenteId) p.set("gerente", gerenteId)
      if (estado) p.set("estado", estado)
      if (prioridad) p.set("prioridad", prioridad)
      if (agenteQuery) p.set("agente", agenteQuery)
      Object.entries(updates).forEach(([k, v]) =>
        v ? p.set(k, v) : p.delete(k)
      )
      p.delete("page")
      const qs = p.toString()
      return `/tramites${qs ? `?${qs}` : ""}`
    },
    [tab, vista, ramo, gerenteId, estado, prioridad, agenteQuery]
  )

  const navigate = useCallback(
    (updates: Record<string, string>) => {
      startTransition(() => router.push(buildUrl(updates)))
    },
    [buildUrl, router]
  )

  const hasFilters = !!(ramo || gerenteId || estado || prioridad || agenteQuery)

  return (
    <div className="space-y-4">
      {/* ─── Tabs ─────────────────────────────────────────────────────── */}
      <div className="flex gap-0 border-b border-slate-200">
        <button
          onClick={() => navigate({ tab: "" })}
          className={cn(
            "px-4 py-2.5 text-sm font-medium border-b-2 -mb-px transition-colors select-none",
            tab === "todos"
              ? "border-slate-900 text-slate-900"
              : "border-transparent text-slate-500 hover:text-slate-700 hover:border-slate-300"
          )}
        >
          Todos los trámites
          <span className="ml-2 rounded-full bg-slate-100 px-2 py-0.5 text-xs font-medium text-slate-600">
            {tab === "todos" ? tramiteCount.toLocaleString("es-MX") : "—"}
          </span>
        </button>

        <button
          onClick={() => navigate({ tab: "escalados" })}
          className={cn(
            "flex items-center gap-1.5 px-4 py-2.5 text-sm font-medium border-b-2 -mb-px transition-colors select-none",
            tab === "escalados"
              ? "border-red-500 text-red-700"
              : "border-transparent text-slate-500 hover:text-red-600 hover:border-red-300"
          )}
        >
          {escaladosCount > 0 && (
            <span className="flex h-2 w-2 rounded-full bg-red-500 animate-pulse" />
          )}
          Casos escalados
          {escaladosCount > 0 && (
            <span
              className={cn(
                "rounded-full px-2 py-0.5 text-xs font-semibold",
                tab === "escalados"
                  ? "bg-red-100 text-red-700"
                  : "bg-red-100 text-red-600"
              )}
            >
              {escaladosCount}
            </span>
          )}
        </button>
      </div>

      {/* ─── Filter bar ───────────────────────────────────────────────── */}
      <div className="flex flex-wrap items-center gap-2">
        <select
          value={ramo}
          onChange={(e) => navigate({ ramo: e.target.value })}
          className={SELECT_CLASS}
        >
          {RAMO_OPTIONS.map((o) => (
            <option key={o.value} value={o.value}>
              {o.label}
            </option>
          ))}
        </select>

        <select
          value={gerenteId}
          onChange={(e) => navigate({ gerente: e.target.value })}
          className={SELECT_CLASS}
          disabled={gerentes.length === 0}
        >
          <option value="">
            {gerentes.length === 0 ? "Sin gerentes" : "Todos los gerentes"}
          </option>
          {gerentes.map((g) => (
            <option key={g.id} value={g.id}>
              {g.nombre}
            </option>
          ))}
        </select>

        <select
          value={estado}
          onChange={(e) => navigate({ estado: e.target.value })}
          className={SELECT_CLASS}
        >
          {ESTADO_OPTIONS.map((o) => (
            <option key={o.value} value={o.value}>
              {o.label}
            </option>
          ))}
        </select>

        <select
          value={prioridad}
          onChange={(e) => navigate({ prioridad: e.target.value })}
          className={SELECT_CLASS}
        >
          {PRIORIDAD_OPTIONS.map((o) => (
            <option key={o.value} value={o.value}>
              {o.label}
            </option>
          ))}
        </select>

        {/* Agente text search — form submit to avoid hammering the server */}
        <form
          className="flex items-center gap-1.5"
          onSubmit={(e) => {
            e.preventDefault()
            navigate({ agente: agenteRef.current?.value.trim() ?? "" })
          }}
        >
          <div className="relative">
            <Search className="absolute left-2.5 top-1/2 h-3.5 w-3.5 -translate-y-1/2 text-slate-400 pointer-events-none" />
            <input
              ref={agenteRef}
              type="text"
              defaultValue={agenteQuery}
              placeholder="Nombre o CUA del agente"
              className={cn(
                "h-8 w-52 rounded-md border bg-white pl-8 pr-3 text-sm text-slate-700 shadow-sm",
                "placeholder:text-slate-400 focus:outline-none focus:ring-2 focus:ring-slate-300"
              )}
            />
          </div>
          <button
            type="submit"
            className="h-8 rounded-md bg-slate-900 px-3 text-xs font-medium text-white hover:bg-slate-700 transition-colors"
          >
            Buscar
          </button>
        </form>

        {hasFilters && (
          <button
            onClick={() =>
              startTransition(() =>
                router.push(
                  tab === "escalados" ? "/tramites?tab=escalados" : "/tramites"
                )
              )
            }
            className="flex h-8 items-center gap-1.5 rounded-md border px-3 text-xs text-slate-500 hover:bg-slate-50 hover:text-slate-700 transition-colors"
          >
            <X className="h-3 w-3" />
            Limpiar filtros
          </button>
        )}

        {isPending && (
          <Loader2 className="h-4 w-4 animate-spin text-slate-400" />
        )}

        {/* View toggle — flush right */}
        <div className="ml-auto flex items-center rounded-md border bg-white overflow-hidden">
          <button
            onClick={() => navigate({ vista: "lista" })}
            title="Vista lista"
            className={cn(
              "flex h-8 w-8 items-center justify-center transition-colors",
              vista === "lista"
                ? "bg-slate-900 text-white"
                : "text-slate-500 hover:bg-slate-50"
            )}
          >
            <LayoutList className="h-4 w-4" />
          </button>
          <button
            onClick={() => navigate({ vista: "tarjetas" })}
            title="Vista tarjetas"
            className={cn(
              "flex h-8 w-8 items-center justify-center transition-colors",
              vista === "tarjetas"
                ? "bg-slate-900 text-white"
                : "text-slate-500 hover:bg-slate-50"
            )}
          >
            <LayoutGrid className="h-4 w-4" />
          </button>
        </div>
      </div>
    </div>
  )
}
