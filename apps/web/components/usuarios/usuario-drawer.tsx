"use client"

import { useForm } from "react-hook-form"
import { zodResolver } from "@hookform/resolvers/zod"
import { z } from "zod"
import { SlideOver } from "@/components/ui/slide-over"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { api } from "@/lib/api"
import type { UsuarioRow } from "./usuarios-tabla"
import { useState } from "react"

const ramosDisponibles = [
  { value: "vida", label: "Vida" },
  { value: "gmm", label: "GMM" },
  { value: "autos", label: "Autos" },
  { value: "pyme", label: "Pyme" },
]

const editSchema = z.object({
  nombre: z.string().min(2, "Nombre requerido").max(150),
  telefono: z.string().max(20).optional(),
  ramos_adicionales: z.array(z.enum(["vida", "gmm", "autos", "pyme"])).optional(),
})

type EditForm = z.infer<typeof editSchema>

interface Props {
  row: UsuarioRow | null
  open: boolean
  onClose: () => void
  onUpdated: () => void
  puedeEditar?: boolean
}

export function UsuarioDrawer({ row, open, onClose, onUpdated, puedeEditar }: Props) {
  const [saving, setSaving] = useState(false)

  const {
    register,
    handleSubmit,
    reset,
    watch,
    setValue,
    formState: { errors, isDirty },
  } = useForm<EditForm>({
    resolver: zodResolver(editSchema),
    defaultValues: {
      nombre: row?.nombre ?? "",
      telefono: row?.telefono ?? "",
      ramos_adicionales: (row?.ramos_adicionales as ("vida" | "gmm" | "autos" | "pyme")[]) ?? [],
    },
  })

  const ramosAdicionalesSeleccionados = watch("ramos_adicionales") ?? []

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

  function handleOpenChange(open: boolean) {
    if (!open) {
      reset()
      onClose()
    }
  }

  async function onSubmit(data: EditForm) {
    if (!row) return
    setSaving(true)
    try {
      const payload: Record<string, unknown> = {
        nombre: data.nombre.trim(),
        telefono: data.telefono?.trim() || undefined,
      }
      if (data.ramos_adicionales !== undefined) {
        payload.ramos_adicionales = data.ramos_adicionales
      }
      await api.patch(`/usuarios/${row.id}`, payload)
      onUpdated()
      onClose()
    } catch (err: unknown) {
      alert((err as Error).message)
    } finally {
      setSaving(false)
    }
  }

  const ROL_LABELS: Record<string, string> = {
    director_general: "Director General",
    director_ops: "Director de Operaciones",
    gerente: "Gerente",
    analista: "Analista",
  }

  return (
    <SlideOver open={open} onClose={() => handleOpenChange(false)} title="Detalle del usuario">
      {row && (
        <div className="flex flex-col gap-6">
          <div className="flex items-center gap-4">
            <div className="flex h-14 w-14 items-center justify-center rounded-full bg-slate-100 text-base font-semibold text-slate-600">
              {row.nombre.split(" ").slice(0, 2).map((p) => p[0]?.toUpperCase() ?? "").join("")}
            </div>
            <div>
              <h3 className="text-base font-semibold text-slate-900">{row.nombre}</h3>
              <p className="text-sm text-slate-500">{row.email}</p>
              <p className="text-xs text-slate-400 mt-0.5">
                {row.activo ? (
                  <span className="text-emerald-600">Activo</span>
                ) : (
                  <span className="text-red-600">Inactivo</span>
                )}
              </p>
            </div>
          </div>

          <div className="grid grid-cols-2 gap-4 rounded-lg border bg-slate-50 p-4">
            <div>
              <p className="text-xs text-slate-500 uppercase tracking-wide">Rol</p>
              <p className="mt-0.5 text-sm font-medium text-slate-900">{ROL_LABELS[row.rol] ?? row.rol}</p>
            </div>
            {row.ramo && (
              <div>
                <p className="text-xs text-slate-500 uppercase tracking-wide">Ramo{row.ramos_adicionales?.length ? "s" : ""}</p>
                <div className="flex flex-wrap gap-1 mt-0.5">
                  <span className="inline-flex items-center rounded bg-violet-100 text-violet-700 px-2 py-0.5 text-xs font-medium capitalize">
                    {row.ramo}
                  </span>
                  {row.ramos_adicionales?.map((r) => (
                    <span key={r} className="inline-flex items-center rounded bg-slate-100 text-slate-600 px-2 py-0.5 text-xs font-medium capitalize">
                      {r}
                    </span>
                  ))}
                </div>
              </div>
            )}
          </div>

          {puedeEditar && row.rol !== "director_general" && row.rol !== "director_ops" && (
            <>
              <div className="space-y-2">
                <Label>Ramos adicionales (opcional)</Label>
                <div className="flex flex-wrap gap-2">
                  {ramosDisponibles
                    .filter((r) => r.value !== row.ramo)
                    .map((ramo) => {
                      const selected = ramosAdicionalesSeleccionados.includes(ramo.value as "vida" | "gmm" | "autos" | "pyme")
                      return (
                        <button
                          key={ramo.value}
                          type="button"
                          onClick={() => toggleRamoAdicional(ramo.value)}
                          className={`inline-flex items-center gap-1.5 rounded-full px-3 py-1.5 text-xs font-medium transition-colors ${
                            selected
                              ? "bg-blue-100 text-blue-700 border border-blue-300"
                              : "bg-slate-50 text-slate-600 border border-slate-200 hover:bg-slate-100"
                          }`}
                        >
                          {selected && (
                            <svg className="h-3 w-3" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                              <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M5 13l4 4L19 7" />
                            </svg>
                          )}
                          {ramo.label}
                        </button>
                      )
                    })}
                </div>
              </div>

              <form onSubmit={handleSubmit(onSubmit)} className="flex flex-col gap-4">
                <div className="space-y-1.5">
                  <Label htmlFor="nombre">Nombre completo</Label>
                  <Input id="nombre" {...register("nombre")} />
                  {errors.nombre && <p className="text-xs text-destructive">{errors.nombre.message}</p>}
                </div>

                <div className="space-y-1.5">
                  <Label htmlFor="telefono">Teléfono</Label>
                  <Input id="telefono" {...register("telefono")} />
                  {errors.telefono && <p className="text-xs text-destructive">{errors.telefono.message}</p>}
                </div>

                <div className="flex gap-3 pt-2">
                  <Button type="button" variant="outline" onClick={() => handleOpenChange(false)} className="flex-1">
                    Cancelar
                  </Button>
                  <Button type="submit" disabled={!isDirty || saving} className="flex-1">
                    {saving ? "Guardando..." : "Guardar cambios"}
                  </Button>
                </div>
              </form>
            </>
          )}
        </div>
      )}
    </SlideOver>
  )
}