export interface AgenteRow {
  id: string
  cua: string
  nombre: string
  nombre_comercial: string | null
  rfc: string | null
  fecha_afiliacion: string | null
  activo: boolean
  email_preferente: string | null
  telefono_preferente: string | null
}

export interface AgenteDetail extends AgenteRow {
  created_at: string
  updated_at: string
  notas: string | null
  telefonos: TelefonoItem[]
  emails: EmailItem[]
  asistentes: AsistenteItem[]
}

export interface TelefonoItem {
  id: string
  agente_id: string
  tipo: "celular" | "oficina" | "casa" | "whatsapp" | "otro"
  numero: string
  preferente: boolean
  created_at: string
}

export interface EmailItem {
  id: string
  agente_id: string
  email: string
  preferente: boolean
  created_at: string
}

export interface AsistenteItem {
  id: string
  agente_id: string
  nombre: string
  email: string
  telefono: string | null
  activo: boolean
  created_at: string
  updated_at: string
}
