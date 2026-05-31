"use client"

import { useState } from "react"
import { useRouter } from "next/navigation"
import { useForm } from "react-hook-form"
import { zodResolver } from "@hookform/resolvers/zod"
import { Eye, EyeOff } from "lucide-react"
import { tenantCreateSchema, type TenantCreateInput } from "@/lib/schemas"
import { useCreateTenant } from "@/hooks/use-tenants"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select"

const STEPS = ["Datos de la empresa", "Credenciales Supabase", "Licencia"] as const

export default function NuevaPromotoraPage() {
  const router = useRouter()
  const [step, setStep] = useState(0)
  const [showKey, setShowKey] = useState(false)
  const [serverError, setServerError] = useState<string | null>(null)

  const createTenant = useCreateTenant()

  const {
    register,
    handleSubmit,
    setValue,
    watch,
    trigger,
    formState: { errors },
  } = useForm<TenantCreateInput>({
    resolver: zodResolver(tenantCreateSchema),
    defaultValues: {
      licencia: { tipo_plan: "basico", estado_licencia: "prueba" },
    },
  })

  const plan = watch("licencia.tipo_plan") ?? "basico"
  const estadoLicencia = watch("licencia.estado_licencia") ?? "prueba"

  async function goNext() {
    const fieldsPerStep: (keyof TenantCreateInput)[][] = [
      ["nombre", "subdominio"],
      ["supabase_url", "service_role_key"],
      [],
    ]
    const valid = await trigger(fieldsPerStep[step] as (keyof TenantCreateInput)[])
    if (valid) setStep((s) => s + 1)
  }

  async function onSubmit(data: TenantCreateInput) {
    setServerError(null)
    try {
      const result = await createTenant.mutateAsync(data)
      router.push(`/promotoras/${result.id}`)
    } catch (err: unknown) {
      const e = err as { errorCode?: string; message?: string }
      if (e?.errorCode === "SUBDOMINIO_DUPLICADO") {
        setServerError("Ya existe una promotoría con ese subdominio.")
      } else {
        setServerError(e?.message ?? "Error al registrar la promotoría.")
      }
    }
  }

  return (
    <div className="max-w-lg space-y-4">
      <div>
        <h1 className="text-xl font-semibold">Nueva promotoría</h1>
        <p className="text-sm text-muted-foreground">Paso {step + 1} de {STEPS.length}: {STEPS[step]}</p>
      </div>

      {/* Indicador de pasos */}
      <div className="flex gap-2">
        {STEPS.map((_, i) => (
          <div
            key={i}
            className={`h-1.5 flex-1 rounded-full ${i <= step ? "bg-slate-900" : "bg-slate-200"}`}
          />
        ))}
      </div>

      <Card>
        <CardHeader>
          <CardTitle className="text-base">{STEPS[step]}</CardTitle>
        </CardHeader>
        <CardContent>
          <form onSubmit={handleSubmit(onSubmit)} className="space-y-4">
            {/* Paso 1 */}
            {step === 0 && (
              <>
                <div className="space-y-1.5">
                  <Label htmlFor="nombre">Nombre de la promotoría</Label>
                  <Input id="nombre" placeholder="Ej: Promotoría Álvarez" {...register("nombre")} />
                  {errors.nombre && <p className="text-xs text-destructive">{errors.nombre.message}</p>}
                </div>
                <div className="space-y-1.5">
                  <Label htmlFor="subdominio">Subdominio</Label>
                  <Input id="subdominio" placeholder="Ej: alvarez.olimpo.mx" {...register("subdominio")} />
                  {errors.subdominio && <p className="text-xs text-destructive">{errors.subdominio.message}</p>}
                  <p className="text-xs text-muted-foreground">Solo minúsculas, números y guiones. Termina en .olimpo.mx</p>
                </div>
              </>
            )}

            {/* Paso 2 */}
            {step === 1 && (
              <>
                <div className="space-y-1.5">
                  <Label htmlFor="supabase_url">URL de Supabase</Label>
                  <Input id="supabase_url" placeholder="https://abc123.supabase.co" {...register("supabase_url")} />
                  {errors.supabase_url && <p className="text-xs text-destructive">{errors.supabase_url.message}</p>}
                </div>
                <div className="space-y-1.5">
                  <Label htmlFor="service_role_key">Service Role Key</Label>
                  <div className="relative">
                    <Input
                      id="service_role_key"
                      type={showKey ? "text" : "password"}
                      placeholder="eyJhbGciOiJIUzI1NiIs..."
                      {...register("service_role_key")}
                    />
                    <button
                      type="button"
                      className="absolute right-3 top-1/2 -translate-y-1/2 text-muted-foreground hover:text-foreground"
                      onClick={() => setShowKey((v) => !v)}
                      tabIndex={-1}
                    >
                      {showKey ? <EyeOff className="h-4 w-4" /> : <Eye className="h-4 w-4" />}
                    </button>
                  </div>
                  {errors.service_role_key && (
                    <p className="text-xs text-destructive">{errors.service_role_key.message}</p>
                  )}
                  <p className="text-xs text-muted-foreground">Se almacena cifrada. Nunca en texto plano.</p>
                </div>
              </>
            )}

            {/* Paso 3 */}
            {step === 2 && (
              <>
                <div className="space-y-1.5">
                  <Label>Plan</Label>
                  <Select value={plan} onValueChange={(v) => setValue("licencia.tipo_plan", v as "basico" | "profesional" | "enterprise")}>
                    <SelectTrigger>
                      <SelectValue placeholder="Selecciona plan" />
                    </SelectTrigger>
                    <SelectContent>
                      <SelectItem value="basico">Básico</SelectItem>
                      <SelectItem value="profesional">Profesional</SelectItem>
                      <SelectItem value="enterprise">Enterprise</SelectItem>
                    </SelectContent>
                  </Select>
                </div>
                <div className="space-y-1.5">
                  <Label htmlFor="fecha_inicio">Fecha de inicio</Label>
                  <Input id="fecha_inicio" type="date" {...register("licencia.fecha_inicio_licencia")} />
                </div>
                <div className="space-y-1.5">
                  <Label htmlFor="fecha_venc">Fecha de vencimiento</Label>
                  <Input id="fecha_venc" type="date" {...register("licencia.fecha_vencimiento_licencia")} />
                  <p className="text-xs text-muted-foreground">Dejar vacío en modo prueba para 30 días automáticos.</p>
                </div>
                <div className="space-y-1.5">
                  <Label>Estado inicial</Label>
                  <Select value={estadoLicencia} onValueChange={(v) => setValue("licencia.estado_licencia", v as "activa" | "prueba")}>
                    <SelectTrigger>
                      <SelectValue />
                    </SelectTrigger>
                    <SelectContent>
                      <SelectItem value="prueba">Prueba</SelectItem>
                      <SelectItem value="activa">Activa</SelectItem>
                    </SelectContent>
                  </Select>
                </div>
              </>
            )}

            {serverError && (
              <div className="rounded-md bg-destructive/10 px-3 py-2 text-sm text-destructive">
                {serverError}
              </div>
            )}

            <div className="flex gap-3 pt-2">
              {step > 0 && (
                <Button type="button" variant="outline" onClick={() => setStep((s) => s - 1)}>
                  Atrás
                </Button>
              )}
              {step < STEPS.length - 1 ? (
                <Button type="button" onClick={goNext} className="flex-1">
                  Siguiente
                </Button>
              ) : (
                <Button type="submit" className="flex-1" disabled={createTenant.isPending}>
                  {createTenant.isPending ? "Registrando..." : "Registrar promotoría"}
                </Button>
              )}
            </div>
          </form>
        </CardContent>
      </Card>
    </div>
  )
}
