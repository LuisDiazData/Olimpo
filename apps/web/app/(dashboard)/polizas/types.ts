// Tipos del módulo de pólizas (frontend). Reflejan los modelos del backend
// (apps/api/models/poliza.py) y las respuestas de los sub-endpoints de la ficha.

/** Fila de la lista de pólizas (lectura directa de Supabase en la página servidor). */
export interface PolizaRow {
  id: string
  numero_poliza: string
  ramo: string
  estado: string
  plan: string | null
  fecha_inicio: string | null
  fecha_fin: string | null
  prima_neta: number | string | null
  moneda: string | null
  activo: boolean
  agente_nombre: string | null
  agente_cua: string | null
  analista_nombre: string | null
}

/** Asegurado vinculado a una póliza (poliza_asegurado + asegurado). */
export interface AseguradoVinculo {
  id: string
  asegurado_id: string
  asegurado_nombre: string | null
  asegurado_rfc: string | null
  rol: string // titular | asegurado_adicional | beneficiario
  parentesco: string | null
  porcentaje: number | string | null
}

/** Detalle completo de la póliza para la ficha /polizas/[id]. */
export interface PolizaDetalle extends PolizaRow {
  agente_id: string
  analista_id: string | null
  porcentaje_comision: number | string | null
  monto_comision: number | string | null
  datos_ramo: Record<string, unknown>
  notas: string | null
  created_at: string
  updated_at: string
  asegurados: AseguradoVinculo[]
}

/** Trámite de la póliza (GET /polizas/{id}/tramites → TramiteListItem). */
export interface TramiteDePoliza {
  id: string
  folio: string
  folio_ot: string | null
  tipo_tramite: string
  estado: string
  prioridad: string
  ramo: string | null
  titulo: string
  requiere_atencion: boolean
  analista_nombre: string | null
  fecha_recepcion: string
  fecha_limite_sla: string | null
  ultima_actividad: string
}

/** Recibo de comisión (GET /polizas/{id}/comisiones → ReciboComisionResponse). */
export interface ReciboComision {
  id: string
  numero_poliza_texto: string
  numero_recibo: string | null
  fecha_pago: string | null
  prima_pagada: number | string
  comision_total: number | string
  comision_agente: number | string
  comision_promotoria: number | string
  es_estorno: boolean
  moneda: string
  creado_en: string
}

/** Documento de la póliza (GET /polizas/{id}/documentos → DocumentoListItem). */
export interface DocumentoPoliza {
  id: string
  tramite_id: string
  adjunto_nombre: string | null
  tipo_documento: string
  estado_validacion: string
  confianza_ocr: number | string | null
  vigente_hasta: string | null
  created_at: string
}

/** Evento del historial unificado (GET /polizas/{id}/historial → EventoFichaPoliza). */
export interface EventoPoliza {
  fuente: "tramite" | "comision"
  tipo: string
  titulo: string
  descripcion: string
  fecha: string
  actor: string | null
  tramite_id: string | null
  tramite_folio: string | null
  datos: Record<string, unknown>
}

/** Opciones para los selectores del formulario de póliza. */
export interface AgenteOption {
  id: string
  nombre: string
  cua: string | null
}

export interface AnalistaOption {
  id: string
  nombre: string
}

export type VistaValue = "lista" | "tarjetas"
