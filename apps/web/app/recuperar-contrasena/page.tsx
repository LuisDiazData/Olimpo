"use client"

import { useState } from "react"
import Link from "next/link"
import { useForm } from "react-hook-form"
import { zodResolver } from "@hookform/resolvers/zod"
import { Shield, AlertCircle, CheckCircle2 } from "lucide-react"
import { z } from "zod"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card"
import { getSupabaseBrowserClient } from "@/lib/supabase"

const schema = z.object({
  email: z.string().email("Ingresa un email válido"),
})

type FormInput = z.infer<typeof schema>

export default function RecuperarContrasenaPage() {
  const [enviado, setEnviado] = useState(false)
  const [isLoading, setIsLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const {
    register,
    handleSubmit,
    formState: { errors },
  } = useForm<FormInput>({ resolver: zodResolver(schema) })

  async function onSubmit(data: FormInput) {
    setIsLoading(true)
    setError(null)

    const siteUrl = process.env.NEXT_PUBLIC_SITE_URL ?? window.location.origin
    const redirectTo = `${siteUrl}/api/auth/callback?next=/restablecer-contrasena`

    const supabase = getSupabaseBrowserClient()
    const { error: sbError } = await supabase.auth.resetPasswordForEmail(
      data.email.trim().toLowerCase(),
      { redirectTo }
    )

    setIsLoading(false)

    if (sbError) {
      setError("Ocurrió un error. Intenta de nuevo.")
      return
    }

    setEnviado(true)
  }

  return (
    <div className="min-h-screen flex flex-col items-center justify-center bg-slate-50 px-4">
      <div className="mb-8 flex flex-col items-center gap-3 text-center">
        <div className="flex h-14 w-14 items-center justify-center rounded-xl bg-slate-900 shadow-lg">
          <Shield className="h-7 w-7 text-white" />
        </div>
        <div>
          <h1 className="text-2xl font-bold tracking-tight text-slate-900">Olimpo</h1>
          <p className="text-sm text-muted-foreground">CRM para promotórias de seguros</p>
        </div>
      </div>

      <Card className="w-full max-w-sm">
        <CardHeader className="text-center space-y-1">
          <CardTitle className="text-xl">Recuperar contraseña</CardTitle>
          <CardDescription>
            Ingresa tu correo y te enviaremos un enlace para restablecer tu contraseña.
          </CardDescription>
        </CardHeader>
        <CardContent>
          {enviado ? (
            <div className="flex flex-col items-center gap-4 py-2 text-center">
              <CheckCircle2 className="h-10 w-10 text-green-600" />
              <p className="text-sm text-muted-foreground">
                Si el correo está registrado, recibirás un enlace de recuperación en breve.
                Revisa también tu carpeta de spam.
              </p>
              <Link href="/login" className="text-sm font-medium underline hover:text-foreground">
                Volver al inicio de sesión
              </Link>
            </div>
          ) : (
            <form onSubmit={handleSubmit(onSubmit)} className="space-y-4">
              <div className="space-y-1.5">
                <Label htmlFor="email">Correo electrónico</Label>
                <Input
                  id="email"
                  type="email"
                  placeholder="director@promotoria.com"
                  autoComplete="email"
                  {...register("email")}
                />
                {errors.email && (
                  <p className="text-xs text-destructive">{errors.email.message}</p>
                )}
              </div>

              {error && (
                <div className="flex items-start gap-2 rounded-md bg-destructive/10 px-3 py-2.5 text-sm text-destructive">
                  <AlertCircle className="mt-0.5 h-4 w-4 shrink-0" />
                  <span>{error}</span>
                </div>
              )}

              <Button type="submit" className="w-full" disabled={isLoading}>
                {isLoading ? "Enviando..." : "Enviar enlace de recuperación"}
              </Button>

              <p className="text-center text-sm text-muted-foreground">
                <Link href="/login" className="underline hover:text-foreground">
                  Volver al inicio de sesión
                </Link>
              </p>
            </form>
          )}
        </CardContent>
      </Card>
    </div>
  )
}
