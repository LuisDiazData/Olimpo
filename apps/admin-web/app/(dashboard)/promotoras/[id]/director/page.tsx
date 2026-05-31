"use client"

import { use, useState } from "react"
import { useRouter } from "next/navigation"
import { useForm } from "react-hook-form"
import { zodResolver } from "@hookform/resolvers/zod"
import { ArrowLeft, Copy, CheckCheck } from "lucide-react"
import Link from "next/link"
import { useTenant } from "@/hooks/use-tenants"
import { useCrearDirector, useResetearPassword } from "@/hooks/use-director"
import { directorCreateSchema, resetPasswordSchema, type DirectorCreateInput, type ResetPasswordInput } from "@/lib/schemas"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"

export default function DirectorPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = use(params)
  const router = useRouter()
  const { data: tenant, isLoading } = useTenant(id)
  const [passwordTemporal, setPasswordTemporal] = useState<string | null>(null)
  const [copied, setCopied] = useState(false)
  const [serverError, setServerError] = useState<string | null>(null)

  const crear = useCrearDirector(id)
  const resetear = useResetearPassword(id)

  const tieneDirector = !!tenant?.usuario_maestro_id

  const createForm = useForm<DirectorCreateInput>({ resolver: zodResolver(directorCreateSchema) })
  const resetForm = useForm<ResetPasswordInput>({ resolver: zodResolver(resetPasswordSchema) })

  async function onCrear(data: DirectorCreateInput) {
    setServerError(null)
    try {
      const res = await crear.mutateAsync({
        nombre: data.nombre,
        email: data.email,
        password: data.password,
      })
      setPasswordTemporal(res.password_temporal)
    } catch (err: unknown) {
      const e = err as { message?: string }
      setServerError(e?.message ?? "Error al crear el director.")
    }
  }

  async function onResetear(data: ResetPasswordInput) {
    setServerError(null)
    try {
      const res = await resetear.mutateAsync({ nueva_password: data.nueva_password })
      setPasswordTemporal(res.nueva_password)
    } catch (err: unknown) {
      const e = err as { message?: string }
      setServerError(e?.message ?? "Error al resetear la contraseña.")
    }
  }

  function copyPassword() {
    if (passwordTemporal) {
      navigator.clipboard.writeText(passwordTemporal)
      setCopied(true)
      setTimeout(() => setCopied(false), 2000)
    }
  }

  if (isLoading) return <div className="text-sm text-muted-foreground">Cargando...</div>

  // Pantalla post-submit: muestra contraseña temporal
  if (passwordTemporal) {
    return (
      <div className="max-w-lg space-y-4">
        <div className="flex items-center gap-3">
          <Button asChild variant="ghost" size="sm">
            <Link href={`/promotoras/${id}`}>
              <ArrowLeft className="h-4 w-4" />
            </Link>
          </Button>
          <h1 className="text-xl font-semibold">Contraseña temporal</h1>
        </div>

        <div className="rounded-lg border border-amber-300 bg-amber-50 p-4 text-sm text-amber-800">
          <p className="font-semibold">Guarda esta contraseña ahora.</p>
          <p className="mt-1">No se puede recuperar después de cerrar esta pantalla. Compártela con el director de forma segura.</p>
        </div>

        <Card>
          <CardContent className="pt-6">
            <div className="flex items-center gap-3 rounded-md bg-slate-100 px-4 py-3 font-mono text-sm">
              <span className="flex-1 break-all">{passwordTemporal}</span>
              <button onClick={copyPassword} className="shrink-0 text-slate-500 hover:text-slate-900">
                {copied ? <CheckCheck className="h-4 w-4 text-green-600" /> : <Copy className="h-4 w-4" />}
              </button>
            </div>
          </CardContent>
        </Card>

        <Button asChild variant="outline">
          <Link href={`/promotoras/${id}`}>Volver a la promotoría</Link>
        </Button>
      </div>
    )
  }

  return (
    <div className="max-w-lg space-y-4">
      <div className="flex items-center gap-3">
        <Button asChild variant="ghost" size="sm">
          <Link href={`/promotoras/${id}`}>
            <ArrowLeft className="h-4 w-4" />
          </Link>
        </Button>
        <div>
          <h1 className="text-xl font-semibold">
            {tieneDirector ? "Resetear contraseña" : "Crear director general"}
          </h1>
          <p className="text-sm text-muted-foreground">{tenant?.nombre}</p>
        </div>
      </div>

      <Card>
        <CardHeader>
          <CardTitle className="text-base">
            {tieneDirector ? "Nueva contraseña" : "Datos del director"}
          </CardTitle>
        </CardHeader>
        <CardContent>
          {/* Modo crear */}
          {!tieneDirector && (
            <form onSubmit={createForm.handleSubmit(onCrear)} className="space-y-4">
              <div className="space-y-1.5">
                <Label>Nombre completo</Label>
                <Input {...createForm.register("nombre")} placeholder="Ej: Ana García López" />
                {createForm.formState.errors.nombre && (
                  <p className="text-xs text-destructive">{createForm.formState.errors.nombre.message}</p>
                )}
              </div>
              <div className="space-y-1.5">
                <Label>Email</Label>
                <Input type="email" {...createForm.register("email")} placeholder="director@promotoría.com" />
                {createForm.formState.errors.email && (
                  <p className="text-xs text-destructive">{createForm.formState.errors.email.message}</p>
                )}
              </div>
              <div className="space-y-1.5">
                <Label>Contraseña (mínimo 12 caracteres)</Label>
                <Input type="password" {...createForm.register("password")} />
                {createForm.formState.errors.password && (
                  <p className="text-xs text-destructive">{createForm.formState.errors.password.message}</p>
                )}
              </div>
              <div className="space-y-1.5">
                <Label>Confirmar contraseña</Label>
                <Input type="password" {...createForm.register("confirmar_password")} />
                {createForm.formState.errors.confirmar_password && (
                  <p className="text-xs text-destructive">{createForm.formState.errors.confirmar_password.message}</p>
                )}
              </div>
              {serverError && (
                <div className="rounded-md bg-destructive/10 px-3 py-2 text-sm text-destructive">{serverError}</div>
              )}
              <Button type="submit" className="w-full" disabled={crear.isPending}>
                {crear.isPending ? "Creando..." : "Crear director"}
              </Button>
            </form>
          )}

          {/* Modo resetear */}
          {tieneDirector && (
            <form onSubmit={resetForm.handleSubmit(onResetear)} className="space-y-4">
              <div className="text-sm text-muted-foreground">
                Director actual: <span className="font-medium text-foreground">{tenant?.usuario_maestro_email}</span>
              </div>
              <div className="space-y-1.5">
                <Label>Nueva contraseña (mínimo 12 caracteres)</Label>
                <Input type="password" {...resetForm.register("nueva_password")} />
                {resetForm.formState.errors.nueva_password && (
                  <p className="text-xs text-destructive">{resetForm.formState.errors.nueva_password.message}</p>
                )}
              </div>
              <div className="space-y-1.5">
                <Label>Confirmar contraseña</Label>
                <Input type="password" {...resetForm.register("confirmar_password")} />
                {resetForm.formState.errors.confirmar_password && (
                  <p className="text-xs text-destructive">{resetForm.formState.errors.confirmar_password.message}</p>
                )}
              </div>
              {serverError && (
                <div className="rounded-md bg-destructive/10 px-3 py-2 text-sm text-destructive">{serverError}</div>
              )}
              <Button type="submit" className="w-full" disabled={resetear.isPending}>
                {resetear.isPending ? "Reseteando..." : "Resetear contraseña"}
              </Button>
            </form>
          )}
        </CardContent>
      </Card>
    </div>
  )
}
