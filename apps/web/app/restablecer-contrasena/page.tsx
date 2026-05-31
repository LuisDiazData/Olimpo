"use client"

import { useState } from "react"
import { useRouter } from "next/navigation"
import Link from "next/link"
import { useForm } from "react-hook-form"
import { zodResolver } from "@hookform/resolvers/zod"
import { Eye, EyeOff, Shield, AlertCircle } from "lucide-react"
import { z } from "zod"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card"
import { getSupabaseBrowserClient } from "@/lib/supabase"

const schema = z
  .object({
    nueva_contrasena: z
      .string()
      .min(8, "La contraseña debe tener al menos 8 caracteres"),
    confirmar_contrasena: z.string(),
  })
  .refine((d) => d.nueva_contrasena === d.confirmar_contrasena, {
    message: "Las contraseñas no coinciden.",
    path: ["confirmar_contrasena"],
  })

type FormInput = z.infer<typeof schema>

export default function RestablecerContrasenaPage() {
  const router = useRouter()
  const [showPassword, setShowPassword] = useState(false)
  const [showConfirm, setShowConfirm] = useState(false)
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

    const supabase = getSupabaseBrowserClient()
    const { error: updateError } = await supabase.auth.updateUser({
      password: data.nueva_contrasena,
    })

    setIsLoading(false)

    if (updateError) {
      if (updateError.message.includes("session") || updateError.message.includes("Auth")) {
        setError("El enlace de recuperación ha expirado. Solicita uno nuevo.")
      } else if (updateError.message.includes("same password")) {
        setError("La nueva contraseña no puede ser igual a la contraseña actual.")
      } else {
        setError("No se pudo actualizar la contraseña. Intenta de nuevo.")
      }
      setIsLoading(false)
      return
    }

    // Cerrar sesión para que el login muestre el banner de confirmación
    await supabase.auth.signOut()
    router.push("/login?recuperado=1")
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
          <CardTitle className="text-xl">Nueva contraseña</CardTitle>
          <CardDescription>
            Elige una contraseña segura de al menos 8 caracteres.
          </CardDescription>
        </CardHeader>
        <CardContent>
          <form onSubmit={handleSubmit(onSubmit)} className="space-y-4">
            <div className="space-y-1.5">
              <Label htmlFor="nueva_contrasena">Nueva contraseña</Label>
              <div className="relative">
                <Input
                  id="nueva_contrasena"
                  type={showPassword ? "text" : "password"}
                  placeholder="••••••••••"
                  autoComplete="new-password"
                  {...register("nueva_contrasena")}
                />
                <button
                  type="button"
                  onClick={() => setShowPassword((v) => !v)}
                  className="absolute right-3 top-1/2 -translate-y-1/2 text-muted-foreground hover:text-foreground transition-colors"
                  tabIndex={-1}
                >
                  {showPassword ? <EyeOff className="h-4 w-4" /> : <Eye className="h-4 w-4" />}
                </button>
              </div>
              {errors.nueva_contrasena && (
                <p className="text-xs text-destructive">{errors.nueva_contrasena.message}</p>
              )}
            </div>

            <div className="space-y-1.5">
              <Label htmlFor="confirmar_contrasena">Confirmar contraseña</Label>
              <div className="relative">
                <Input
                  id="confirmar_contrasena"
                  type={showConfirm ? "text" : "password"}
                  placeholder="••••••••••"
                  autoComplete="new-password"
                  {...register("confirmar_contrasena")}
                />
                <button
                  type="button"
                  onClick={() => setShowConfirm((v) => !v)}
                  className="absolute right-3 top-1/2 -translate-y-1/2 text-muted-foreground hover:text-foreground transition-colors"
                  tabIndex={-1}
                >
                  {showConfirm ? <EyeOff className="h-4 w-4" /> : <Eye className="h-4 w-4" />}
                </button>
              </div>
              {errors.confirmar_contrasena && (
                <p className="text-xs text-destructive">{errors.confirmar_contrasena.message}</p>
              )}
            </div>

            {error && (
              <div className="flex items-start gap-2 rounded-md bg-destructive/10 px-3 py-2.5 text-sm text-destructive">
                <AlertCircle className="mt-0.5 h-4 w-4 shrink-0" />
                <span>{error}</span>
              </div>
            )}

            <Button type="submit" className="w-full" disabled={isLoading}>
              {isLoading ? "Guardando..." : "Guardar nueva contraseña"}
            </Button>

            <p className="text-center text-sm text-muted-foreground">
              <Link href="/recuperar-contrasena" className="underline hover:text-foreground">
                Solicitar nuevo enlace
              </Link>
            </p>
          </form>
        </CardContent>
      </Card>
    </div>
  )
}
