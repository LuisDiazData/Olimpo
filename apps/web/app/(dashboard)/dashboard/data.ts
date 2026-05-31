import type { SupabaseClient } from "@supabase/supabase-js"

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

export type EstadoCount = { estado: string; count: number }
export type RamoCount = { ramo: string; count: number }
export type TipoCount = { tipo: string; count: number }
export type SlaCount = { estado: string; count: number }
export type SemanaEntry = { semana: string; entradas: number; resueltos: number }

export type AnalistaCount = {
  analista_id: string
  analista_nombre: string | null
  count: number
}

export type RamoRechazo = {
  ramo: string
  total: number
  rechazados: number
  pct_rechazo: number
}

export type TopRechazo = {
  motivo_rechazo: string
  count: number
}

export type AlertaTramite = {
  id: string
  folio: string
  titulo: string
  estado: string
  prioridad: string
  fecha_limite_sla: string | null
  requiere_atencion: boolean
  riesgo_sla: "verde" | "amarillo" | "rojo"
  analista_nombre: string | null
}

// New types
export type GNPConversionEntry = {
  resultado: "completado" | "rechazado_gnp" | "activado_gnp"
  label: string
  count: number
  pct: number
}

export type AvgTimeByEstado = {
  estado: string
  label: string
  avg_dias: number
}

export type StalledTramite = {
  id: string
  folio: string
  titulo: string
  estado: string
  dias_sin_movimiento: number
  ultima_actividad: string
}

export type DashboardKpis = {
  tramitesActivos: number
  requierenAtencion: number
  aprobadosMes: number
  aprobadosMesAnterior: number
  pctSla: number
  slaTotal: number
  tiempoPromedioDias: number | null
  tasaRechazoPct: number
  tasaReenvioPct: number
  pctCorreosConRespuesta: number
  // New KPIs
  backlogBloqueante: number
  tasaEscalamientoPct: number
  ratioCompletadoRechazo: number | null
  tramitesSinMovimiento: number
}

