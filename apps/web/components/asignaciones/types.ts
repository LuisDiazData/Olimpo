export interface AsignacionRow {
  id: string
  agente_id: string
  ramo: "vida" | "gmm" | "autos" | "pyme"
  analista_id: string
  notas: string | null
  asignado_por: string | null
  activo: boolean
  created_at: string
  updated_at: string
  agente_nombre?: string
  agente_cua?: string
  analista_nombre?: string
}

export interface BulkAsignacionResult {
  total: number
  creados: number
  saltados: number
  errores: number
  detalle: string[]
}

export const RAMOS = ["vida", "gmm", "autos", "pyme"] as const
export type Ramo = typeof RAMOS[number]

export const RAMO_LABELS: Record<string, string> = {
  vida:  "Vida",
  gmm:   "GMM",
  autos: "Autos",
  pyme:  "Pyme",
}
