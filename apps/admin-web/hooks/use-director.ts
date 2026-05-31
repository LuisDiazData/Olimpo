"use client"

import { useMutation, useQueryClient } from "@tanstack/react-query"
import { api } from "@/lib/api-client"
import type { DirectorCreateInput, ResetPasswordInput } from "@/lib/schemas"

export interface DirectorCreateResponse {
  usuario_id: string
  email: string
  nombre: string
  password_temporal: string
}

export interface ResetPasswordResponse {
  mensaje: string
  nueva_password: string
  advertencia: string
}

export function useCrearDirector(tenantId: string) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (data: Omit<DirectorCreateInput, "confirmar_password">) =>
      api.post<DirectorCreateResponse>(`/tenants/${tenantId}/usuario-maestro`, data),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["tenants", tenantId] }),
  })
}

export function useResetearPassword(tenantId: string) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (data: Pick<ResetPasswordInput, "nueva_password">) =>
      api.post<ResetPasswordResponse>(`/tenants/${tenantId}/usuario-maestro/reset-password`, data),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["tenants", tenantId] }),
  })
}