export type DashboardData = {
  kpis: DashboardKpis
  porEstado: EstadoCount[]
  porRamo: RamoCount[]
  porTipo: TipoCount[]
  porSla: SlaCount[]
  tendencia: SemanaEntry[]
  alertas: AlertaTramite[]
  cargaPorAnalista: AnalistaCount[]
  rechazoPorRamo: RamoRechazo[]
  topRechazos: TopRechazo[]
  // New data
  gnpConversion: GNPConversionEntry[]
  avgTiempoPorEstado: AvgTimeByEstado[]
  tramitesEstancados: StalledTramite[]
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function semanaLabel(fecha: Date): string {
  return fecha.toLocaleDateString("es-MX", { day: "numeric", month: "short" })
}

function getLunesAnterior(fecha: Date, nSemanas: number): Date {
  const d = new Date(fecha)
  const diaSemana = d.getDay() === 0 ? 7 : d.getDay()
  d.setDate(d.getDate() - diaSemana + 1)
  d.setHours(0, 0, 0, 0)
  d.setDate(d.getDate() - (nSemanas - 1) * 7)
  return d
}

function agruparPorSemana(
  entradas: string[],
  resueltos: string[],
  nSemanas: number
): SemanaEntry[] {
  const ahora = new Date()
  const primerLunes = getLunesAnterior(ahora, nSemanas)

  return Array.from({ length: nSemanas }, (_, i) => {
    const inicio = new Date(primerLunes)
    inicio.setDate(primerLunes.getDate() + i * 7)
    const fin = new Date(inicio)
    fin.setDate(inicio.getDate() + 7)

    const e = entradas.filter((d) => {
      const f = new Date(d)
      return f >= inicio && f < fin
    }).length

    const r = resueltos.filter((d) => {
      const f = new Date(d)
      return f >= inicio && f < fin
    }).length

    return { semana: semanaLabel(inicio), entradas: e, resueltos: r }
  })
}

function riesgoSla(fechaLimite: string | null): "verde" | "amarillo" | "rojo" {
  if (!fechaLimite) return "verde"
  const horas = (new Date(fechaLimite).getTime() - Date.now()) / 3_600_000
  if (horas < 0) return "rojo"
  if (horas < 24) return "rojo"
  if (horas < 72) return "amarillo"
  return "verde"
}

function contarPorCampo<T extends Record<string, unknown>>(
  rows: T[],
  campo: keyof T
): Record<string, number> {
  const map: Record<string, number> = {}
  for (const row of rows) {
    const val = row[campo]
    if (val != null) {
      const key = String(val)
      map[key] = (map[key] ?? 0) + 1
    }
  }
  return map
}

// ---------------------------------------------------------------------------
// Main fetcher
// ---------------------------------------------------------------------------

export async function getDashboardData(
  supabase: SupabaseClient,
  ramoFiltro?: string
): Promise<DashboardData> {
  const ahora = new Date()
  const inicioMes = new Date(ahora.getFullYear(), ahora.getMonth(), 1)
  const inicioMesAnterior = new Date(ahora.getFullYear(), ahora.getMonth() - 1, 1)
  const finMesAnterior = new Date(ahora.getFullYear(), ahora.getMonth(), 0, 23, 59, 59)
  const hace8Semanas = new Date(ahora.getTime() - 56 * 24 * 3_600_000)
  const hace5Dias = new Date(ahora.getTime() - 5 * 24 * 3_600_000)

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  function withRamo(q: any) {
    return ramoFiltro ? q.eq("ramo", ramoFiltro) : q
  }

  // ── Queries ───────────────────────────────────────────────────────────────

  const [
    activosRes,
    atencionRes,
    aprobadosMesRes,
    aprobadosAnteriorRes,
    estadosRes,
    ramoRes,
    tipoRes,
    slaRes,
    entradasRes,
    resueltosRes,
    alertasRes,
    cargaAnalistaRes,
    rechazosGnpFullRes,
    topRechazosRes,
    correosEntrantesRes,
    correosSalientesRes,
    reenviosRes,
    resueltosTiempoRes,
    // New queries
    backlogRes,
    eventosTurnadoRes,
    tramiteEventosRes,
    escaladosRes,
    estancadosRes,
  ] = await Promise.all([
    // KPI 1 — trámites activos
    withRamo(
      supabase
        .from("tramite")
        .select("*", { count: "exact", head: true })
        .eq("activo", true)
        .not("estado", "in", "('completado','rechazado_gnp','cancelado')")
    ),

    // KPI 2 — requieren atención
    withRamo(
      supabase
        .from("tramite")
        .select("*", { count: "exact", head: true })
        .eq("activo", true)
        .eq("requiere_atencion", true)
        .not("estado", "in", "('completado','rechazado_gnp','cancelado')")
    ),

    // KPI 3 — aprobados este mes
    withRamo(
      supabase
        .from("tramite")
        .select("*", { count: "exact", head: true })
        .eq("estado", "completado")
        .gte("fecha_recepcion", inicioMes.toISOString())
    ),

    // Delta — aprobados mes anterior
    withRamo(
      supabase
        .from("tramite")
        .select("*", { count: "exact", head: true })
        .eq("estado", "completado")
        .gte("fecha_recepcion", inicioMesAnterior.toISOString())
        .lte("fecha_recepcion", finMesAnterior.toISOString())
    ),

    // Por estado
    withRamo(supabase.from("tramite").select("estado").eq("activo", true)),

    // Por ramo
    withRamo(
      supabase
        .from("tramite")
        .select("ramo")
        .eq("activo", true)
        .not("ramo", "is", null)
    ),

    // Por tipo
    withRamo(supabase.from("tramite").select("tipo_tramite").eq("activo", true)),

    // SLA breakdown
    supabase.from("sla_tramite").select("estado"),

    // Tendencia — entradas
    withRamo(
      supabase
        .from("tramite")
        .select("fecha_recepcion")
        .gte("fecha_recepcion", hace8Semanas.toISOString())
    ),

    // Tendencia — resueltos
    withRamo(
      supabase
        .from("tramite")
        .select("updated_at")
        .in("estado", ["completado", "rechazado_gnp"])
        .gte("updated_at", hace8Semanas.toISOString())
    ),

    // Alertas
    withRamo(
      supabase
        .from("tramite")
        .select("id, folio, titulo, estado, prioridad, fecha_limite_sla, requiere_atencion")
        .eq("activo", true)
        .or("requiere_atencion.eq.true,prioridad.eq.urgente")
        .not("estado", "in", "('completado','rechazado_gnp','cancelado')")
        .order("prioridad", { ascending: false })
        .order("fecha_limite_sla", { ascending: true, nullsFirst: false })
        .limit(20)
    ),

    // Carga por analista
    withRamo(
      supabase
        .from("tramite")
        .select("analista_id")
        .eq("activo", true)
        .not("estado", "in", "('completado','rechazado_gnp','cancelado')")
        .not("analista_id", "is", null)
    ),

    // Rechazo GNP — resueltos con estado y ramo (últimas 8 semanas)
    supabase
      .from("tramite")
      .select("ramo, estado")
      .eq("activo", true)
      .in("estado", ["completado", "rechazado_gnp"])
      .not("ramo", "is", null)
      .gte("updated_at", hace8Semanas.toISOString()),

    // TOP rechazos de rag_aprendizaje
    supabase
      .from("rag_aprendizaje")
      .select("motivo_rechazo")
      .eq("descartado", false)
      .eq("aprendizaje_validado", true)
      .limit(10),

    // Correos entrantes este mes
    supabase
      .from("correo")
      .select("id", { count: "exact" })
      .eq("tipo", "entrante")
      .gte("fecha_correo", inicioMes.toISOString()),

    // Correos salientes este mes
    supabase
      .from("correo")
      .select("id", { count: "exact" })
      .eq("tipo", "saliente")
      .gte("fecha_correo", inicioMes.toISOString()),

    // Reenvíos — trámites que volvieron a pendiente_documentos_agente
    supabase
      .from("tramite_evento")
      .select("tramite_id")
      .eq("tipo_evento", "cambio_estado")
      .eq("estado_nuevo", "pendiente_documentos_agente")
      .gte("created_at", hace8Semanas.toISOString()),

    // Tiempo de resolución (tramites resueltos con fechas)
    withRamo(
      supabase
        .from("tramite")
        .select("fecha_recepcion, updated_at")
        .in("estado", ["completado", "rechazado_gnp"])
        .gte("updated_at", hace8Semanas.toISOString())
        .not("fecha_recepcion", "is", null)
        .not("updated_at", "is", null)
    ),

    // ── New metrics ───────────────────────────────────────────────────────────

    // Backlog bloqueante: pendiente_documentos_agente + activado_gnp
    withRamo(
      supabase
        .from("tramite")
        .select("estado", { count: "exact", head: true })
        .eq("activo", true)
        .in("estado", ["pendiente_documentos_agente", "activado_gnp"])
    ),

    // GNP Conversion: resultados de trámites que alguna vez estuvieron en turnado_a_gnp
    // Contamos cuántos terminó en cada resultado (últimas 8 semanas)
    withRamo(
      supabase
        .from("tramite")
        .select("estado")
        .eq("activo", true)
        .in("estado", ["completado", "rechazado_gnp", "activado_gnp"])
        .gte("updated_at", hace8Semanas.toISOString())
    ),

    // Tiempo promedio por estado (desde tramite_evento)
    supabase
      .from("tramite_evento")
      .select("estado_nuevo, created_at")
      .eq("tipo_evento", "cambio_estado")
      .not("estado_nuevo", "is", null)
      .gte("created_at", hace8Semanas.toISOString())
      .limit(5000),

    // Tasa de escalamiento: trámites con eventos de escalado
    withRamo(
      supabase
        .from("tramite")
        .select("id", { count: "exact", head: true })
        .eq("activo", true)
        .not("estado", "in", "('completado','rechazado_gnp','cancelado')")
    ),

    // Tramites sin movimiento > 5 días
    withRamo(
      supabase
        .from("tramite")
        .select("id, folio, titulo, estado, ultima_actividad")
        .eq("activo", true)
        .not("estado", "in", "('completado','rechazado_gnp','cancelado')")
        .lt("ultima_actividad", hace5Dias.toISOString())
        .order("ultima_actividad", { ascending: true })
        .limit(10)
    ),
  ])

  // ── Base KPIs ─────────────────────────────────────────────────────────────

  const slaRows = slaRes.data ?? []
  const slaCumplidos = slaRows.filter((s) => s.estado === "cumplido").length
  const slaIncumplidos = slaRows.filter((s) => s.estado === "incumplido").length
  const slaTotal = slaCumplidos + slaIncumplidos
  const pctSla = slaTotal > 0 ? Math.round((slaCumplidos / slaTotal) * 100) : 100

  // Tiempo promedio de resolución
  const resueltosTiempo = (resueltosTiempoRes.data ?? []).filter(
    (t: Record<string, unknown>) => t.fecha_recepcion && t.updated_at
  )
  let tiempoPromedioDias: number | null = null
  if (resueltosTiempo.length > 0) {
    const totalMs = resueltosTiempo.reduce((acc: number, t: Record<string, unknown>) => {
      return acc + (new Date(t.updated_at as string).getTime() - new Date(t.fecha_recepcion as string).getTime())
    }, 0)
    tiempoPromedioDias = Math.round((totalMs / resueltosTiempo.length) / (1000 * 60 * 60 * 24) * 10) / 10
  }

  // ── GNP Conversion ─────────────────────────────────────────────────────────

  const resultadosGnpRaw = (eventosTurnadoRes.data ?? []) as { estado: string }[]
  const gnpCounts: Record<string, number> = {}
  for (const r of resultadosGnpRaw) {
    gnpCounts[r.estado] = (gnpCounts[r.estado] ?? 0) + 1
  }

  const gnpTotal = Object.values(gnpCounts).reduce((a, b) => a + b, 0) || 1

  const GNP_RESULTADO_CONFIG: Record<string, { label: string; color: string }> = {
    completado:      { label: "Completado",       color: "#22c55e" },
    rechazado_gnp:   { label: "Rechazado GNP",     color: "#ef4444" },
    activado_gnp:   { label: "Activado GNP",     color: "#f97316" },
  }

  const gnpConversion: GNPConversionEntry[] = Object.entries(gnpCounts).map(
    ([resultado, count]) => ({
      resultado: resultado as "completado" | "rechazado_gnp" | "activado_gnp",
      label: GNP_RESULTADO_CONFIG[resultado]?.label ?? resultado,
      count,
      pct: Math.round((count / gnpTotal) * 100),
    })
  )

  // ── Tasa de rechazo GNP por ramo ──────────────────────────────────────────

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const rechazosGnp = rechazosGnpFullRes.data ?? ([] as any[])
  const ramoStats: Record<string, { total: number; rechazados: number }> = {}
  for (const r of rechazosGnp) {
    if (!r.ramo) continue
    if (!ramoStats[r.ramo]) ramoStats[r.ramo] = { total: 0, rechazados: 0 }
    ramoStats[r.ramo].total++
    if (r.estado === "rechazado_gnp") ramoStats[r.ramo].rechazados++
  }

  const rechazoPorRamo: RamoRechazo[] = Object.entries(ramoStats).map(([ramo, s]) => ({
    ramo,
    total: s.total,
    rechazados: s.rechazados,
    pct_rechazo: s.total > 0 ? Math.round((s.rechazados / s.total) * 100) : 0,
  }))

  const totalRechazadosGnp = Object.values(ramoStats).reduce((acc, s) => acc + s.rechazados, 0)
  const totalResueltosGnp = Object.values(ramoStats).reduce((acc, s) => acc + s.total, 0)
  const tasaRechazoPct = totalResueltosGnp > 0
    ? Math.round((totalRechazadosGnp / totalResueltosGnp) * 100)
    : 0

  // ── Tasa de reenvío ───────────────────────────────────────────────────────

  const tramitesReenviados = new Set(
    (reenviosRes.data ?? []).map((e) => e.tramite_id as string)
  ).size
  const activosCount = activosRes.count ?? 1
  const tasaReenvioPct = Math.round((tramitesReenviados / activosCount) * 100)

  // ── % correos con respuesta ───────────────────────────────────────────────

  const correosEntrantes = correosEntrantesRes.count ?? 0
  const correosSalientes = correosSalientesRes.count ?? 0
  const pctCorreosConRespuesta = correosEntrantes > 0
    ? Math.round((correosSalientes / correosEntrantes) * 100 * 10) / 10
    : 0

  // ── Backlog bloqueante ───────────────────────────────────────────────────

  const backlogBloqueante = backlogRes.count ?? 0

  // ── Tiempo promedio por estado ────────────────────────────────────────────

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const eventosRaw = (tramiteEventosRes.data ?? []) as any[]
  const estadoDiasMap: Record<string, { total_ms: number; count: number }> = {}
  for (const ev of eventosRaw) {
    if (!ev.estado_nuevo) continue
    // Solo eventos que tienen fecha_anterior para calcular duración en ese estado
    // Approximación: usamos created_at como proxy del tiempo en ese estado
    // (Esto sobreestima pero sirve como indicador relativo)
  }

  // Para cada estado activo, calculamos avg dias desde que entró
  const ESTADO_LABELS: Record<string, string> = {
    recibido:                   "Recibido",
    en_revision:                "En revisión",
    pendiente_documentos_agente:"Docs. pendientes",
    turnado_a_gnp:              "Turnado a GNP",
    activado_gnp:               "Activado por GNP",
    complemento_en_revision:    "Complemento en rev.",
    escalado:                   "Escalado",
  }

  const activosEstados = ["recibido","en_revision","pendiente_documentos_agente","turnado_a_gnp","activado_gnp","complemento_en_revision","escalado"]

  // Tiempo avg en cada estado = días entre primer evento de entrada y primer evento de salida
  // Simplificado: días transcurridos desde fecha_recepcion hasta hoy por estado
  const estadoRowsRes = await withRamo(
    supabase
      .from("tramite")
      .select("estado, fecha_recepcion")
      .eq("activo", true)
      .not("estado", "in", "('completado','rechazado_gnp','cancelado')")
  )

  const estadoRows = (estadoRowsRes.data ?? []) as { estado: string; fecha_recepcion: string }[]
  const estadoDiasSum: Record<string, { total_dias: number; count: number }> = {}
  const ahoraMs = Date.now()
  for (const r of estadoRows) {
    if (!estadoDiasSum[r.estado]) estadoDiasSum[r.estado] = { total_dias: 0, count: 0 }
    const dias = (ahoraMs - new Date(r.fecha_recepcion).getTime()) / (1000 * 60 * 60 * 24)
    estadoDiasSum[r.estado].total_dias += dias
    estadoDiasSum[r.estado].count++
  }

  const avgTiempoPorEstado: AvgTimeByEstado[] = activosEstados.map((estado) => {
    const d = estadoDiasSum[estado]
    return {
      estado,
      label: ESTADO_LABELS[estado] ?? estado,
      avg_dias: d && d.count > 0 ? Math.round((d.total_dias / d.count) * 10) / 10 : 0,
    }
  })

  // ── Tasa de escalamiento ──────────────────────────────────────────────────

  const escaladosRes2 = await withRamo(
    supabase
      .from("tramite_evento")
      .select("tramite_id", { count: "exact", head: true })
      .eq("tipo_evento", "cambio_estado")
      .eq("estado_nuevo", "escalado")
  )
  // Count unique tramites que fueron escalados
  const escaladosUnicos = new Set(
    ((escaladosRes2.data ?? []) as { tramite_id: string }[]).map((e) => e.tramite_id)
  ).size
  const totalActivosParaEscalar = activosRes.count ?? 1
  const tasaEscalamientoPct = Math.round((escaladosUnicos / totalActivosParaEscalar) * 100)

  // ── Ratio completado vs rechazado ─────────────────────────────────────────

  const completadosGnp = gnpCounts["completado"] ?? 0
  const rechazadosGnpCount = gnpCounts["rechazado_gnp"] ?? 0
  const ratioCompletadoRechazo: number | null =
    rechazadosGnpCount > 0
      ? Math.round((completadosGnp / rechazadosGnpCount) * 10) / 10
      : completadosGnp > 0 ? null : null

  // ── Tramites sin movimiento > 5 días ───────────────────────────────────────

  const tramitesEstancados: StalledTramite[] = (estancadosRes.data ?? []).map((t: Record<string, unknown>) => {
    const dias = Math.floor(
      (ahoraMs - new Date(t.ultima_actividad as string).getTime()) / (1000 * 60 * 60 * 24)
    )
    return {
      id: t.id as string,
      folio: t.folio as string,
      titulo: t.titulo as string,
      estado: t.estado as string,
      dias_sin_movimiento: dias,
      ultima_actividad: t.ultima_actividad as string,
    }
  })

  const tramitesSinMovimiento = estancadosRes.count ?? 0

  // ── Aggregations ───────────────────────────────────────────────────────────

  const estadoMap = contarPorCampo(estadosRes.data ?? ([] as Record<string, unknown>[]), "estado")
  const ramoMap = contarPorCampo(ramoRes.data ?? ([] as Record<string, unknown>[]), "ramo")
  const tipoMap = contarPorCampo(tipoRes.data ?? ([] as Record<string, unknown>[]), "tipo_tramite")
  const slaMap = contarPorCampo(slaRows as Record<string, unknown>[], "estado")

  const porEstado: EstadoCount[] = Object.entries(estadoMap).map(([estado, count]) => ({
    estado,
    count,
  }))

  const porRamo: RamoCount[] = Object.entries(ramoMap).map(([ramo, count]) => ({
    ramo,
    count,
  }))

  const porTipo: TipoCount[] = Object.entries(tipoMap)
    .map(([tipo, count]) => ({ tipo, count }))
    .sort((a, b) => b.count - a.count)

  const porSla: SlaCount[] = Object.entries(slaMap).map(([estado, count]) => ({
    estado,
    count,
  }))

  const entradas = (entradasRes.data ?? []).map((t: Record<string, unknown>) => t.fecha_recepcion as string)
  const resueltosTendencia = (resueltosRes.data ?? []).map((t: Record<string, unknown>) => t.updated_at as string)
  const tendencia = agruparPorSemana(entradas, resueltosTendencia, 8)

  // ── Carga por analista ───────────────────────────────────────────────────

  const cargaRaw = (cargaAnalistaRes.data ?? []) as { analista_id: string | null }[]
  const analistMap = new Map<string, number>()
  for (const row of cargaRaw) {
    if (!row.analista_id) continue
    analistMap.set(row.analista_id, (analistMap.get(row.analista_id) ?? 0) + 1)
  }

  const analistaIds = Array.from(analistMap.keys())
  let analistasNombres: Record<string, string> = {}
  if (analistaIds.length > 0) {
    const nombresRes = await supabase
      .from("usuario")
      .select("id, nombre")
      .in("id", analistaIds)
    for (const u of (nombresRes.data ?? [])) {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      analistasNombres[u.id as string] = u.nombre as string
    }
  }

  const cargaPorAnalista: AnalistaCount[] = Array.from(analistMap.entries())
    .map(([analista_id, count]) => ({
      analista_id,
      analista_nombre: analistasNombres[analista_id] ?? null,
      count,
    }))
    .sort((a, b) => b.count - a.count)

  // ── Top rechazos ─────────────────────────────────────────────────────────

  const topRechazos: TopRechazo[] = (topRechazosRes.data ?? []).map((r) => ({
    motivo_rechazo: r.motivo_rechazo as string,
    count: 1,
  }))

  // ── Alertas ──────────────────────────────────────────────────────────────

  const alertasRaw = alertasRes.data ?? []
  const alertas: AlertaTramite[] = alertasRaw.map((t: Record<string, unknown>) => ({
    id: t.id as string,
    folio: t.folio as string,
    titulo: t.titulo as string,
    estado: t.estado as string,
    prioridad: t.prioridad as string,
    fecha_limite_sla: t.fecha_limite_sla as string | null,
    requiere_atencion: t.requiere_atencion as boolean,
    riesgo_sla: riesgoSla(t.fecha_limite_sla as string | null),
    analista_nombre: null,
  }))

  return {
    kpis: {
      tramitesActivos: activosRes.count ?? 0,
      requierenAtencion: atencionRes.count ?? 0,
      aprobadosMes: aprobadosMesRes.count ?? 0,
      aprobadosMesAnterior: aprobadosAnteriorRes.count ?? 0,
      pctSla,
      slaTotal,
      tiempoPromedioDias,
      tasaRechazoPct,
      tasaReenvioPct,
      pctCorreosConRespuesta,
      backlogBloqueante,
      tasaEscalamientoPct,
      ratioCompletadoRechazo,
      tramitesSinMovimiento,
    },
    porEstado,
    porRamo,
    porTipo,
    porSla,
    tendencia,
    alertas,
    cargaPorAnalista,
    rechazoPorRamo,
    topRechazos,
    gnpConversion,
    avgTiempoPorEstado,
    tramitesEstancados,
  }
}