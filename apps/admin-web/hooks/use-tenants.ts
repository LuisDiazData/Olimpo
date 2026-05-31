"use client"

import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { api } from "@/lib/api-client"
import type { TenantCreateInput } from "@/lib/schemas"

// =============================================================================
// Tipos (espejo del backend)
// =============================================================================

export interface TenantListItem {
  id: string
  nombre: string
  subdominio: string
  activo: boolean
  tipo_plan: string
  estado_licencia: string
  fecha_vencimiento_licencia: string | null
  usuario_maestro_email: string | null
  created_at: string
}

export interface TenantDetail extends TenantListItem {
  supabase_url: string
  fecha_inicio_licencia: string | null
  usuario_maestro_id: string | null
  usuario_maestro_email: string | null
  updated_at: string
}

export interface StatsResponse {
  total_promotorias: number
  activas: number
  suspendidas: number
  en_prueba: number
  expiradas: number
  venciendo_30_dias: number
  ultimas_altas: Array<{
    id: string
    nombre: string
    subdominio: string
    estado_licencia: string
    created_at: string
  }>
}

// =============================================================================
// Queries
// =============================================================================

export function useStats() {
  return useQuery<StatsResponse>({
    queryKey: ["stats"],
    queryFn: () => api.get("/stats"),
  })
}

export function useTenants() {
  return useQuery<TenantListItem[]>({
    queryKey: ["tenants"],
    queryFn: () => api.get("/tenants"),
  })
}

export function useTenant(id: string) {
  return useQuery<TenantDetail>({
    queryKey: ["tenants", id],
    queryFn: () => api.get(`/tenants/${id}`),
    enabled: !!id,
  })
}

// =============================================================================
// Mutations
// =============================================================================

export function useCreateTenant() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (data: TenantCreateInput) => api.post<TenantDetail>("/tenants", data),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["tenants"] }),
  })
}

export function useBlockTenant() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (id: string) => api.post(`/tenants/${id}/bloquear`),
    onSuccess: (_, id) => {
      qc.invalidateQueries({ queryKey: ["tenants", id] })
      qc.invalidateQueries({ queryKey: ["tenants"] })
    },
  })
}

export function useActivateTenant() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (id: string) => api.post(`/tenants/${id}/activar`),
    onSuccess: (_, id) => {
      qc.invalidateQueries({ queryKey: ["tenants", id] })
      qc.invalidateQueries({ queryKey: ["tenants"] })
    },
  })
}
