import { z } from "zod"

// =============================================================================
// Licencia
// =============================================================================

export const licenciaCreateSchema = z.object({
  tipo_plan: z.enum(["basico", "profesional", "enterprise"]).default("basico"),
  fecha_inicio_licencia: z.string().optional(),
  fecha_vencimiento_licencia: z.string().optional(),
  estado_licencia: z.enum(["activa", "prueba"]).default("prueba"),
})

export const licenciaUpdateSchema = z.object({
  tipo_plan: z.enum(["basico", "profesional", "enterprise"]).optional(),
  fecha_inicio_licencia: z.string().optional(),
  fecha_vencimiento_licencia: z.string().optional(),
  estado_licencia: z.enum(["activa", "prueba", "suspendida", "expirada"]).optional(),
})

export const renovarLicenciaSchema = z.object({
  dias: z.number().int().min(30).max(1095).default(365),
})

// =============================================================================
// Tenant
// =============================================================================

export const tenantCreateSchema = z.object({
  nombre: z.string().min(2, "Mínimo 2 caracteres").max(200),
  subdominio: z
    .string()
    .regex(
      /^[a-z0-9][a-z0-9-]*\.olimpo\.mx$/,
      "Formato: nombre.olimpo.mx (solo minúsculas, números y guiones)"
    ),
  supabase_url: z
    .string()
    .url("Debe ser una URL válida")
    .startsWith("https://", "Debe comenzar con https://"),
  service_role_key: z.string().min(100, "La service_role_key debe tener al menos 100 caracteres"),
  licencia: licenciaCreateSchema.optional(),
})

export type TenantCreateInput = z.infer<typeof tenantCreateSchema>
export type LicenciaUpdateInput = z.infer<typeof licenciaUpdateSchema>
export type RenovarLicenciaInput = z.infer<typeof renovarLicenciaSchema>

// =============================================================================
// Director general
// =============================================================================

export const directorCreateSchema = z.object({
  nombre: z.string().min(2, "Mínimo 2 caracteres").max(100),
  email: z.string().email("Email inválido"),
  password: z.string().min(12, "Mínimo 12 caracteres"),
  confirmar_password: z.string(),
}).refine((d) => d.password === d.confirmar_password, {
  message: "Las contraseñas no coinciden",
  path: ["confirmar_password"],
})

export const resetPasswordSchema = z.object({
  nueva_password: z.string().min(12, "Mínimo 12 caracteres"),
  confirmar_password: z.string(),
}).refine((d) => d.nueva_password === d.confirmar_password, {
  message: "Las contraseñas no coinciden",
  path: ["confirmar_password"],
})

export type DirectorCreateInput = z.infer<typeof directorCreateSchema>
export type ResetPasswordInput = z.infer<typeof resetPasswordSchema>

// =============================================================================
// Auth
// =============================================================================

export const loginSchema = z.object({
  api_key: z.string().min(1, "Ingresa tu API key"),
})

export type LoginInput = z.infer<typeof loginSchema>
