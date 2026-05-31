import { AlertTriangle, FileX } from "lucide-react"
import { cn } from "@/lib/utils"
import { Badge } from "@/components/ui/badge"
import type { TramiteRow, TabValue } from "./types"
import { ESTADO_BADGE, TIPO_BADGE, PRIORIDAD_BADGE, RAMO_BADGE, SlaCell, relativeTime } from "./shared"

const SLA_BORDER: Record<TramiteRow["riesgo_sla"], string> = {
  verde:    "border-l-emerald-400",
  amarillo: "border-l-amber-400",
  rojo:     "border-l-red-500",
}

interface Props {
  rows: TramiteRow[]
  tab: TabValue
  hasFilters: boolean
  onSelect?: (row: TramiteRow) => void
}

export function TramitesTarjetas({ rows, hasFilters, onSelect }: Props) {
  if (rows.length === 0) {
    return (
      <div className="flex flex-col items-center gap-3 rounded-xl border bg-white py-16 text-slate-400 shadow-sm">
        <FileX className="h-10 w-10" />
        <div className="text-center">
          <p className="text-sm font-medium text-slate-600">
            {hasFilters ? "Sin resultados para estos filtros" : "No hay trámites"}
          </p>
          <p className="mt-0.5 text-xs">
            {hasFilters
              ? "Prueba ajustando o limpiando los filtros aplicados."
              : "Los trámites aparecerán aquí cuando lleguen correos de los agentes."}
          </p>
        </div>
      </div>
    )
  }

  return (
    <div className="grid gap-3 grid-cols-1 sm:grid-cols-2 xl:grid-cols-3">
      {rows.map((row) => {
        const estado = ESTADO_BADGE[row.estado]
        const tipo = TIPO_BADGE[row.tipo_tramite]
        const prioridad = PRIORIDAD_BADGE[row.prioridad]
        const ramo = row.ramo ? RAMO_BADGE[row.ramo] : null

        return (
          <div
            key={row.id}
            onClick={() => onSelect?.(row)}
            className={cn(
              "flex flex-col rounded-xl border bg-white shadow-sm border-l-4 cursor-pointer transition-shadow hover:shadow-md",
              SLA_BORDER[row.riesgo_sla],
              row.requiere_atencion && "ring-1 ring-red-200"
            )}
          >
            {/* Header: folio + estado + escalado flag */}
            <div className="flex items-start justify-between gap-2 px-4 pt-3.5 pb-2">
              <div className="flex items-center gap-2 min-w-0">
                <span className="font-mono text-xs font-semibold text-slate-800 shrink-0">
                  {row.folio}
                </span>
                {estado
                ? <Badge variant={estado.variant}>{estado.label}</Badge>
                : <span className="rounded-full border border-slate-200 bg-slate-50 px-2 py-0.5 text-[11px] font-medium text-slate-500">{row.estado}</span>
              }
              </div>
              {row.requiere_atencion && (
                <span className="flex shrink-0 items-center gap-1 text-[11px] font-medium text-red-600">
                  <AlertTriangle className="h-3 w-3" />
                  Escalado
                </span>
              )}
            </div>

            {/* Title */}
            <p
              className="flex-1 px-4 text-sm font-medium text-slate-800 line-clamp-2"
              title={row.titulo}
            >
              {row.titulo}
            </p>

            {/* Agente */}
            <div className="px-4 pt-2">
              {row.agente_nombre ? (
                <p className="truncate text-xs text-slate-500">
                  <span className="font-medium text-slate-700">{row.agente_nombre}</span>
                  {row.agente_cua && (
                    <span className="ml-1.5 font-mono text-[11px] text-slate-400">
                      CUA {row.agente_cua}
                    </span>
                  )}
                </p>
              ) : (
                <p className="text-xs italic text-slate-400">Sin agente identificado</p>
              )}
            </div>

            {/* Badges */}
            <div className="flex flex-wrap gap-1.5 px-4 pb-3 pt-2">
              {ramo && <Badge variant={ramo.variant}>{ramo.label}</Badge>}
              {tipo && <Badge variant={tipo.variant}>{tipo.label}</Badge>}
              {prioridad && <Badge variant={prioridad.variant}>{prioridad.label}</Badge>}
            </div>

            <div className="mx-4 border-t" />

            {/* Team */}
            <div className="flex min-w-0 items-center gap-1 px-4 py-2 text-[11px] text-slate-500">
              <span className="max-w-[80px] truncate">{row.gerente_nombre ?? "—"}</span>
              <span className="shrink-0 text-slate-300">›</span>
              <span className="truncate">{row.analista_nombre ?? "Sin asignar"}</span>
            </div>

            {/* Footer: SLA + relative time */}
            <div className="flex items-center justify-between px-4 pb-3.5">
              <SlaCell row={row} />
              <span className="text-[11px] text-slate-400">
                {relativeTime(row.ultima_actividad)}
              </span>
            </div>
          </div>
        )
      })}
    </div>
  )
}
