"use client"

import { Shield, Mail } from "lucide-react"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"

const ROL_STYLES: Record<string, { label: string; variant: "slate" | "blue" | "violet" | "amber" | "emerald" }> = {
  director_general: { label: "Director General", variant: "slate" },
  director_ops:     { label: "Director de Operaciones", variant: "blue" },
  gerente:          { label: "Gerente", variant: "violet" },
  analista:         { label: "Analista", variant: "amber" },
}

const RAMO_STYLES: Record<string, { label: string; variant: "emerald" | "sky" | "violet" | "orange" | "slate" }> = {
  vida:  { label: "Vida", variant: "emerald" },
  gmm:   { label: "GMM", variant: "sky" },
  autos: { label: "Autos", variant: "violet" },
  pyme:  { label: "Pyme", variant: "orange" },
}

export interface UsuarioRow {
  id: string
  nombre: string
  email: string
  rol: string
  ramo: string | null
  ramos_adicionales: string[] | null
  telefono: string | null
  activo: boolean
}

interface Props {
  rows: UsuarioRow[]
  onSelect: (row: UsuarioRow) => void
  onDesactivar?: (row: UsuarioRow) => void
  canEdit?: boolean
}

function RolBadge({ rol }: { rol: string }) {
  const style = ROL_STYLES[rol] ?? { label: rol, variant: "slate" as const }
  return <Badge variant={style.variant}>{style.label}</Badge>
}

function RamosDisplay({ ramo, ramosAdicionales }: { ramo: string | null; ramosAdicionales: string[] | null }) {
  if (!ramo) return <span className="text-slate-400 text-xs">—</span>
  const adicionales = ramosAdicionales ?? []
  const principales = [ramo]
  const todos = [...principales, ...adicionales].filter(Boolean)

  return (
    <div className="flex flex-wrap gap-1">
      {todos.map((r, i) => {
        const style = RAMO_STYLES[r] ?? { label: r, variant: "slate" as const }
        return (
          <Badge key={r} variant={i === 0 ? style.variant : "slate"}>
            {style.label}
            {i === 0 && <span className="ml-1 opacity-60">·</span>}
          </Badge>
        )
      })}
    </div>
  )
}

export function UsuariosTabla({ rows, onSelect, onDesactivar, canEdit }: Props) {
  if (rows.length === 0) {
    return (
      <div className="flex flex-col items-center justify-center py-20 text-sm text-slate-400">
        <Shield className="mb-2 h-8 w-8" />
        <p>No hay usuarios registrados</p>
      </div>
    )
  }

  return (
    <div className="rounded-xl border bg-white overflow-hidden">
      <table className="w-full text-sm">
        <thead>
          <tr className="border-b bg-slate-50 text-left">
            <th className="px-4 py-3 font-medium text-slate-600">Nombre</th>
            <th className="px-4 py-3 font-medium text-slate-600">Correo</th>
            <th className="px-4 py-3 font-medium text-slate-600">Rol</th>
            <th className="px-4 py-3 font-medium text-slate-600">Ramo</th>
            <th className="px-4 py-3 font-medium text-slate-600">Estado</th>
            {canEdit && <th className="px-4 py-3 font-medium text-slate-600 text-right">Acciones</th>}
          </tr>
        </thead>
        <tbody className="divide-y divide-slate-100">
          {rows.map((row) => (
            <tr
              key={row.id}
              className="hover:bg-slate-50 cursor-pointer transition-colors"
              onClick={() => onSelect(row)}
            >
              <td className="px-4 py-3">
                <div className="flex items-center gap-3">
                  <div className="flex h-9 w-9 items-center justify-center rounded-full bg-slate-100 text-xs font-medium text-slate-600">
                    {row.nombre.split(" ").slice(0, 2).map((p) => p[0]?.toUpperCase() ?? "").join("")}
                  </div>
                  <span className="font-medium text-slate-900">{row.nombre}</span>
                </div>
              </td>
              <td className="px-4 py-3">
                <div className="flex items-center gap-1.5 text-slate-600">
                  <Mail className="h-3.5 w-3.5 shrink-0" />
                  <span className="truncate max-w-[200px]">{row.email}</span>
                </div>
              </td>
              <td className="px-4 py-3">
                <RolBadge rol={row.rol} />
              </td>
              <td className="px-4 py-3">
                <RamosDisplay ramo={row.ramo} ramosAdicionales={row.ramos_adicionales} />
              </td>
              <td className="px-4 py-3">
                {row.activo ? (
                  <span className="inline-flex items-center gap-1 text-xs text-emerald-700">
                    <span className="h-1.5 w-1.5 rounded-full bg-emerald-500" />
                    Activo
                  </span>
                ) : (
                  <span className="inline-flex items-center gap-1 text-xs text-red-600">
                    <span className="h-1.5 w-1.5 rounded-full bg-red-500" />
                    Inactivo
                  </span>
                )}
              </td>
              {canEdit && (
                <td className="px-4 py-3 text-right" onClick={(e) => e.stopPropagation()}>
                  {row.activo && onDesactivar ? (
                    <Button
                      variant="ghost"
                      size="sm"
                      className="h-8 text-red-600 hover:text-red-700 hover:bg-red-50"
                      onClick={() => onDesactivar(row)}
                    >
                      Desactivar
                    </Button>
                  ) : null}
                </td>
              )}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}