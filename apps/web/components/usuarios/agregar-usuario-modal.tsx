"use client"

import { useState } from "react"
import { useForm } from "react-hook-form"
import { zodResolver } from "@hookform/resolvers/zod"
import { z } from "zod"
import { SlideOver } from "@/components/ui/slide-over"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { api } from "@/lib/api"

const ramosDisponibles = [
  { value: "vida", label: "Vida" },
  { value: "gmm", label: "GMM" },
  { value: "autos", label: "Autos" },
  { value: "pyme", label: "Pyme" },
]

const rolesPorRango: Record<string, { value: string; label: string }[]> = {
  director_general: [
    { value: "director_ops", label: "Director de Operaciones" },
    { value: "gerente", label: "Gerente" },
    { value: "analista", label: "Analista" },
  ],
  director_ops: [
    { value: "gerente", label: "Gerente" },
    { value: "analista", label: "Analista" },
  ],
  gerente: [
    { value: "analista", label: "Analista" },
  ],
}

const usuarioSchema = z.object({
  nombre: z.string().min(2, "Nombre requerido (mínimo 2 caracteres)").max(150),
  email: z.string().email("Correo inválido"),
  password: z.string().min(12, "La contraseña debe tener al menos 12 caracteres").max(128),
  rol: z.enum(["director_ops", "gerente", "analista"], {
    required_error: "Selecciona un rol",
  }),
  ramo: z.string().optional(),
  ramos_adicionales: z.array(z.enum(["vida", "gmm", "autos", "pyme"])).optional(),
  telefono: z.string().max(20).optional(),
})

type UsuarioForm = z.infer<typeof usuarioSchema>

interface Props {
  open: boolean
  onClose: () => void
  onSuccess: () => void
  rolCreador: string
  ramoCreador?: string | null
}

