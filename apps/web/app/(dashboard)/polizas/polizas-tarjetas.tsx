import { FileX, User } from "lucide-react"
import { Badge } from "@/components/ui/badge"
import type { PolizaRow } from "./types"
import {
  ESTADO_POLIZA_BADGE,
  RAMO_BADGE,
  formatMoney,
  vigenciaLabel,
  estaVencida,
} from "./shared"

interface Props {
  rows: PolizaRow[]
  hasFilters: boolean
  onSelect?: (row: PolizaRow) => void
}

export function PolizasTarjetas({ rows, hasFilters, onSelect }: Props) {
  if (rows.length === 0) {
    return (
      <div className="flex flex-col items-center gap-3 rounded-xl border bg-white py-16 text-slate-400 shadow-sm">
        <FileX className="h-10 w-10" />
        <div className="text-center">
          <p className="text-sm font-medium text-slate-600">
            {hasFilters ? "Sin resultados para estos filtros" : "No hay pólizas"}
          </p>
          <p className="mt-0.5 text-xs">
            {hasFilters
              ? "Prueba ajustando o limpiando los filtros aplicados."
              : "Crea una póliza con el botón “Nueva póliza”."}
          </p>
        </div>
      </div>
    )
  }

  return (
    <div className="grid grid-cols-1 gap-3 sm:grid-cols-2 xl:grid-cols-3">
      {rows.map((row) => {
        const estado = ESTADO_POLIZA_BADGE[row.estado]
        const ramo = RAMO_BADGE[row.ramo]
        const vencida = estaVencida(row.fecha_fin)

        return (
          <div
            key={row.id}
            onClick={() => onSelect?.(row)}
            className="flex cursor-pointer flex-col rounded-xl border bg-white shadow-sm transition-shadow hover:shadow-md"
          >
            {/* Header: número + estado */}
            <div className="flex items-start justify-between gap-2 px-4 pb-2 pt-3.5">
              <span className="font-mono text-xs font-semibold text-slate-800">
                {row.numero_poliza}
              </span>
              {estado ? (
                <Badge variant={estado.variant}>{estado.label}</Badge>
              ) : (
                <span className="rounded-full border border-slate-200 bg-slate-50 px-2 py-0.5 text-[11px] font-medium text-slate-500">
                  {row.estado}
                </span>
              )}
            </div>

            {/* Agente */}
            <div className="px-4">
              {row.agente_nombre ? (
                <div className="flex items-center gap-2">
                  <div className="flex h-8 w-8 shrink-0 items-center justify-center rounded-full bg-slate-100">
                    <User className="h-4 w-4 text-slate-500" />
                  </div>
                  <div className="min-w-0">
                    <p className="truncate text-sm font-medium text-slate-800">
                      {row.agente_nombre}
                    </p>
                    {row.agente_cua && (
                      <p className="font-mono text-[11px] text-slate-400">CUA {row.agente_cua}</p>
                    )}
                  </div>
                </div>
              ) : (
                <p className="text-xs italic text-slate-400">Sin agente identificado</p>
              )}
            </div>

            {/* Badges */}
            <div className="flex flex-wrap gap-1.5 px-4 pb-3 pt-2">
              {ramo && <Badge variant={ramo.variant}>{ramo.label}</Badge>}
              {row.plan && (
                <span className="rounded-full border border-slate-200 bg-slate-50 px-2 py-0.5 text-[11px] font-medium text-slate-500">
                  {row.plan}
                </span>
              )}
            </div>

            <div className="mx-4 border-t" />

            {/* Footer: vigencia + prima */}
            <div className="flex items-center justify-between px-4 py-3">
              <span className={vencida ? "text-[11px] text-red-600" : "text-[11px] text-slate-500"}>
                {vigenciaLabel(row.fecha_inicio, row.fecha_fin)}
              </span>
              <span className="text-xs font-semibold text-slate-700">
                {formatMoney(row.prima_neta, row.moneda ?? "MXN")}
              </span>
            </div>
          </div>
        )
      })}
    </div>
  )
}
