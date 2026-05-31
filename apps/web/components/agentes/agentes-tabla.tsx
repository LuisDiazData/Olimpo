import { Pencil, FileX } from "lucide-react"
import type { AgenteRow } from "./types"

interface Props {
  rows: AgenteRow[]
  onSelect: (row: AgenteRow) => void
  canEdit: boolean
}

export function AgentesTabla({ rows, onSelect, canEdit }: Props) {
  if (rows.length === 0) {
    return (
      <div className="flex flex-col items-center gap-3 rounded-xl border border-dashed bg-slate-50 py-16 text-center">
        <FileX className="h-10 w-10 text-slate-300" />
        <div>
          <p className="text-sm font-medium text-slate-600">Sin resultados</p>
          <p className="mt-0.5 text-xs text-slate-400">
            Ajusta la búsqueda o el filtro de estatus.
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
            <th className="px-4 py-3 whitespace-nowrap">CUA</th>
            <th className="px-4 py-3 min-w-[180px]">Nombre</th>
            <th className="hidden px-4 py-3 whitespace-nowrap md:table-cell">
              Nombre comercial
            </th>
            <th className="hidden px-4 py-3 whitespace-nowrap lg:table-cell">RFC</th>
            <th className="hidden px-4 py-3 whitespace-nowrap md:table-cell">Email</th>
            <th className="hidden px-4 py-3 whitespace-nowrap lg:table-cell">Teléfono</th>
            <th className="px-4 py-3 whitespace-nowrap">Estatus</th>
            <th className="w-10 px-4 py-3" />
          </tr>
        </thead>
        <tbody className="divide-y divide-slate-100">
          {rows.map((row) => (
            <tr
              key={row.id}
              className="cursor-pointer hover:bg-slate-50 transition-colors"
              onClick={() => onSelect(row)}
            >
              <td className="px-4 py-3">
                <span className="font-mono text-xs font-semibold text-slate-700">
                  {row.cua}
                </span>
              </td>

              <td className="px-4 py-3">
                <span className="font-medium text-slate-900">{row.nombre}</span>
              </td>

              <td className="hidden px-4 py-3 text-slate-500 md:table-cell">
                {row.nombre_comercial ?? (
                  <span className="text-slate-300">—</span>
                )}
              </td>

              <td className="hidden px-4 py-3 lg:table-cell">
                {row.rfc ? (
                  <span className="font-mono text-xs text-slate-600">{row.rfc}</span>
                ) : (
                  <span className="text-slate-300">—</span>
                )}
              </td>

              <td className="hidden px-4 py-3 text-xs text-slate-500 md:table-cell">
                {row.email_preferente ?? <span className="text-slate-300">—</span>}
              </td>

              <td className="hidden px-4 py-3 lg:table-cell">
                {row.telefono_preferente ? (
                  <span className="font-mono text-xs text-slate-600">
                    {row.telefono_preferente}
                  </span>
                ) : (
                  <span className="text-slate-300">—</span>
                )}
              </td>

              <td className="px-4 py-3">
                <span
                  className={`inline-flex items-center rounded-full px-2 py-0.5 text-xs font-medium ${
                    row.activo
                      ? "bg-emerald-100 text-emerald-700"
                      : "bg-red-100 text-red-600"
                  }`}
                >
                  {row.activo ? "Activo" : "Inactivo"}
                </span>
              </td>

              <td
                className="px-3 py-3"
                onClick={(e) => {
                  e.stopPropagation()
                  onSelect(row)
                }}
              >
                <button
                  className="rounded p-1.5 text-slate-300 hover:bg-slate-100 hover:text-slate-600 transition-colors"
                  title={canEdit ? "Editar agente" : "Ver agente"}
                >
                  <Pencil className="h-3.5 w-3.5" />
                </button>
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}
