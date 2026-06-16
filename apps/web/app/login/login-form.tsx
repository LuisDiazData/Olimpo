"use client"

import { useState } from "react"
import { useRouter, useSearchParams } from "next/navigation"
import Link from "next/link"
import { useForm } from "react-hook-form"
import { zodResolver } from "@hookform/resolvers/zod"
import { Eye, EyeOff, Shield, AlertCircle, CheckCircle2 } from "lucide-react"
import { z } from "zod"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card"
import { useUser } from "@/components/providers/user-provider"

const loginSchema = z.object({
  email: z.string().email("Ingresa un email válido"),
  password: z.string().min(1, "La contraseña es requerida"),
})

type LoginInput = z.infer<typeof loginSchema>

export default function LoginForm() {
  const router = useRouter()
  const searchParams = useSearchParams()
  const { refreshPerfil } = useUser()
  const [showPassword, setShowPassword] = useState(false)
  const [authError, setAuthError] = useState<string | null>(null)
  const [isLoading, setIsLoading] = useState(false)

  const passwordRecuperado = searchParams.get("recuperado") === "1"
  const enlaceError = searchParams.get("error")

  const {
    register,
    handleSubmit,
    formState: { errors },
  } = useForm<LoginInput>({
    resolver: zodResolver(loginSchema),
  })

  async function onSubmit(data: LoginInput) {
    setIsLoading(true)
    setAuthError(null)

    const res = await fetch("/api/auth/login", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(data),
    })

    const body = await res.json().catch(() => ({}))

    if (!res.ok) {
      if (body.banned) {
        setAuthError("Tu cuenta ha sido suspendida. Contacta a tu administrador.")
      } else if (body.message?.includes("Invalid login credentials")) {
        setAuthError("Email o contraseña incorrectos.")
      } else {
        setAuthError(body.message ?? "Error al iniciar sesión. Intenta de nuevo.")
      }
      setIsLoading(false)
      return
    }

    // Actualizar perfil en contexto antes de navegar para evitar el flash de nav incorrecto.
    // El UserProvider persiste en el root layout — useState no se reinicializa al navegar.
    await refreshPerfil()
    router.push("/")
  }

  return (
    <div className="min-h-screen flex flex-col items-center justify-center bg-slate-50 px-4">
      {/* Logo / Branding */}
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
          <CardTitle className="text-xl">Iniciar sesión</CardTitle>
          <CardDescription>
            Ingresa tus credenciales para acceder al CRM
          </CardDescription>
        </CardHeader>
        <CardContent>
          {passwordRecuperado && (
            <div className="flex items-start gap-2 rounded-md bg-green-50 px-3 py-2.5 text-sm text-green-700 mb-4">
              <CheckCircle2 className="mt-0.5 h-4 w-4 shrink-0" />
              <span>Contraseña actualizada correctamente. Inicia sesión con tu nueva contraseña.</span>
            </div>
          )}
          {enlaceError && (
            <div className="flex items-start gap-2 rounded-md bg-destructive/10 px-3 py-2.5 text-sm text-destructive mb-4">
              <AlertCircle className="mt-0.5 h-4 w-4 shrink-0" />
              <span>
                {enlaceError === "enlace_expirado"
                  ? "El enlace de recuperación ha expirado. Solicita uno nuevo."
                  : "El enlace de recuperación no es válido."}
              </span>
            </div>
          )}
          <form onSubmit={handleSubmit(onSubmit)} className="space-y-4">
            {/* Email */}
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

            {/* Password */}
            <div className="space-y-1.5">
              <div className="flex items-center justify-between">
                <Label htmlFor="password">Contraseña</Label>
                <Link
                  href="/recuperar-contrasena"
                  className="text-xs text-muted-foreground hover:text-foreground transition-colors"
                >
                  ¿Olvidaste tu contraseña?
                </Link>
              </div>
              <div className="relative">
                <Input
                  id="password"
                  type={showPassword ? "text" : "password"}
                  placeholder="••••••••••"
                  autoComplete="current-password"
                  {...register("password")}
                />
                <button
                  type="button"
                  onClick={() => setShowPassword((v) => !v)}
                  className="absolute right-3 top-1/2 -translate-y-1/2 text-muted-foreground hover:text-foreground transition-colors"
                  tabIndex={-1}
                >
                  {showPassword ? (
                    <EyeOff className="h-4 w-4" />
                  ) : (
                    <Eye className="h-4 w-4" />
                  )}
                </button>
              </div>
              {errors.password && (
                <p className="text-xs text-destructive">{errors.password.message}</p>
              )}
            </div>

            {/* Auth error */}
            {authError && (
              <div className="flex items-start gap-2 rounded-md bg-destructive/10 px-3 py-2.5 text-sm text-destructive">
                <AlertCircle className="mt-0.5 h-4 w-4 shrink-0" />
                <span>{authError}</span>
              </div>
            )}

            <Button type="submit" className="w-full" disabled={isLoading}>
              {isLoading ? "Iniciando sesión..." : "Entrar"}
            </Button>
          </form>
        </CardContent>
      </Card>

      <p className="mt-6 text-center text-xs text-muted-foreground">
        ¿Necesitas ayuda? Contacta a tu{" "}
        <Link href="mailto:soporte@olimpo.mx" className="underline hover:text-foreground">
          equipo de soporte
        </Link>
      </p>
    </div>
  )
}
