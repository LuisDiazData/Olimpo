export interface TramiteRow {
  id: string
  folio: string
  folio_ot: string | null
  tipo_tramite: string
  titulo: string
  estado: string
  prioridad: string
  ramo: string | null
  requiere_atencion: boolean
  fecha_recepcion: string
  ultima_actividad: string
  fecha_limite_sla: string | null
  agente_nombre: string | null
  agente_cua: string | null
  analista_nombre: string | null
  gerente_nombre: string | null
  sla_estado: string | null
  riesgo_sla: "verde" | "amarillo" | "rojo"
  resumen_ia: string | null
}

/** Detalle completo para la página /tramites/[id] */
export interface TramiteDetalle extends TramiteRow {
  // Póliza y asegurado (no en TramiteRow)
  poliza_id: string | null
  poliza_numero: string | null
  asegurado_id: string | null
  asegurado_nombre: string | null
  descripcion: string | null

  // Quién envió el trámite originalmente
  correo_origen_email: string | null
  correo_origen_nombre: string | null

  // Fechas GNP
  ot_fecha_envio: string | null
  ot_fecha_respuesta: string | null
  motivo_rechazo_gnp: string | null

  // IDs para navegación
  agente_id: string | null
  analista_id: string | null
  gerente_id: string | null

  // Pipeline IA
  paso_pipeline_actual: string | null

  // Meta
  canal_origen: string
  transiciones_disponibles: string[]
  etiquetas: string[]
  datos_tramite: Record<string, unknown>
  activo: boolean
  created_at: string
  updated_at: string
}

/** Evento individual del timeline del trámite */
export interface EventoTramite {
  id: string
  tipo_evento: string
  descripcion: string
  agente_ia_nombre: string | null
  usuario_nombre: string | null
  usuario_id: string | null
  created_at: string
  estado_anterior: string | null
  estado_nuevo: string | null
  datos: Record<string, unknown>
  visible_en_timeline: boolean
}

/** Documento clasificado vinculado al trámite */
export interface DocumentoTramite {
  id: string
  adjunto_id: string
  tramite_id: string
  adjunto_nombre: string | null
  tipo_documento: string
  tipo_mime: string | null
  tamanio_bytes: number | null
  estado_validacion: string
  confianza_ocr: number | null
  confianza_clasificacion: number | null
  motivo_invalidez: string | null
  vigente_hasta: string | null
  created_at: string
}

/** Entrada unificada de comunicación (correo o informal) */
export interface ComunicacionUnificada {
  id: string
  fuente: "correo" | "informal"
  fecha: string
  // Correo
  asunto?: string
  de_email?: string
  de_nombre?: string | null
  tipo_correo?: "entrante" | "saliente"
  es_origen?: boolean
  // Informal (whatsapp / telefono / presencial)
  medio?: "whatsapp" | "telefono" | "presencial"
  nota?: string
  comunicacion_entrante?: boolean
  requiere_seguimiento?: boolean
  usuario_nombre?: string | null
}

/** Correo vinculado a un trámite (del endpoint /tramites/{id}/correos) */
export interface CorreoTramiteItem {
  id: string
  tipo: "entrante" | "saliente"
  estado: string
  de_email: string
  de_nombre: string | null
  para_emails: string[]
  asunto: string
  fecha_correo: string
  es_origen: boolean
}

/** Persona involucrada en el trámite */
export interface ContactoTramite {
  id: string
  nombre: string
  email: string | null
  telefono: string | null
  rol: "agente" | "asistente" | "analista" | "gerente"
  cua?: string | null
}

export interface GerenteOption {
  id: string
  nombre: string
}

export type TabValue = "todos" | "escalados"
export type VistaValue = "lista" | "tarjetas"