export function AgregarUsuarioModal({ open, onClose, onSuccess, rolCreador, ramoCreador }: Props) {
  const [isSubmitting, setIsSubmitting] = useState(false)
  const [serverError, setServerError] = useState<string | null>(null)
  const [created, setCreated] = useState<string | null>(null)

  const rolesAsignables = rolesPorRango[rolCreador] ?? []

  const {
    register,
    handleSubmit,
    reset,
    watch,
    setValue,
    formState: { errors },
  } = useForm<UsuarioForm>({
    resolver: zodResolver(usuarioSchema),
    defaultValues: {
      nombre: "",
      email: "",
      password: "",
      rol: undefined,
      ramo: "",
      ramos_adicionales: [],
      telefono: "",
    },
  })

  const rolSeleccionado = watch("rol")
  const ramosAdicionalesSeleccionados = watch("ramos_adicionales") ?? []
  const requiereRamo = rolSeleccionado === "gerente" || rolSeleccionado === "analista"

  function toggleRamoAdicional(ramo: string) {
    const current = ramosAdicionalesSeleccionados as string[]
    if (current.includes(ramo)) {
      setValue(
        "ramos_adicionales",
        current.filter((r) => r !== ramo) as ("vida" | "gmm" | "autos" | "pyme")[],
        { shouldValidate: true }
      )
    } else {
      setValue(
        "ramos_adicionales",
        [...current, ramo] as ("vida" | "gmm" | "autos" | "pyme")[],
        { shouldValidate: true }
      )
    }
  }

  async function onSubmit(data: UsuarioForm) {
    setIsSubmitting(true)
    setServerError(null)

    try {
      const payload: Record<string, unknown> = {
        nombre: data.nombre.trim(),
        email: data.email.trim().toLowerCase(),
        password: data.password,
        rol: data.rol,
      }

      if (data.ramo && data.ramo !== "") {
        payload.ramo = data.ramo
      }

      if (data.ramos_adicionales && data.ramos_adicionales.length > 0) {
        payload.ramos_adicionales = data.ramos_adicionales as string[]
      }
      if (data.telefono) {
        payload.telefono = data.telefono.trim()
      }

      const res = await api.post<{ id?: string; email?: string }>("/usuarios", payload)
      setCreated(res.email ?? data.email)
      setTimeout(() => {
        reset()
        onSuccess()
        onClose()
      }, 1500)
    } catch (err: unknown) {
      setServerError((err as Error).message)
    } finally {
      setIsSubmitting(false)
    }
  }

  function handleClose() {
    reset()
    setCreated(null)
    setServerError(null)
    onClose()
  }

  return (
    <SlideOver open={open} onClose={handleClose} title="Agregar usuario">
      {created ? (
        <div className="flex flex-col items-center justify-center gap-4 py-12 text-center">
          <div className="flex h-14 w-14 items-center justify-center rounded-full bg-emerald-50">
            <svg className="h-7 w-7 text-emerald-600" fill="none" viewBox="0 0 24 24" stroke="currentColor">
              <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M5 13l4 4L19 7" />
            </svg>
          </div>
          <div>
            <p className="text-base font-semibold text-slate-900">Usuario creado</p>
            <p className="mt-1 text-sm text-slate-500">
              {created} ha sido dado de alta correctamente.
            </p>
            <p className="mt-1 text-xs text-slate-400">
              La contraseña fue enviada al correo proporcionado.
            </p>
          </div>
          <Button onClick={handleClose} variant="outline" className="mt-2">Cerrar</Button>
        </div>
      ) : (
        <form onSubmit={handleSubmit(onSubmit)} className="flex flex-col gap-5">
          <div className="space-y-1.5">
            <Label htmlFor="nombre">Nombre completo *</Label>
            <Input id="nombre" placeholder="Juan Pérez García" {...register("nombre")} />
            {errors.nombre && <p className="text-xs text-destructive">{errors.nombre.message}</p>}
          </div>

          <div className="space-y-1.5">
            <Label htmlFor="email">Correo electrónico *</Label>
            <Input id="email" type="email" placeholder="juan@empresa.com" {...register("email")} />
            {errors.email && <p className="text-xs text-destructive">{errors.email.message}</p>}
          </div>

          <div className="space-y-1.5">
            <Label htmlFor="password">Contraseña *</Label>
            <Input id="password" type="password" placeholder="Mínimo 8 caracteres" {...register("password")} />
            {errors.password && <p className="text-xs text-destructive">{errors.password.message}</p>}
          </div>

          <div className="space-y-1.5">
            <Label htmlFor="rol">Rol *</Label>
            <select
              id="rol"
              {...register("rol")}
              className="flex h-10 w-full rounded-md border border-input bg-white px-3 py-2 text-sm ring-offset-background placeholder:text-muted-foreground focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2 disabled:cursor-not-allowed disabled:opacity-50"
            >
              <option value="">Seleccionar rol</option>
              {rolesAsignables.map((r) => (
                <option key={r.value} value={r.value}>{r.label}</option>
              ))}
            </select>
            {errors.rol && <p className="text-xs text-destructive">{errors.rol.message}</p>}
          </div>

          {requiereRamo && (
            <>
              <div className="space-y-1.5">
                <Label htmlFor="ramo">Ramo principal *</Label>
                <select
                  id="ramo"
                  {...register("ramo")}
                  className="flex h-10 w-full rounded-md border border-input bg-white px-3 py-2 text-sm ring-offset-background placeholder:text-muted-foreground focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2 disabled:cursor-not-allowed disabled:opacity-50"
                >
                  <option value="">Seleccionar ramo principal</option>
                  {ramosDisponibles.map((r) => (
                    <option key={r.value} value={r.value}>{r.label}</option>
                  ))}
                </select>
                {errors.ramo && <p className="text-xs text-destructive">{errors.ramo.message}</p>}
              </div>

              <div className="space-y-2">
                <Label>Ramos adicionales (opcional)</Label>
                <p className="text-xs text-slate-500">Selecciona ramos adicionales en los que el usuario también tendrá acceso.</p>
                <div className="flex flex-wrap gap-2">
                  {ramosDisponibles.map((ramo) => {
                    const selected = ramosAdicionalesSeleccionados.includes(ramo.value as "vida" | "gmm" | "autos" | "pyme")
                    const principal = watch("ramo")
                    const disabled = principal === ramo.value
                    return (
                      <button
                        key={ramo.value}
                        type="button"
                        disabled={disabled}
                        onClick={() => toggleRamoAdicional(ramo.value)}
                        className={`inline-flex items-center gap-1.5 rounded-full px-3 py-1.5 text-xs font-medium transition-colors ${
                          disabled
                            ? "bg-slate-100 text-slate-400 cursor-not-allowed"
                            : selected
                            ? "bg-blue-100 text-blue-700 border border-blue-300"
                            : "bg-slate-50 text-slate-600 border border-slate-200 hover:bg-slate-100"
                        }`}
                      >
                        {selected && !disabled && (
                          <svg className="h-3 w-3" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                            <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M5 13l4 4L19 7" />
                          </svg>
                        )}
                        {ramo.label}
                        {disabled && <span className="text-slate-400">(principal)</span>}
                      </button>
                    )
                  })}
                </div>
              </div>
            </>
          )}

          <div className="space-y-1.5">
            <Label htmlFor="telefono">Teléfono</Label>
            <Input id="telefono" placeholder="55 1234 5678" {...register("telefono")} />
            {errors.telefono && <p className="text-xs text-destructive">{errors.telefono.message}</p>}
          </div>

          {serverError && (
            <div className="rounded-md bg-destructive/10 px-3 py-2 text-sm text-destructive">
              {serverError}
            </div>
          )}

          <div className="flex gap-3 pt-2">
            <Button type="button" variant="outline" onClick={handleClose} className="flex-1">
              Cancelar
            </Button>
            <Button type="submit" disabled={isSubmitting} className="flex-1">
              {isSubmitting ? "Guardando..." : "Crear usuario"}
            </Button>
          </div>
        </form>
      )}
    </SlideOver>
  )
}