import { Building2, Calendar, Coins, FileText, Percent, Shield, User } from "lucide-react"
import { cn } from "@/lib/utils"
import { formatFecha, formatMoney } from "../shared"
import type { PolizaDetalle } from "../types"

function MetaRow({
  icon: Icon,
  label,
  value,
  mono = false,
}: {
  icon: React.ElementType
  label: string
  value: React.ReactNode
  mono?: boolean
}) {
  return (
    <div className="flex items-start gap-3 py-2.5">
      <Icon className="mt-0.5 h-4 w-4 shrink-0 text-slate-400" />
      <div className="min-w-0 flex-1">
        <p className="text-[10px] font-semibold uppercase tracking-wider text-slate-400">{label}</p>
        <p className={cn("mt-0.5 break-words text-sm text-slate-800", mono && "font-mono")}>
          {value || <span className="italic text-slate-400">—</span>}
        </p>
      </div>
    </div>
  )
}

export function PolizaMeta({ poliza }: { poliza: PolizaDetalle }) {
  const titular = poliza.asegurados.find((a) => a.rol === "titular")

  return (
    <div className="divide-y divide-slate-100 px-4">
      {/* Datos de la póliza */}
      <div className="py-2">
        <p className="mb-1 text-[10px] font-bold uppercase tracking-widest text-slate-400">
          Datos de la póliza
        </p>
        <MetaRow icon={User} label="Titular" value={titular?.asegurado_nombre} />
        <MetaRow
          icon={Shield}
          label="Ramo"
          value={poliza.ramo.charAt(0).toUpperCase() + poliza.ramo.slice(1)}
        />
        <MetaRow icon={FileText} label="Plan" value={poliza.plan} />
        <MetaRow
          icon={Calendar}
          label="Vigencia"
          value={`${formatFecha(poliza.fecha_inicio)} – ${formatFecha(poliza.fecha_fin)}`}
        />
      </div>

      {/* Agente */}
      <div className="py-2">
        <p className="mb-1 text-[10px] font-bold uppercase tracking-widest text-slate-400">Agente</p>
        <MetaRow icon={Building2} label="Nombre" value={poliza.agente_nombre} />
        <MetaRow icon={Building2} label="CUA" value={poliza.agente_cua} mono />
        <MetaRow icon={User} label="Analista" value={poliza.analista_nombre} />
      </div>

      {/* Financiero */}
      <div className="py-2">
        <p className="mb-1 text-[10px] font-bold uppercase tracking-widest text-slate-400">
          Financiero
        </p>
        <MetaRow
          icon={Coins}
          label="Prima neta"
          value={formatMoney(poliza.prima_neta, poliza.moneda ?? "MXN")}
        />
        <MetaRow
          icon={Percent}
          label="% Comisión"
          value={poliza.porcentaje_comision != null ? `${poliza.porcentaje_comision}%` : null}
        />
        <MetaRow
          icon={Coins}
          label="Monto comisión"
          value={formatMoney(poliza.monto_comision, poliza.moneda ?? "MXN")}
        />
      </div>

      {/* Notas */}
      <div className="py-3">
        <p className="mb-2 text-[10px] font-bold uppercase tracking-widest text-slate-400">Notas</p>
        <p className="text-sm leading-relaxed text-slate-600">
          {poliza.notas ?? <span className="italic text-slate-400">Sin notas.</span>}
        </p>
      </div>
    </div>
  )
}
