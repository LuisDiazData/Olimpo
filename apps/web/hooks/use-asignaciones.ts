import { useCallback } from "react"
import { api } from "@/lib/api"
import type { AsignacionRow, BulkAsignacionResult } from "@/components/asignaciones/types"

export function useAsignaciones() {
  const listar = useCallback(async (params?: {
    ramo?:    string
    agente_id?: string
    analista_id?: string
    activo?:   boolean
    limit?:    number
    offset?:   number
  }): Promise<AsignacionRow[]> => {
    const qs = new URLSearchParams()
    if (params?.ramo)          qs.set("ramo", params.ramo)
    if (params?.agente_id)      qs.set("agente_id", params.agente_id)
    if (params?.analista_id)    qs.set("analista_id", params.analista_id)
    if (params?.activo !== undefined) qs.set("activo", String(params.activo))
    if (params?.limit)          qs.set("limit", String(params.limit ?? 200))
    if (params?.offset)         qs.set("offset", String(params.offset ?? 0))
    const query = qs.toString() ? `?${qs.toString()}` : ""
    return api.get<AsignacionRow[]>(`/asignaciones${query}`)
  }, [])

  const crear = useCallback(async (data: {
    agente_id:   string
    ramo:        string
    analista_id: string
    notas?:      string
  }): Promise<AsignacionRow> => {
    const payload = {
      agente_id:   data.agente_id,
      ramo:        data.ramo,
      analista_id: data.analista_id,
      notas:       data.notas,
    }
    return api.post<AsignacionRow>("/asignaciones", payload)
  }, [])

  const actualizar = useCallback(async (id: string, data: {
    analista_id?: string
    notas?:       string
    activo?:      boolean
  }): Promise<AsignacionRow> => {
    return api.patch<AsignacionRow>(`/asignaciones/${id}`, data)
  }, [])

  const desactivar = useCallback(async (id: string): Promise<void> => {
    return api.delete<void>(`/asignaciones/${id}`)
  }, [])

  const masiva = useCallback(async (data: {
    agente_ids:  string[]
    ramo:        string
    analista_id: string
    notas?:      string
  }): Promise<BulkAsignacionResult> => {
    return api.post<BulkAsignacionResult>("/asignaciones/bulk", data)
  }, [])

  return { listar, crear, actualizar, desactivar, masiva }
}
