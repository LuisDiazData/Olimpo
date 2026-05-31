"use client"

import { api } from "./api"

export type Medio = "whatsapp" | "telefono" | "presencial"

export interface ComunicacionCreate {
  medio: Medio
  nota: string
  tramite_id?: string
  agente_id?: string
  comunicacion_entrante: boolean
  requiere_seguimiento: boolean
  tramite_generado_id?: string
}

export interface Comunicacion {
  id: string
  medio: Medio
  nota: string
  tramite_id: string | null
  tramite_folio: string | null
  agente_id: string | null
  agente_nombre: string | null
  comunicacion_entrante: boolean
  requiere_seguimiento: boolean
  usuario_nombre: string | null
  created_at: string
}

export function useComunicacionApi() {
  async function crear(data: ComunicacionCreate): Promise<Comunicacion> {
    return api.post<Comunicacion>("/comunicaciones", data)
  }

  async function listar(params: {
    tramite_id?: string
    agente_id?: string
    limit?: number
  }): Promise<Comunicacion[]> {
    const qs = new URLSearchParams()
    if (params.tramite_id) qs.set("tramite_id", params.tramite_id)
    if (params.agente_id) qs.set("agente_id", params.agente_id)
    if (params.limit) qs.set("limit", String(params.limit))
    return api.get<Comunicacion[]>(`/comunicaciones?${qs}`)
  }

  async function marcarSeguimiento(ids: string[], requiere: boolean): Promise<void> {
    await api.post("/comunicaciones/marcar-seguimiento", {
      comunicacion_ids: ids,
      requiere_seguimiento: requiere,
    })
  }

  return { crear, listar, marcarSeguimiento }
}
