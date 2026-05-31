"use client"

import { useMutation, useQueryClient } from "@tanstack/react-query"
import { api } from "@/lib/api-client"
import type { LicenciaUpdateInput, RenovarLicenciaInput } from "@/lib/schemas"

export function useUpdateLicencia(tenantId: string) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (data: LicenciaUpdateInput) =>
      api.put(`/tenants/${tenantId}/licencia`, data),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["tenants", tenantId] }),
  })
}

export function useRenovarLicencia(tenantId: string) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (data: RenovarLicenciaInput) =>
      api.post(`/tenants/${tenantId}/licencia/renovar`, data),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ["tenants", tenantId] })
      qc.invalidateQueries({ queryKey: ["stats"] })
    },
  })
}

export function useSuspenderLicencia(tenantId: string) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: () => api.post(`/tenants/${tenantId}/licencia/suspender`),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ["tenants", tenantId] })
      qc.invalidateQueries({ queryKey: ["stats"] })
    },
  })
}

export function useActivarLicencia(tenantId: string) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: () => api.post(`/tenants/${tenantId}/licencia/activar`),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ["tenants", tenantId] })
      qc.invalidateQueries({ queryKey: ["stats"] })
    },
  })
}
