"use client"

import { AlertTriangle } from "lucide-react"
import { Badge } from "@/components/ui/badge"
import { cn } from "@/lib/utils"
import { ESTADO_BADGE, TIPO_BADGE, PRIORIDAD_BADGE, RAMO_BADGE } from "../shared"
import type { TramiteDetalle } from "../types"

interface TramiteHeaderProps {
  tramite: TramiteDetalle
}

export function TramiteHeader({ tramite }: TramiteHeaderProps) {
  const estado = ESTADO_BADGE[tramite.estado]
  const tipo = TIPO_BADGE[tramite.tipo_tramite]
  const prioridad = PRIORIDAD_BADGE[tramite.prioridad]
  const ramo = tramite.ramo ? RAMO_BADGE[tramite.ramo] : null

  return (
    <div className="border-b bg-white px-6 py-4">
      <div className="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
        {/* Folio + OT + título */}
        <div className="min-w-0 flex-1">
          <div className="flex flex-wrap items-center gap-2">
            <h1 className="font-mono text-xl font-bold text-slate-900">{tramite.folio}</h1>
            {tramite.folio_ot && (
              <span className="rounded bg-violet-100 px-2 py-0.5 text-xs font-semibold text-violet-700">
                OT {tramite.folio_ot}
              </span>
            )}
            {tramite.requiere_atencion && (
              <span className="flex items-center gap-1 rounded bg-red-100 px-2 py-0.5 text-xs font-semibold text-red-700">
                <AlertTriangle className="h-3 w-3" />
                Requiere atención
              </span>
            )}
          </div>
          <p className="mt-1 text-sm text-slate-600 line-clamp-2">{tramite.titulo}</p>
        </div>

        {/* Badges de clasificación */}
        <div className="flex flex-wrap items-center gap-1.5 sm:shrink-0">
          {estado && <Badge variant={estado.variant}>{estado.label}</Badge>}
          {ramo && <Badge variant={ramo.variant}>{ramo.label}</Badge>}
          {tipo && <Badge variant={tipo.variant}>{tipo.label}</Badge>}
          {prioridad && prioridad.label !== "Normal" && (
            <Badge variant={prioridad.variant}>{prioridad.label}</Badge>
          )}
        </div>
      </div>

      {/* Etiquetas */}
      {tramite.etiquetas.length > 0 && (
        <div className="mt-2 flex flex-wrap gap-1.5">
          {tramite.etiquetas.map((tag) => (
            <span
              key={tag}
              className="rounded-full border border-slate-200 bg-slate-50 px-2 py-0.5 text-[11px] font-medium text-slate-600"
            >
              {tag}
            </span>
          ))}
        </div>
      )}

      {/* Advertencia de rechazo GNP */}
      {tramite.estado === "rechazado_gnp" && tramite.motivo_rechazo_gnp && (
        <div className={cn("mt-3 rounded-lg border border-red-200 bg-red-50 px-4 py-2.5")}>
          <p className="text-xs font-semibold text-red-700">Motivo de rechazo GNP</p>
          <p className="mt-0.5 text-sm text-red-600">{tramite.motivo_rechazo_gnp}</p>
        </div>
      )}
    </div>
  )
}
