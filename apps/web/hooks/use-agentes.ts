import { useCallback } from "react"
import { api } from "@/lib/api"
import { getSupabaseBrowserClient } from "@/lib/supabase"
import type { AgenteRow } from "@/components/agentes/types"

export interface ImportResult {
  total: number
  exitosos: number
  fallidos: number
  errores_duplicados: number
  detalle: string
  results: {
    row: number
    cua: string
    success: boolean
    agente_id: string | null
    error: string | null
  }[]
}

export function useAgentes() {
  const listar = useCallback(async (params?: {
    q?: string
    activo?: boolean
    limit?: number
    offset?: number
  }): Promise<AgenteRow[]> => {
    const qs = new URLSearchParams()
    if (params?.q) qs.set("q", params.q)
    if (params?.activo !== undefined) qs.set("activo", String(params.activo))
    if (params?.limit) qs.set("limit", String(params.limit))
    if (params?.offset) qs.set("offset", String(params.offset))
    const query = qs.toString() ? `?${qs.toString()}` : ""
    return api.get<AgenteRow[]>(`/agentes${query}`)
  }, [])

  const obtener = useCallback(async (id: string): Promise<AgenteRow> => {
    return api.get<AgenteRow>(`/agentes/${id}`)
  }, [])

  const crear = useCallback(async (data: Record<string, unknown>): Promise<AgenteRow> => {
    return api.post<AgenteRow>("/agentes", data)
  }, [])

  const actualizar = useCallback(async (id: string, data: Record<string, unknown>): Promise<AgenteRow> => {
    return api.patch<AgenteRow>(`/agentes/${id}`, data)
  }, [])

  const eliminar = useCallback(async (id: string): Promise<void> => {
    return api.delete<void>(`/agentes/${id}`)
  }, [])

  const importar = useCallback(async (file: File): Promise<ImportResult> => {
    const API_URL = process.env.NEXT_PUBLIC_API_URL ?? "http://localhost:8000"
    const form = new FormData()
    form.append("file", file)
    const res = await fetch(`${API_URL}/api/v1/agentes/import`, {
      method: "POST",
      credentials: "include",
      body: form,
    })
    if (!res.ok) {
      const body = await res.json().catch(() => ({}))
      throw new Error((body as { detail?: string }).detail ?? "Error al importar")
    }
    return res.json()
  }, [])

  const descargarTemplate = useCallback(async () => {
    const API_URL = process.env.NEXT_PUBLIC_API_URL ?? "http://localhost:8000"
    const supabase = getSupabaseBrowserClient()
    const { data: { session } } = await supabase.auth.getSession()
    const token = session?.access_token ?? ""
    const res = await fetch(`${API_URL}/api/v1/agentes/template`, {
      headers: { Authorization: `Bearer ${token}` },
    })
    if (!res.ok) {
      const body = await res.json().catch(() => ({}))
      throw new Error((body as { detail?: string }).detail ?? "Error al descargar plantilla")
    }
    const blob = await res.blob()
    const url = URL.createObjectURL(blob)
    const a = document.createElement("a")
    a.href = url
    a.download = "olimpo_agentes_template.xlsx"
    a.click()
    URL.revokeObjectURL(url)
  }, [])

  const agregarTelefono = useCallback(async (
    agenteId: string,
    data: { tipo: string; numero: string; preferente?: boolean }
  ) => {
    return api.post(`/agentes/${agenteId}/telefonos`, data)
  }, [])

  const eliminarTelefono = useCallback(async (agenteId: string, telefonoId: string) => {
    return api.delete(`/agentes/${agenteId}/telefonos/${telefonoId}`)
  }, [])

  const agregarEmail = useCallback(async (
    agenteId: string,
    data: { email: string; preferente?: boolean }
  ) => {
    return api.post(`/agentes/${agenteId}/emails`, data)
  }, [])

  const eliminarEmail = useCallback(async (agenteId: string, emailId: string) => {
    return api.delete(`/agentes/${agenteId}/emails/${emailId}`)
  }, [])

  return {
    listar,
    obtener,
    crear,
    actualizar,
    eliminar,
    importar,
    descargarTemplate,
    agregarTelefono,
    eliminarTelefono,
    agregarEmail,
    eliminarEmail,
  }
}
