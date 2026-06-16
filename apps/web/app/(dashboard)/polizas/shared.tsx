import { Badge } from "@/components/ui/badge"
// Reutilizamos los helpers compartidos del módulo de trámites para mantener
// consistencia visual (badges de ramo, formato de fechas, tiempo relativo).
export { RAMO_BADGE, relativeTime, formatFechaCorta } from "../tramites/shared"

type BadgeVariant = Parameters<typeof Badge>[0]["variant"]

export const ESTADO_POLIZA_BADGE: Record<string, { label: string; variant: BadgeVariant }> = {
  en_tramite: { label: "En trámite", variant: "amber" },
  activa: { label: "Activa", variant: "green" },
  vencida: { label: "Vencida", variant: "slate" },
  cancelada: { label: "Cancelada", variant: "red" },
}

export const ROL_ASEGURADO_BADGE: Record<string, { label: string; variant: BadgeVariant }> = {
  titular: { label: "Titular", variant: "blue" },
  asegurado_adicional: { label: "Adicional", variant: "sky" },
  beneficiario: { label: "Beneficiario", variant: "violet" },
}

/** Formatea un monto con su moneda (es-MX). Acepta number o string (Decimal del backend). */
export function formatMoney(value: number | string | null | undefined, moneda = "MXN"): string {
  if (value === null || value === undefined || value === "") return "—"
  const n = Number(value)
  if (Number.isNaN(n)) return "—"
  return new Intl.NumberFormat("es-MX", {
    style: "currency",
    currency: moneda || "MXN",
    minimumFractionDigits: 2,
  }).format(n)
}

/** Fecha sin hora (vigencias de la póliza). */
export function formatFecha(iso: string | null | undefined): string {
  if (!iso) return "—"
  return new Date(iso).toLocaleDateString("es-MX", {
    day: "numeric",
    month: "short",
    year: "numeric",
  })
}

/** Etiqueta de vigencia "inicio – fin" para encabezados y tarjetas. */
export function vigenciaLabel(inicio: string | null, fin: string | null): string {
  if (!inicio && !fin) return "Sin vigencia"
  return `${formatFecha(inicio)} – ${formatFecha(fin)}`
}

/** True si la póliza venció (fecha_fin pasada). */
export function estaVencida(fechaFin: string | null): boolean {
  if (!fechaFin) return false
  return new Date(fechaFin) < new Date()
}
