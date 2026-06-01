"use client"

import { useState } from "react"
import { useForm } from "react-hook-form"
import { zodResolver } from "@hookform/resolvers/zod"
import { z } from "zod"
import { Phone, MessageCircle, Users, CheckSquare } from "lucide-react"
import { SlideOver } from "@/components/ui/slide-over"
import { Button } from "@/components/ui/button"
import { Label } from "@/components/ui/label"
import type { TramiteSearchItem, AgenteSearchItem } from "@/hooks/use-busqueda"
import type { Medio } from "@/hooks/use-comunicacion"

const comunicacionSchema = z.object({
  nota: z.string().min(1, "La nota es requerida").max(2000),
  medio: z.enum(["whatsapp", "telefono", "presencial"]),
  comunicacion_entrante: z.boolean(),
  requiere_seguimiento: z.boolean(),
})

type ComunicacionForm = z.infer<typeof comunicacionSchema>

interface QuickCommunicationFormProps {
  open: boolean
  onClose: () => void
  tramite?: TramiteSearchItem | null
  agente?: AgenteSearchItem | null
  onSuccess?: () => void
}

const medioOptions: { value: Medio; label: string; icon: React.ElementType }[] = [
  { value: "whatsapp", label: "WhatsApp", icon: MessageCircle },
  { value: "telefono", label: "Teléfono", icon: Phone },
  { value: "presencial", label: "Presencial", icon: Users },
]

export function QuickCommunicationForm({
  open,
  onClose,
  tramite,
  agente,
  onSuccess,
}: QuickCommunicationFormProps) {
  const [isSubmitting, setIsSubmitting] = useState(false)
  const [serverError, setServerError] = useState<string | null>(null)

  const {
    register,
    handleSubmit,
    watch,
    setValue,
    reset,
    formState: { errors },
  } = useForm<ComunicacionForm>({
    resolver: zodResolver(comunicacionSchema),
    defaultValues: {
      medio: "whatsapp",
      comunicacion_entrante: true,
      requiere_seguimiento: false,
      nota: "",
    },
  })

  const selectedMedio = watch("medio")

  async function onSubmit(data: ComunicacionForm) {
    setIsSubmitting(true)
    setServerError(null)

    try {
      const res = await fetch("/api/comunicaciones", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          ...data,
          tramite_id: tramite?.id,
          agente_id: agente?.id,
        }),
      })

      if (!res.ok) {
        const body = await res.json().catch(() => ({}))
        throw new Error((body as { detail?: string }).detail ?? "Error al guardar")
      }

      reset()
      onSuccess?.()
      onClose()
    } catch (err: unknown) {
      setServerError((err as Error).message)
    } finally {
      setIsSubmitting(false)
    }
  }

  return (
    <SlideOver
      open={open}
      onClose={onClose}
      title="Agregar comunicación"
    >
      <form onSubmit={handleSubmit(onSubmit)} className="flex flex-col gap-5">
        {/* Medio */}
        <div className="space-y-1.5">
          <Label>Medio de contacto</Label>
          <div className="flex gap-2">
            {medioOptions.map((opt) => {
              const Icon = opt.icon
              const isActive = selectedMedio === opt.value
              return (
                <button
                  key={opt.value}
                  type="button"
                  onClick={() => setValue("medio", opt.value)}
                  className={`flex flex-1 flex-col items-center gap-1.5 rounded-lg border py-3 text-xs font-medium transition-all ${
                    isActive
                      ? "border-slate-900 bg-slate-900 text-white"
                      : "border-slate-200 text-slate-600 hover:border-slate-300 hover:bg-slate-50"
                  }`}
                >
                  <Icon className="h-4 w-4" />
                  {opt.label}
                </button>
              )
            })}
          </div>
        </div>

        {/* ¿Comunicación entrante? */}
        <div className="flex items-center gap-3">
          <button
            type="button"
            role="switch"
            aria-checked={watch("comunicacion_entrante")}
            onClick={() => setValue("comunicacion_entrante", !watch("comunicacion_entrante"))}
            className={`relative inline-flex h-5 w-9 items-center rounded-full transition-colors ${
              watch("comunicacion_entrante") ? "bg-slate-900" : "bg-slate-200"
            }`}
          >
            <span
              className={`inline-block h-3.5 w-3.5 transform rounded-full bg-white shadow transition-transform ${
                watch("comunicacion_entrante") ? "translate-x-4" : "translate-x-1"
              }`}
            />
          </button>
          <Label className="cursor-pointer text-sm">
            {watch("comunicacion_entrante")
              ? "📥 El agente contactó al analista"
              : "📤 El analistainitió el contacto"}
          </Label>
        </div>

        {/* Nota */}
        <div className="space-y-1.5">
          <Label htmlFor="nota">Nota</Label>
          <textarea
            id="nota"
            rows={4}
            placeholder="¿De qué se platicó? Resumen breve del contacto..."
            className="flex w-full rounded-md border border-input bg-white px-3 py-2 text-sm ring-offset-background placeholder:text-muted-foreground focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2 disabled:cursor-not-allowed disabled:opacity-50 resize-none"
            {...register("nota")}
          />
          {errors.nota && (
            <p className="text-xs text-destructive">{errors.nota.message}</p>
          )}
          <p className="text-xs text-muted-foreground text-right">
            {watch("nota")?.length ?? 0}/2000
          </p>
        </div>

        {/* Requiere seguimiento */}
        <div className="flex items-center gap-3">
          <input
            type="checkbox"
            id="requiere_seguimiento"
            className="h-4 w-4 rounded border-slate-300 text-slate-900 focus:ring-slate-900"
            {...register("requiere_seguimiento")}
          />
          <Label htmlFor="requiere_seguimiento" className="text-sm cursor-pointer">
            <CheckSquare className="inline h-3.5 w-3.5 mr-1 text-amber-500" />
            Requiere seguimiento
          </Label>
        </div>

        {/* Contexto: trámite o agente */}
        {(tramite || agente) && (
          <div className="rounded-lg border bg-slate-50 p-3 space-y-1">
            <p className="text-xs font-medium text-muted-foreground uppercase tracking-wide">
              Vinculado a
            </p>
            {tramite && (
              <p className="text-sm font-medium text-slate-900">
                📋 {tramite.folio} — {tramite.titulo}
              </p>
            )}
            {agente && (
              <p className="text-sm font-medium text-slate-900">
                👤 {agente.nombre}
                {agente.cua && <span className="text-muted-foreground ml-1">· CUA {agente.cua}</span>}
              </p>
            )}
          </div>
        )}

        {serverError && (
          <div className="rounded-md bg-destructive/10 px-3 py-2 text-sm text-destructive">
            {serverError}
          </div>
        )}

        {/* Actions */}
        <div className="flex gap-3 pt-2">
          <Button type="button" variant="outline" onClick={onClose} className="flex-1">
            Cancelar
          </Button>
          <Button type="submit" className="flex-1" disabled={isSubmitting}>
            {isSubmitting ? "Guardando..." : "Guardar"}
          </Button>
        </div>
      </form>
    </SlideOver>
  )
}
