"use client"

import { Pencil, Trash2, FileX } from "lucide-react"
import type { AsignacionRow } from "./types"
import { RAMO_LABELS } from "./types"

const RAMO_COLORS: Record<string, string> = {
  vida:  "bg-blue-100 text-blue-700",
  gmm:   "bg-purple-100 text-purple-700",
  autos: "bg-orange-100 text-orange-700",
  pyme:  "bg-teal-100 text-teal-700",
}

interface Props {
  rows: AsignacionRow[]
  agentesMap: Record<string, { nombre: string; cua: string }>
  analistasMap: Record<string, { nombre: string }>
  onEdit?: (row: AsignacionRow) => void
  onDelete?: (row: AsignacionRow) => void
  puedeEditar: boolean
}

export function AsignacionesTabla({
  rows,
  agentesMap,
  analistasMap,
  onEdit,
  onDelete,
  puedeEditar,
}: Props) {
  if (rows.length === 0) {
    return (
      <div className="flex flex-col items-center gap-3 rounded-xl border border-dashed bg-slate-50 py-16 text-center">
        <FileX className="h-10 w-10 text-slate-300" />
        <div>
          <p className="text-sm font-medium text-slate-600">Sin reglas de asignación</p>
          <p className="mt-0.5 text-xs text-slate-400">
            Usa la pestaña «Configurar» para asignar agentes a analistas.
          </p>
        </div>
      </div>
    )
  }

  return (
    <div className="overflow-x-auto rounded-xl border bg-white shadow-sm">
      <table className="w-full text-sm">
        <thead>
          <tr className="border-b bg-slate-50 text-left text-xs font-semibold uppercase tracking-wide text-slate-500">
            <th className="px-4 py-3 whitespace-nowrap">Ramo</th>
            <th className="px-4 py-3 min-w-[200px]">Agente</th>
            <th className="px-4 py-3 min-w-[160px]">Analista</th>
            <th className="hidden px-4 py-3 md:table-cell">Notas</th>
            <th className="px-4 py-3 whitespace-nowrap">Estatus</th>
            {puedeEditar && <th className="w-10 px-4 py-3" />}
          </tr>
        </thead>
        <tbody className="divide-y divide-slate-100">
          {rows.map((row) => {
            const agente = agentesMap[row.agente_id]
            const analista = analistasMap[row.analista_id]

            return (
              <tr key={row.id} className="hover:bg-slate-50">
                <td className="px-4 py-3">
                  <span
                    className={`inline-flex items-center rounded-full px-2.5 py-0.5 text-xs font-medium ${
                      RAMO_COLORS[row.ramo] ?? "bg-slate-100 text-slate-700"
                    }`}
                  >
                    {RAMO_LABELS[row.ramo] ?? row.ramo}
                  </span>
                </td>

                <td className="px-4 py-3">
                  {agente ? (
                    <>
                      <p className="font-medium text-slate-900">{agente.nombre}</p>
                      <p className="text-xs font-mono text-slate-500">{agente.cua}</p>
                    </>
                  ) : (
                    <span className="font-mono text-xs text-slate-400">{row.agente_id}</span>
                  )}
                </td>

                <td className="px-4 py-3 text-slate-700">
                  {analista?.nombre ?? (
                    <span className="font-mono text-xs text-slate-400">{row.analista_id}</span>
                  )}
                </td>

                <td className="hidden px-4 py-3 text-xs text-slate-400 max-w-[200px] truncate md:table-cell">
                  {row.notas ?? "—"}
                </td>

                <td className="px-4 py-3">
                  <span
                    className={`inline-flex items-center rounded-full px-2 py-0.5 text-xs font-medium ${
                      row.activo
                        ? "bg-emerald-100 text-emerald-700"
                        : "bg-red-100 text-red-600"
                    }`}
                  >
                    {row.activo ? "Activa" : "Inactiva"}
                  </span>
                </td>

                {puedeEditar && (
                  <td className="px-3 py-3">
                    <div className="flex items-center gap-0.5">
                      {onEdit && (
                        <button
                          onClick={() => onEdit(row)}
                          title="Editar asignación"
                          className="rounded p-1.5 text-slate-400 hover:bg-slate-100 hover:text-slate-600"
                        >
                          <Pencil className="h-3.5 w-3.5" />
                        </button>
                      )}
                      {onDelete && (
                        <button
                          onClick={() => onDelete(row)}
                          title="Desactivar asignación"
                          className="rounded p-1.5 text-slate-400 hover:bg-red-50 hover:text-red-600"
                        >
                          <Trash2 className="h-3.5 w-3.5" />
                        </button>
                      )}
                    </div>
                  </td>
                )}
              </tr>
            )
          })}
        </tbody>
      </table>
    </div>
  )
}
