import { Clock } from "lucide-react"
import { cn } from "@/lib/utils"
import { Badge } from "@/components/ui/badge"
import type { TramiteRow } from "./types"

export const ESTADO_BADGE: Record<string, { label: string; variant: Parameters<typeof Badge>[0]["variant"] }> = {
  recibido:                   { label: "Recibido",              variant: "slate" },
  en_revision:                { label: "En revisión",           variant: "blue" },
  pendiente_documentos_agente:{ label: "Docs. pendientes",      variant: "amber" },
  turnado_a_gnp:              { label: "Turnado a GNP",         variant: "violet" },
  activado_gnp:               { label: "Activado por GNP",    variant: "orange" },
  complemento_en_revision:     { label: "Complemento en rev.",  variant: "sky" },
  escalado:                   { label: "Escalado",              variant: "rose" },
  completado:                 { label: "Completado",            variant: "green" },
  rechazado_gnp:              { label: "Rechazado por GNP",     variant: "red" },
  cancelado:                  { label: "Cancelado",             variant: "slate" },
}

export const TIPO_BADGE: Record<string, { label: string; variant: Parameters<typeof Badge>[0]["variant"] }> = {
  alta:         { label: "Alta",         variant: "blue" },
  endoso:       { label: "Endoso",       variant: "violet" },
  renovacion:   { label: "Renovación",   variant: "sky" },
  cancelacion:  { label: "Cancelación",  variant: "red" },
  siniestro:    { label: "Siniestro",    variant: "orange" },
  reactivacion: { label: "Reactivación", variant: "emerald" },
  consulta:     { label: "Consulta",     variant: "slate" },
  desconocido:  { label: "Desconocido",  variant: "slate" },
}

export const PRIORIDAD_BADGE: Record<string, { label: string; variant: Parameters<typeof Badge>[0]["variant"] }> = {
  urgente: { label: "Urgente", variant: "red" },
  alta:    { label: "Alta",    variant: "amber" },
  normal:  { label: "Normal",  variant: "slate" },
}

export const RAMO_BADGE: Record<string, { label: string; variant: Parameters<typeof Badge>[0]["variant"] }> = {
  vida:  { label: "Vida",  variant: "rose" },
  gmm:   { label: "GMM",   variant: "sky" },
  autos: { label: "Autos", variant: "amber" },
  pyme:  { label: "PyME",  variant: "violet" },
}

export function riesgoSla(fechaLimite: string | null): TramiteRow["riesgo_sla"] {
  if (!fechaLimite) return "verde"
  const horas = (new Date(fechaLimite).getTime() - Date.now()) / 3_600_000
  if (horas < 0) return "rojo"
  if (horas < 24) return "rojo"
  if (horas < 72) return "amarillo"
  return "verde"
}

export function relativeTime(iso: string): string {
  const diff = Date.now() - new Date(iso).getTime()
  const mins = Math.floor(diff / 60_000)
  if (mins < 2) return "ahora"
  if (mins < 60) return `hace ${mins} min`
  const hours = Math.floor(mins / 60)
  if (hours < 24) return `hace ${hours}h`
  const days = Math.floor(hours / 24)
  if (days === 1) return "ayer"
  if (days < 7) return `hace ${days} días`
  return new Date(iso).toLocaleDateString("es-MX", { day: "numeric", month: "short" })
}

export function formatFechaCorta(iso: string | null): string {
  if (!iso) return "—"
  return new Date(iso).toLocaleDateString("es-MX", {
    day: "numeric",
    month: "short",
    hour: "2-digit",
    minute: "2-digit",
  })
}

export function SlaCell({ row }: { row: TramiteRow }) {
  const colorClass = {
    verde:    "text-emerald-600",
    amarillo: "text-amber-600",
    rojo:     "text-red-600",
  }[row.riesgo_sla]

  const isVencido = row.fecha_limite_sla && new Date(row.fecha_limite_sla) < new Date()

  return (
    <div className={cn("flex items-center gap-1.5 text-xs", colorClass)}>
      <Clock className="h-3 w-3 shrink-0" />
      <div>
        {isVencido && (
          <p className="font-semibold uppercase tracking-wide">Vencido</p>
        )}
        <p>{formatFechaCorta(row.fecha_limite_sla)}</p>
      </div>
    </div>
  )
}