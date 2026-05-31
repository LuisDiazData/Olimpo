
import { getSupabaseServer } from "@/lib/supabase/server"
import { getDashboardData } from "./data"
import { KpiCard } from "@/components/dashboard/kpi-card"
import { EstadoChart } from "@/components/dashboard/estado-chart"
import { TendenciaChart } from "@/components/dashboard/tendencia-chart"
import { RamoDonut } from "@/components/dashboard/ramo-donut"
import { SlaRing } from "@/components/dashboard/sla-ring"
import { TipoChart } from "@/components/dashboard/tipo-chart"
import { AlertasTable } from "@/components/dashboard/alertas-table"
import { AnalystWorkloadChart } from "@/components/dashboard/analyst-workload-chart"
import { GNPRejectionChart } from "@/components/dashboard/gnp-rejection-chart"
import { TopRechazosList } from "@/components/dashboard/top-rechazos-list"

function saludo(): string {
  const h = new Date().getHours()
  if (h < 12) return "Buenos días"
  if (h < 19) return "Buenas tardes"
  return "Buenas noches"
}

function fechaActual(): string {
  return new Date().toLocaleDateString("es-MX", {
    weekday: "long",
    year: "numeric",
    month: "long",
    day: "numeric",
  })
}

function capitalize(s: string): string {
  return s.charAt(0).toUpperCase() + s.slice(1)
}

function ChartCard({
  title,
  subtitle,
  children,
}: {
  title: string
  subtitle?: string
  children: React.ReactNode
}) {
  return (
    <div className="rounded-xl border bg-white p-5 shadow-sm">
      <div className="mb-4">
        <h3 className="text-sm font-semibold text-slate-800">{title}</h3>
        {subtitle && <p className="text-xs text-muted-foreground">{subtitle}</p>}
      </div>
      {children}
    </div>
  )
}

