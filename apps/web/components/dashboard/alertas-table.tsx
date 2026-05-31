"use client"

import Link from "next/link"
import { AlertCircle, Clock } from "lucide-react"
import { cn } from "@/lib/utils"
import type { AlertaTramite } from "@/app/(dashboard)/dashboard/data"

const ESTADO_LABELS: Record<string, string> = {
  recibido:                   "Recibido",
  en_revision:                "En revisión",
  pendiente_documentos_agente:"Docs. pendientes",
  turnado_a_gnp:              "Turnado a GNP",
  activado_gnp:               "Activado por GNP",
  complemento_en_revision:     "Complemento en rev.",
  escalado:                   "Escalado",
  completado:                 "Completado",
  rechazado_gnp:              "Rechazado por GNP",
  cancelado:                  "Cancelado",
}

const PRIORIDAD_STYLES: Record<string, string> = {
  urgente: "bg-red-100 text-red-700",
  alta:    "bg-amber-100 text-amber-700",
  normal:  "bg-slate-100 text-slate-600",
}

const RIESGO_COLOR: Record<string, string> = {
  verde:    "text-emerald-500",
  amarillo: "text-amber-500",
  rojo:     "text-red-500",
}

interface Props {
  alertas: AlertaTramite[]
}

function formatFecha(iso: string | null): string {
  if (!iso) return "—"
  return new Date(iso).toLocaleDateString("es-MX", {
    day: "numeric",
    month: "short",
    hour: "2-digit",
    minute: "2-digit",
  })
}

export function AlertasTable({ alertas }: Props) {
  if (alertas.length === 0) {
    return (
      <div className="flex items-center gap-2 rounded-lg border border-dashed bg-slate-50 px-4 py-8 text-sm text-muted-foreground">
        <AlertCircle className="h-4 w-4" />
        No hay trámites urgentes ni que requieran atención en este momento.
      </div>
    )
  }

  return (
    <div className="overflow-x-auto rounded-lg border bg-white">
      <table className="w-full text-sm">
        <thead>
          <tr className="border-b bg-slate-50 text-left text-xs font-medium uppercase tracking-wide text-slate-500">
            <th className="px-4 py-3">Folio</th>
            <th className="px-4 py-3">Título</th>
            <th className="px-4 py-3">Estado</th>
            <th className="px-4 py-3">Prioridad</th>
            <th className="px-4 py-3">Límite SLA</th>
            <th className="px-4 py-3">Analista</th>
            <th className="px-4 py-3">Atención</th>
          </tr>
        </thead>
        <tbody className="divide-y divide-slate-100">
          {alertas.map((t) => (
            <tr key={t.id} className="hover:bg-slate-50 transition-colors">
              <td className="whitespace-nowrap px-4 py-3">
                <Link
                  href={`/tramites/${t.id}`}
                  className="font-mono text-xs font-semibold text-blue-600 hover:text-blue-700 hover:underline"
                >
                  {t.folio}
                </Link>
              </td>
              <td className="max-w-xs px-4 py-3">
                <p className="truncate text-slate-800">{t.titulo}</p>
              </td>
              <td className="whitespace-nowrap px-4 py-3 text-xs text-slate-500">
                {ESTADO_LABELS[t.estado] ?? t.estado}
              </td>
              <td className="px-4 py-3">
                <span
                  className={cn(
                    "rounded-full px-2 py-0.5 text-xs font-medium capitalize",
                    PRIORIDAD_STYLES[t.prioridad] ?? PRIORIDAD_STYLES.normal
                  )}
                >
                  {t.prioridad}
                </span>
              </td>
              <td className="whitespace-nowrap px-4 py-3">
                <span className={cn("flex items-center gap-1 text-xs", RIESGO_COLOR[t.riesgo_sla])}>
                  <Clock className="h-3 w-3" />
                  {formatFecha(t.fecha_limite_sla)}
                </span>
              </td>
              <td className="whitespace-nowrap px-4 py-3 text-xs text-slate-500">
                {t.analista_nombre ?? "—"}
              </td>
              <td className="px-4 py-3">
                {t.requiere_atencion && (
                  <span className="flex items-center gap-1 text-xs font-medium text-red-600">
                    <AlertCircle className="h-3 w-3" />
                    Requiere atención
                  </span>
                )}
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}
