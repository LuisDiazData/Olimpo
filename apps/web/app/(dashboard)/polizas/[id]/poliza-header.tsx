import { Badge } from "@/components/ui/badge"
import { ESTADO_POLIZA_BADGE, RAMO_BADGE, formatMoney, vigenciaLabel, estaVencida } from "../shared"
import { EditarPolizaButton } from "../poliza-form"
import type { PolizaDetalle, AgenteOption, AnalistaOption } from "../types"

interface Props {
  poliza: PolizaDetalle
  agentes: AgenteOption[]
  analistas: AnalistaOption[]
}

export function PolizaHeader({ poliza, agentes, analistas }: Props) {
  const estado = ESTADO_POLIZA_BADGE[poliza.estado]
  const ramo = RAMO_BADGE[poliza.ramo]
  const vencida = estaVencida(poliza.fecha_fin)

  return (
    <div className="border-b bg-white px-6 py-4">
      <div className="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
        <div className="min-w-0 flex-1">
          <div className="flex flex-wrap items-center gap-2">
            <h1 className="font-mono text-xl font-bold text-slate-900">{poliza.numero_poliza}</h1>
            {estado && <Badge variant={estado.variant}>{estado.label}</Badge>}
            {ramo && <Badge variant={ramo.variant}>{ramo.label}</Badge>}
            {!poliza.activo && <Badge variant="slate">Archivada</Badge>}
          </div>
          <p className="mt-1 text-sm text-slate-600">
            {poliza.plan ? `${poliza.plan} · ` : ""}
            <span className={vencida ? "text-red-600" : ""}>
              {vigenciaLabel(poliza.fecha_inicio, poliza.fecha_fin)}
            </span>
          </p>
        </div>

        <div className="flex shrink-0 items-center gap-3">
          <div className="text-right">
            <p className="text-[10px] uppercase tracking-wider text-slate-400">Prima neta</p>
            <p className="text-lg font-bold text-slate-900">
              {formatMoney(poliza.prima_neta, poliza.moneda ?? "MXN")}
            </p>
          </div>
          <EditarPolizaButton poliza={poliza} agentes={agentes} analistas={analistas} />
        </div>
      </div>
    </div>
  )
}
