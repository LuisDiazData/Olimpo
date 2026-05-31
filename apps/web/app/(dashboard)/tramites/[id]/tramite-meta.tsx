import { Building2, Calendar, FileText, Mail, Shield, User, CircleDot } from "lucide-react"
import { cn } from "@/lib/utils"
import { Badge } from "@/components/ui/badge"
import { formatFechaCorta, ESTADO_BADGE } from "../shared"
import type { TramiteDetalle } from "../types"

interface TramiteMetaProps {
  tramite: TramiteDetalle
}

function MetaRow({
  icon: Icon,
  label,
  value,
  mono = false,
  className,
}: {
  icon: React.ElementType
  label: string
  value: React.ReactNode
  mono?: boolean
  className?: string
}) {
  return (
    <div className={cn("flex items-start gap-3 py-2.5", className)}>
      <Icon className="mt-0.5 h-4 w-4 shrink-0 text-slate-400" />
      <div className="min-w-0 flex-1">
        <p className="text-[10px] font-semibold uppercase tracking-wider text-slate-400">{label}</p>
        <p className={cn("mt-0.5 text-sm text-slate-800 break-words", mono && "font-mono")}>
          {value || <span className="italic text-slate-400">—</span>}
        </p>
      </div>
    </div>
  )
}

function SlaBar({ tramite }: { tramite: TramiteDetalle }) {
  const colorClass = {
    verde: "bg-emerald-500",
    amarillo: "bg-amber-500",
    rojo: "bg-red-500",
  }[tramite.riesgo_sla]

  const textClass = {
    verde: "text-emerald-700",
    amarillo: "text-amber-700",
    rojo: "text-red-700",
  }[tramite.riesgo_sla]

  const dias = Math.floor(
    (Date.now() - new Date(tramite.fecha_recepcion).getTime()) / 86_400_000
  )

  return (
    <div className="space-y-2 py-3">
      <div className="flex items-center justify-between text-xs">
        <span className="font-semibold text-slate-500">SLA</span>
        {tramite.fecha_limite_sla ? (
          <span className={cn("font-semibold", textClass)}>
            {new Date(tramite.fecha_limite_sla) < new Date() ? "Vencido" : "Activo"}
          </span>
        ) : (
          <span className="text-slate-400">Sin límite</span>
        )}
      </div>
      <div className="h-1.5 rounded-full bg-slate-100">
        <div className={cn("h-full rounded-full transition-all", colorClass)} style={{ width: "60%" }} />
      </div>
      <div className="flex justify-between text-[11px] text-slate-500">
        <span>{dias} {dias === 1 ? "día" : "días"} transcurridos</span>
        {tramite.fecha_limite_sla && (
          <span>Límite: {formatFechaCorta(tramite.fecha_limite_sla).split(",")[0]}</span>
        )}
      </div>
    </div>
  )
}

export function TramiteMeta({ tramite }: TramiteMetaProps) {
  return (
    <div className="divide-y divide-slate-100 px-4">
      {/* Datos del trámite */}
      <div className="py-2">
        <p className="mb-1 text-[10px] font-bold uppercase tracking-widest text-slate-400">
          Datos del trámite
        </p>
        <MetaRow icon={User} label="Asegurado" value={tramite.asegurado_nombre} />
        <MetaRow
          icon={FileText}
          label="Póliza"
          value={tramite.poliza_numero}
          mono
        />
        <MetaRow
          icon={Shield}
          label="Ramo"
          value={tramite.ramo ? tramite.ramo.charAt(0).toUpperCase() + tramite.ramo.slice(1) : null}
        />

        {/* Estado */}
        <div className="flex items-start gap-3 py-2.5">
          <CircleDot className="mt-0.5 h-4 w-4 shrink-0 text-slate-400" />
          <div className="min-w-0 flex-1">
            <p className="text-[10px] font-semibold uppercase tracking-wider text-slate-400">Estado</p>
            <div className="mt-0.5">
              {(() => {
                const e = ESTADO_BADGE[tramite.estado]
                return e ? (
                  <Badge variant={e.variant}>{e.label}</Badge>
                ) : (
                  <span className="text-sm text-slate-800">{tramite.estado}</span>
                )
              })()}
            </div>
            {tramite.transiciones_disponibles.length > 0 && (
              <p className="mt-1 text-[10px] text-slate-400">
                {tramite.transiciones_disponibles.length} transición{tramite.transiciones_disponibles.length !== 1 ? "es" : ""} disponible{tramite.transiciones_disponibles.length !== 1 ? "s" : ""}
              </p>
            )}
          </div>
        </div>
      </div>

      {/* Agente */}
      <div className="py-2">
        <p className="mb-1 text-[10px] font-bold uppercase tracking-widest text-slate-400">
          Agente
        </p>
        <MetaRow icon={Building2} label="Nombre" value={tramite.agente_nombre} />
        <MetaRow icon={Building2} label="CUA" value={tramite.agente_cua} mono />
        {tramite.correo_origen_email && (
          <MetaRow
            icon={Mail}
            label="Correo de origen"
            value={
              <span>
                {tramite.correo_origen_nombre && (
                  <span className="block font-medium">{tramite.correo_origen_nombre}</span>
                )}
                <span className="text-slate-500">{tramite.correo_origen_email}</span>
              </span>
            }
          />
        )}
      </div>

      {/* Asignación */}
      <div className="py-2">
        <p className="mb-1 text-[10px] font-bold uppercase tracking-widest text-slate-400">
          Asignación
        </p>
        <MetaRow icon={User} label="Analista" value={tramite.analista_nombre} />
        {tramite.ot_fecha_envio && (
          <MetaRow icon={Calendar} label="Turnado a GNP" value={tramite.ot_fecha_envio} />
        )}
        {tramite.ot_fecha_respuesta && (
          <MetaRow icon={Calendar} label="Respuesta GNP" value={tramite.ot_fecha_respuesta} />
        )}
      </div>

      {/* SLA */}
      <div className="py-1">
        <p className="mb-1 text-[10px] font-bold uppercase tracking-widest text-slate-400">
          SLA
        </p>
        <SlaBar tramite={tramite} />
        <MetaRow
          icon={Calendar}
          label="Recibido"
          value={formatFechaCorta(tramite.fecha_recepcion)}
        />
      </div>

      {/* Resumen IA */}
      <div className="py-3">
        <p className="mb-2 text-[10px] font-bold uppercase tracking-widest text-slate-400">
          Resumen IA
        </p>
        <p className="text-sm leading-relaxed text-slate-600">
          {tramite.resumen_ia ?? (
            <span className="italic text-slate-400">
              Se generará cuando el agente IA procese el trámite.
            </span>
          )}
        </p>
        {tramite.paso_pipeline_actual && (
          <p className="mt-2 text-[11px] text-slate-400">
            Pipeline en: <span className="font-mono font-semibold">{tramite.paso_pipeline_actual}</span>
          </p>
        )}
      </div>
    </div>
  )
}
