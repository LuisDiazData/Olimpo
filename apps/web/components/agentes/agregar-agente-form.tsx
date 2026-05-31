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

const agenteSchema = z.object({
  cua:            z.string().min(1, "CUA es requerido").max(20),
  nombre:         z.string().min(2, "Nombre requerido (mínimo 2 caracteres)").max(150),
  nombre_comercial: z.string().max(150).optional(),
  rfc:            z.string().max(13).optional(),
  fecha_afiliacion: z.string().optional(),
  email:           z.string().email("Correo inválido").optional().or(z.literal("")),
  telefono:        z.string().max(20).optional(),
  notas:           z.string().max(2000).optional(),
})

type AgenteForm = z.infer<typeof agenteSchema>

interface Props {
  open: boolean
  onClose: () => void
  onSuccess: () => void
}

export function AgregarAgenteForm({ open, onClose, onSuccess }: Props) {
  const [isSubmitting, setIsSubmitting] = useState(false)
  const [serverError, setServerError] = useState<string | null>(null)
  const [created, setCreated] = useState<string | null>(null)

  const {
    register,
    handleSubmit,
    reset,
    formState: { errors },
  } = useForm<AgenteForm>({
    resolver: zodResolver(agenteSchema),
    defaultValues: {
      nombre_comercial: "",
      rfc: "",
      fecha_afiliacion: "",
      email: "",
      telefono: "",
      notas: "",
    },
  })

  async function onSubmit(data: AgenteForm) {
    setIsSubmitting(true)
    setServerError(null)

    try {
      const payload: Record<string, unknown> = {
        cua: data.cua.trim().toUpperCase(),
        nombre: data.nombre.trim(),
      }
      if (data.nombre_comercial) payload.nombre_comercial = data.nombre_comercial.trim()
      if (data.rfc)               payload.rfc               = data.rfc.trim().toUpperCase()
      if (data.fecha_afiliacion)  payload.fecha_afiliacion  = data.fecha_afiliacion
      if (data.notas)             payload.notas             = data.notas.trim()

      const res = await api.post<{ id?: string }>("/agentes", payload)
      const agenteId = res.id

      if (agenteId && data.email) {
        await api.post(`/agentes/${agenteId}/emails`, { email: data.email, preferente: true })
      }
      if (agenteId && data.telefono) {
        await api.post(`/agentes/${agenteId}/telefonos`, { numero: data.telefono, tipo: "celular", preferente: true })
      }

      setCreated(agenteId ?? data.cua)
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
    <SlideOver open={open} onClose={handleClose} title="Agregar agente">
      {created ? (
        <div className="flex flex-col items-center justify-center gap-4 py-12 text-center">
          <div className="flex h-14 w-14 items-center justify-center rounded-full bg-emerald-50">
            <svg className="h-7 w-7 text-emerald-600" fill="none" viewBox="0 0 24 24" stroke="currentColor">
              <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M5 13l4 4L19 7" />
            </svg>
          </div>
          <div>
            <p className="text-base font-semibold text-slate-900">Agente registrado</p>
            <p className="mt-1 text-sm text-slate-500">CUA {created} agregado correctamente.</p>
          </div>
          <Button onClick={handleClose} variant="outline" className="mt-2">Cerrar</Button>
        </div>
      ) : (
        <form onSubmit={handleSubmit(onSubmit)} className="flex flex-col gap-5">
          <div className="space-y-1.5">
            <Label htmlFor="cua">CUA *</Label>
            <Input
              id="cua"
              placeholder="A000123456"
              {...register("cua")}
              className="uppercase"
            />
            {errors.cua && <p className="text-xs text-destructive">{errors.cua.message}</p>}
          </div>

          <div className="space-y-1.5">
            <Label htmlFor="nombre">Nombre completo *</Label>
            <Input id="nombre" placeholder="Juan Pérez García" {...register("nombre")} />
            {errors.nombre && <p className="text-xs text-destructive">{errors.nombre.message}</p>}
          </div>

          <div className="space-y-1.5">
            <Label htmlFor="nombre_comercial">Nombre comercial</Label>
            <Input id="nombre_comercial" placeholder="Agencia JP" {...register("nombre_comercial")} />
          </div>

          <div className="grid grid-cols-2 gap-3">
            <div className="space-y-1.5">
              <Label htmlFor="rfc">RFC</Label>
              <Input id="rfc" placeholder="PEGJ800101ABC" {...register("rfc")} className="uppercase" />
              {errors.rfc && <p className="text-xs text-destructive">{errors.rfc.message}</p>}
            </div>
            <div className="space-y-1.5">
              <Label htmlFor="fecha_afiliacion">Fecha de afiliación</Label>
              <Input id="fecha_afiliacion" type="date" {...register("fecha_afiliacion")} />
            </div>
          </div>

          <div className="grid grid-cols-2 gap-3">
            <div className="space-y-1.5">
              <Label htmlFor="email">Correo electrónico</Label>
              <Input id="email" type="email" placeholder="juan@email.com" {...register("email")} />
              {errors.email && <p className="text-xs text-destructive">{errors.email.message}</p>}
            </div>
            <div className="space-y-1.5">
              <Label htmlFor="telefono">Teléfono</Label>
              <Input id="telefono" placeholder="55 1234 5678" {...register("telefono")} />
            </div>
          </div>

          <div className="space-y-1.5">
            <Label htmlFor="notas">Notas</Label>
            <textarea
              id="notas"
              rows={3}
              className="flex w-full rounded-md border border-input bg-white px-3 py-2 text-sm ring-offset-background placeholder:text-muted-foreground focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2 resize-none"
              {...register("notas")}
            />
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
              {isSubmitting ? "Guardando..." : "Guardar agente"}
            </Button>
          </div>
        </form>
      )}
    </SlideOver>
  )
}
