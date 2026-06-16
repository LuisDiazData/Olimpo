import { FileX } from "lucide-react"
import { cn } from "@/lib/utils"
import { Badge } from "@/components/ui/badge"
import type { PolizaRow } from "./types"
import {
  ESTADO_POLIZA_BADGE,
  RAMO_BADGE,
  formatMoney,
  vigenciaLabel,
} from "./shared"

interface Props {
  rows: PolizaRow[]
  hasFilters: boolean
  onSelect?: (row: PolizaRow) => void
}

function EmptyState({ colSpan, hasFilters }: { colSpan: number; hasFilters: boolean }) {
  return (
    <tr>
      <td colSpan={colSpan} className="px-4 py-16 text-center">
        <div className="flex flex-col items-center gap-3 text-slate-400">
          <FileX className="h-10 w-10" />
          <div>
            <p className="text-sm font-medium text-slate-600">
              {hasFilters ? "Sin resultados para estos filtros" : "No hay pólizas"}
            </p>
            <p className="mt-0.5 text-xs">
              {hasFilters
                ? "Prueba ajustando o limpiando los filtros aplicados."
                : "Crea una póliza con el botón “Nueva póliza” o se generarán al procesar trámites."}
            </p>
          </div>
        </div>
      </td>
    </tr>
  )
}

export function PolizasTabla({ rows, hasFilters, onSelect }: Props) {
  const colSpan = 7

  return (
    <div className="overflow-x-auto">
      <table className="w-full text-sm">
        <thead>
          <tr className="border-b bg-slate-50 text-left text-xs font-semibold uppercase tracking-wide text-slate-500">
            <th className="px-4 py-3 whitespace-nowrap">Número</th>
            <th className="px-4 py-3 whitespace-nowrap">Estado</th>
            <th className="px-4 py-3 whitespace-nowrap">Ramo</th>
            <th className="px-4 py-3 whitespace-nowrap">Agente</th>
            <th className="px-4 py-3 whitespace-nowrap">Plan</th>
            <th className="px-4 py-3 whitespace-nowrap">Vigencia</th>
            <th className="px-4 py-3 whitespace-nowrap text-right">Prima neta</th>
          </tr>
        </thead>
        <tbody className="divide-y divide-slate-100">
          {rows.length === 0 ? (
            <EmptyState colSpan={colSpan} hasFilters={hasFilters} />
          ) : (
            rows.map((row) => {
              const estado = ESTADO_POLIZA_BADGE[row.estado]
              const ramo = RAMO_BADGE[row.ramo]
              return (
                <tr
                  key={row.id}
                  onClick={() => onSelect?.(row)}
                  className="cursor-pointer transition-colors hover:bg-slate-50"
                >
                  <td className="px-4 py-3 whitespace-nowrap">
                    <span className="font-mono text-xs font-semibold text-slate-800">
                      {row.numero_poliza}
                    </span>
                  </td>

                  <td className="px-4 py-3 whitespace-nowrap">
                    {estado ? (
                      <Badge variant={estado.variant}>{estado.label}</Badge>
                    ) : (
                      <span className="text-xs text-slate-400">{row.estado}</span>
                    )}
                  </td>

                  <td className="px-4 py-3 whitespace-nowrap">
                    {ramo ? (
                      <Badge variant={ramo.variant}>{ramo.label}</Badge>
                    ) : (
                      <span className="text-xs text-slate-500">{row.ramo}</span>
                    )}
                  </td>

                  <td className="px-4 py-3 whitespace-nowrap">
                    {row.agente_nombre ? (
                      <div>
                        <p className="max-w-[160px] truncate text-xs font-medium text-slate-800">
                          {row.agente_nombre}
                        </p>
                        {row.agente_cua && (
                          <p className="font-mono text-[11px] text-slate-400">
                            CUA {row.agente_cua}
                          </p>
                        )}
                      </div>
                    ) : (
                      <span className="text-xs italic text-slate-400">Sin agente</span>
                    )}
                  </td>

                  <td className="px-4 py-3 whitespace-nowrap">
                    <span className="text-xs text-slate-600">{row.plan ?? "—"}</span>
                  </td>

                  <td className="px-4 py-3 whitespace-nowrap">
                    <span
                      className={cn(
                        "text-xs",
                        row.fecha_fin && new Date(row.fecha_fin) < new Date()
                          ? "text-red-600"
                          : "text-slate-600"
                      )}
                    >
                      {vigenciaLabel(row.fecha_inicio, row.fecha_fin)}
                    </span>
                  </td>

                  <td className="px-4 py-3 whitespace-nowrap text-right">
                    <span className="text-xs font-medium text-slate-700">
                      {formatMoney(row.prima_neta, row.moneda ?? "MXN")}
                    </span>
                  </td>
                </tr>
              )
            })
          )}
        </tbody>
      </table>
    </div>
  )
}
