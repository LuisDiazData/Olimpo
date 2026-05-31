import { AlertTriangle, FileX } from "lucide-react"
import { cn } from "@/lib/utils"
import { Badge } from "@/components/ui/badge"
import type { TramiteRow, TabValue } from "./types"
import { ESTADO_BADGE, TIPO_BADGE, PRIORIDAD_BADGE, RAMO_BADGE, SlaCell, relativeTime } from "./shared"

interface Props {
  rows: TramiteRow[]
  tab: TabValue
  hasFilters: boolean
  onSelect?: (row: TramiteRow) => void
}

function EmptyState({ colSpan, hasFilters }: { colSpan: number; hasFilters: boolean }) {
  return (
    <tr>
      <td colSpan={colSpan} className="px-4 py-16 text-center">
        <div className="flex flex-col items-center gap-3 text-slate-400">
          <FileX className="h-10 w-10" />
          <div>
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
      </td>
    </tr>
  )
}

export function TramitesTabla({ rows, tab, hasFilters, onSelect }: Props) {
  const colSpan = tab === "escalados" ? 11 : 10

  return (
    <div className="overflow-x-auto">
      <table className="w-full text-sm">
        <thead>
          <tr className="border-b bg-slate-50 text-left text-xs font-semibold uppercase tracking-wide text-slate-500">
            {tab === "escalados" && (
              <th className="px-4 py-3 w-0 whitespace-nowrap">Estado</th>
            )}
            <th className="px-4 py-3 whitespace-nowrap">Folio</th>
            <th className="px-4 py-3 whitespace-nowrap">Tipo</th>
            <th className="px-4 py-3 whitespace-nowrap">Agente</th>
            <th className="px-4 py-3 min-w-[200px]">Asunto</th>
            <th className="px-4 py-3 whitespace-nowrap">Estado trámite</th>
            <th className="px-4 py-3 whitespace-nowrap">Ramo</th>
            <th className="px-4 py-3 whitespace-nowrap">Equipo</th>
            <th className="px-4 py-3 whitespace-nowrap">Prioridad</th>
            <th className="px-4 py-3 whitespace-nowrap">SLA</th>
            <th className="px-4 py-3 whitespace-nowrap">Actividad</th>
          </tr>
        </thead>
        <tbody className="divide-y divide-slate-100">
          {rows.length === 0 ? (
            <EmptyState colSpan={colSpan} hasFilters={hasFilters} />
          ) : (
            rows.map((row) => (
              <tr
                key={row.id}
                onClick={() => onSelect?.(row)}
                className={cn(
                  "transition-colors hover:bg-slate-50 cursor-pointer",
                  row.requiere_atencion && "border-l-2 border-l-red-400"
                )}
              >
                {tab === "escalados" && (
                  <td className="px-4 py-3">
                    <span className="flex items-center gap-1 text-xs font-medium text-red-600 whitespace-nowrap">
                      <AlertTriangle className="h-3.5 w-3.5" />
                      Escalado
                    </span>
                  </td>
                )}

                <td className="px-4 py-3 whitespace-nowrap">
                  <span className="font-mono text-xs font-semibold text-slate-800">
                    {row.folio}
                  </span>
                </td>

                <td className="px-4 py-3 whitespace-nowrap">
                  {(() => {
                    const t = TIPO_BADGE[row.tipo_tramite]
                    return t ? (
                      <Badge variant={t.variant}>{t.label}</Badge>
                    ) : (
                      <span className="text-xs text-slate-400">{row.tipo_tramite}</span>
                    )
                  })()}
                </td>

                <td className="px-4 py-3 whitespace-nowrap">
                  {row.agente_nombre ? (
                    <div>
                      <p className="text-xs font-medium text-slate-800 max-w-[140px] truncate">
                        {row.agente_nombre}
                      </p>
                      {row.agente_cua && (
                        <p className="text-[11px] text-slate-400 font-mono">
                          CUA: {row.agente_cua}
                        </p>
                      )}
                    </div>
                  ) : (
                    <span className="text-xs text-slate-400 italic">Sin identificar</span>
                  )}
                </td>

                <td className="px-4 py-3">
                  <p className="max-w-[240px] truncate text-xs text-slate-700" title={row.titulo}>
                    {row.titulo}
                  </p>
                </td>

                <td className="px-4 py-3 whitespace-nowrap">
                  {(() => {
                    const e = ESTADO_BADGE[row.estado]
                    return e ? (
                      <Badge variant={e.variant}>{e.label}</Badge>
                    ) : (
                      <span className="text-xs text-slate-400">{row.estado}</span>
                    )
                  })()}
                </td>

                <td className="px-4 py-3 whitespace-nowrap">
                  {row.ramo ? (
                    (() => {
                      const r = RAMO_BADGE[row.ramo]
                      return r ? (
                        <Badge variant={r.variant}>{r.label}</Badge>
                      ) : (
                        <span className="text-xs text-slate-400">{row.ramo}</span>
                      )
                    })()
                  ) : (
                    <span className="text-xs text-slate-300">—</span>
                  )}
                </td>

                <td className="px-4 py-3 whitespace-nowrap">
                  <div className="text-xs">
                    {row.gerente_nombre ? (
                      <p className="font-medium text-slate-700 max-w-[120px] truncate">
                        {row.gerente_nombre}
                      </p>
                    ) : (
                      <p className="text-slate-300 italic">Sin gerente</p>
                    )}
                    {row.analista_nombre ? (
                      <p className="text-slate-400 max-w-[120px] truncate">
                        {row.analista_nombre}
                      </p>
                    ) : (
                      <p className="text-slate-300 italic text-[11px]">Sin asignar</p>
                    )}
                  </div>
                </td>

                <td className="px-4 py-3 whitespace-nowrap">
                  {(() => {
                    const p = PRIORIDAD_BADGE[row.prioridad]
                    return p ? (
                      <Badge variant={p.variant}>{p.label}</Badge>
                    ) : (
                      <span className="text-xs text-slate-400">{row.prioridad}</span>
                    )
                  })()}
                </td>

                <td className="px-4 py-3 whitespace-nowrap">
                  <SlaCell row={row} />
                </td>

                <td className="px-4 py-3 whitespace-nowrap">
                  <span className="text-xs text-slate-500">
                    {relativeTime(row.ultima_actividad)}
                  </span>
                </td>
              </tr>
            ))
          )}
        </tbody>
      </table>
    </div>
  )
}