export default async function DashboardPage() {
  const supabase = await getSupabaseServer()

  const {
    data: { user },
  } = await supabase.auth.getUser()

  const { data: perfil } = user
    ? await supabase
        .from("usuario")
        .select("id, nombre, rol, ramo")
        .eq("id", user.id)
        .single()
    : { data: null }

  const nombreCorto = perfil?.nombre
    ? perfil.nombre.split(" ")[0]
    : user?.email?.split("@")[0] ?? "Usuario"

  const esGerente = perfil?.rol === "gerente"
  const esDirector = ["director_general", "director_ops"].includes(perfil?.rol ?? "")
  const ramoFiltro = esGerente ? perfil?.ramo ?? undefined : undefined

  const data = await getDashboardData(supabase, ramoFiltro)
  const { kpis } = data

  const deltaMes = kpis.aprobadosMes - kpis.aprobadosMesAnterior

  const rolLabel = esDirector
    ? "Director General"
    : esGerente
    ? `Gerente · ${perfil?.ramo?.toUpperCase()}`
    : "Analista"

  return (
    <div className="space-y-6">
      {/* Header */}
      <div className="flex items-start justify-between">
        <div>
          <h2 className="text-xl font-bold text-slate-900">
            {saludo()}, {nombreCorto}
          </h2>
          <p className="mt-0.5 text-sm text-muted-foreground capitalize">
            {capitalize(fechaActual())}
          </p>
        </div>
        <div className="text-right text-xs text-muted-foreground">
          <p>Dashboard · {rolLabel}</p>
          <p className="mt-0.5">Datos en tiempo real</p>
        </div>
      </div>

      {/* KPIs row 1 */}
      <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
        <KpiCard
          label="Trámites activos"
          value={kpis.tramitesActivos}
          icon="FileText"
          description="En proceso (sin cerrar)"
          accent="blue"
        />
        <KpiCard
          label="Cumplimiento SLA"
          value={`${kpis.pctSla}%`}
          icon="ShieldCheck"
          description={
            kpis.slaTotal > 0
              ? `Sobre ${kpis.slaTotal} SLAs cerrados`
              : "Sin SLAs cerrados aún"
          }
          accent={kpis.pctSla >= 80 ? "green" : kpis.pctSla >= 60 ? "amber" : "red"}
        />
        <KpiCard
          label="Requieren atención"
          value={kpis.requierenAtencion}
          icon="AlertTriangle"
          description="Escalados por el agente IA"
          accent={kpis.requierenAtencion > 0 ? "red" : "green"}
        />
        <KpiCard
          label="Aprobados este mes"
          value={kpis.aprobadosMes}
          icon="CheckCircle2"
          description="Trámites resueltos con éxito"
          delta={deltaMes}
          accent="green"
        />
      </div>

      {/* KPIs row 2 — métricas calidad + productividad */}
      {(esDirector || esGerente) && (
        <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
          <KpiCard
            label="Tiempo promedio resolución"
            value={
              kpis.tiempoPromedioDias != null
                ? `${kpis.tiempoPromedioDias}d`
                : "—"
            }
            icon="Clock"
            description="Desde ingreso hasta resolución"
            accent="violet"
          />
          <KpiCard
            label="Tasa rechazo GNP"
            value={`${kpis.tasaRechazoPct}%`}
            icon="RotateCcw"
            description="Rechazos sobre total resueltos"
            accent={kpis.tasaRechazoPct > 20 ? "red" : kpis.tasaRechazoPct > 10 ? "amber" : "green"}
          />
          <KpiCard
            label="Tasa de reenvío"
            value={`${kpis.tasaReenvioPct}%`}
            icon="TrendingUp"
            description="Trámites que volvieron a pend. docs."
            accent={kpis.tasaReenvioPct > 15 ? "red" : kpis.tasaReenvioPct > 5 ? "amber" : "green"}
          />
          <KpiCard
            label="Correos respondidos"
            value={`${kpis.pctCorreosConRespuesta}%`}
            icon="Mail"
            description="Con respuesta vs entrantes este mes"
            accent={kpis.pctCorreosConRespuesta >= 70 ? "green" : kpis.pctCorreosConRespuesta >= 40 ? "amber" : "red"}
          />
        </div>
      )}

      {/* Row 2: Estado funnel + Tendencia */}
      <div className="grid gap-4 lg:grid-cols-5">
        <div className="lg:col-span-2">
          <ChartCard
            title="Embudo de estados"
            subtitle="Trámites activos por etapa del flujo"
          >
            <EstadoChart data={data.porEstado} />
          </ChartCard>
        </div>
        <div className="lg:col-span-3">
          <ChartCard
            title="Tendencia semanal"
            subtitle="Entradas vs resueltos — últimas 8 semanas"
          >
            <TendenciaChart data={data.tendencia} />
          </ChartCard>
        </div>
      </div>

      {/* Row 2b: Backlog + Escalamiento + Ratio + Sin movimiento */}
      {(esDirector || esGerente) && (
        <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
          <KpiCard
            label="Backlog bloqueante"
            value={kpis.backlogBloqueante}
            icon="Inbox"
            description="Pend. docs. agente + Activado GNP"
            accent={kpis.backlogBloqueante > 20 ? "red" : kpis.backlogBloqueante > 10 ? "amber" : "green"}
          />
          <KpiCard
            label="Tasa escalamiento"
            value={`${kpis.tasaEscalamientoPct}%`}
            icon="ArrowUpRight"
            description="Trámites escalados a gerencia"
            accent={kpis.tasaEscalamientoPct > 10 ? "red" : kpis.tasaEscalamientoPct > 5 ? "amber" : "green"}
          />
          <KpiCard
            label="Ratio comp./rechazo"
            value={kpis.ratioCompletadoRechazo ?? "—"}
            icon="TrendingUp"
            description="Veces completado vs rechazado"
            accent={
              kpis.ratioCompletadoRechazo == null
                ? "neutral"
                : kpis.ratioCompletadoRechazo >= 3
                ? "green"
                : kpis.ratioCompletadoRechazo >= 1.5
                ? "amber"
                : "red"
            }
          />
          <KpiCard
            label="Sin movimiento"
            value={kpis.tramitesSinMovimiento}
            icon="AlertCircle"
            description="Sin actividad > 5 días"
            accent={kpis.tramitesSinMovimiento > 5 ? "red" : kpis.tramitesSinMovimiento > 0 ? "amber" : "green"}
          />
        </div>
      )}

      {/* Row 3: Ramo + SLA + Tipo */}
      <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
        <ChartCard title="Por ramo" subtitle="Distribución de trámites activos">
          <RamoDonut data={data.porRamo} />
        </ChartCard>

        <ChartCard title="Estado SLA" subtitle="Todos los SLAs del sistema">
          <SlaRing data={data.porSla} pct={kpis.pctSla} />
        </ChartCard>

        <ChartCard title="Por tipo de trámite" subtitle="Trámites activos">
          <TipoChart data={data.porTipo} />
        </ChartCard>
      </div>

      {/* Row 4: Analista workload + Rechazo GNP */}
      {(esDirector || esGerente) && (
        <div className="grid gap-4 lg:grid-cols-5">
          <div className="lg:col-span-2">
            <ChartCard
              title="Carga de trabajo por analista"
              subtitle="Trámites activos asignados — verde OK, ámbar cargado, rojo saturado"
            >
              <AnalystWorkloadChart data={data.cargaPorAnalista} />
            </ChartCard>
          </div>
          <div className="lg:col-span-3">
            <ChartCard
              title="Tasa de rechazo GNP por ramo"
              subtitle="Rechazos sobre trámites resueltos por ramo — ultimas 8 semanas"
            >
              <GNPRejectionChart data={data.rechazoPorRamo} />
            </ChartCard>
          </div>
        </div>
      )}

      {/* Row 5: Top rechazos GNP */}
      {(esDirector || esGerente) && data.topRechazos.length > 0 && (
        <ChartCard
          title="Top errores de validación GNP"
          subtitle="Aprendizajes más comunes — analistas han validado estos patrones"
        >
          <TopRechazosList rechazos={data.topRechazos} />
        </ChartCard>
      )}

      {/* Row 6: Alertas */}
      <div>
        <div className="mb-3 flex items-center justify-between">
          <div>
            <h3 className="text-sm font-semibold text-slate-800">
              Trámites que requieren atención
            </h3>
            <p className="text-xs text-muted-foreground">
              Urgentes o escalados por el agente IA — clic en folio para abrir
            </p>
          </div>
        </div>
        <AlertasTable alertas={data.alertas} />
      </div>
    </div>
  )
}
