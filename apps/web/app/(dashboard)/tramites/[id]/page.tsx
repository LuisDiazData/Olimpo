import { notFound } from "next/navigation"
import Link from "next/link"
import { ChevronLeft } from "lucide-react"
import { getSupabaseServer } from "@/lib/supabase/server"
import { riesgoSla } from "../shared"
import type { TramiteDetalle } from "../types"
import { TramiteMeta } from "./tramite-meta"
import { TramiteHeader } from "./tramite-header"
import { TramiteTabs } from "./tramite-tabs"

export const dynamic = "force-dynamic"

async function fetchTramiteDetalle(id: string): Promise<TramiteDetalle | null> {
  const supabase = await getSupabaseServer()

  const { data, error } = await supabase
    .from("tramite")
    .select(`
      id, folio, folio_ot, tipo_tramite, titulo, descripcion, estado, prioridad,
      canal_origen, ramo, requiere_atencion, etiquetas, datos_tramite, resumen_ia,
      activo, created_at, updated_at,
      fecha_recepcion, fecha_limite_sla, ultima_actividad,
      ot_fecha_envio, ot_fecha_respuesta, motivo_rechazo_gnp,
      paso_pipeline_actual,
      agente_id, poliza_id, asegurado_id, analista_id, gerente_id, asistente_id,
      agente:agente_id ( nombre, cua ),
      analista:analista_id ( nombre ),
      poliza:poliza_id ( numero_poliza ),
      asegurado:asegurado_id ( nombre )
    `)
    .eq("id", id)
    .single()

  if (error || !data) return null

  // Aplanar JOINs
  const row = data as Record<string, unknown>
  const agente = (row.agente as Record<string, string> | null) ?? {}
  const analista = (row.analista as Record<string, string> | null) ?? {}
  const poliza = (row.poliza as Record<string, string> | null) ?? {}
  const asegurado = (row.asegurado as Record<string, string> | null) ?? {}

  // Correo que originó el trámite
  let correo_origen_email: string | null = null
  let correo_origen_nombre: string | null = null

  const { data: vinculo } = await supabase
    .from("correo_tramite")
    .select("es_origen, correo:correo_id ( de_email, de_nombre )")
    .eq("tramite_id", id)
    .order("es_origen", { ascending: false })
    .limit(1)
    .maybeSingle()

  if (vinculo) {
    const c = (vinculo.correo as unknown as { de_email?: string; de_nombre?: string } | null) ?? {}
    correo_origen_email = c.de_email ?? null
    correo_origen_nombre = c.de_nombre ?? null
  }

  const fechaLimite = (row.fecha_limite_sla as string | null) ?? null

  return {
    id: row.id as string,
    folio: row.folio as string,
    folio_ot: (row.folio_ot as string | null) ?? null,
    tipo_tramite: row.tipo_tramite as string,
    titulo: row.titulo as string,
    descripcion: (row.descripcion as string | null) ?? null,
    estado: row.estado as string,
    prioridad: row.prioridad as string,
    canal_origen: row.canal_origen as string,
    ramo: (row.ramo as string | null) ?? null,
    requiere_atencion: row.requiere_atencion as boolean,
    etiquetas: (row.etiquetas as string[]) ?? [],
    datos_tramite: (row.datos_tramite as Record<string, unknown>) ?? {},
    resumen_ia: (row.resumen_ia as string | null) ?? null,
    activo: row.activo as boolean,
    created_at: row.created_at as string,
    updated_at: row.updated_at as string,
    fecha_recepcion: row.fecha_recepcion as string,
    fecha_limite_sla: fechaLimite,
    ultima_actividad: row.ultima_actividad as string,
    ot_fecha_envio: (row.ot_fecha_envio as string | null) ?? null,
    ot_fecha_respuesta: (row.ot_fecha_respuesta as string | null) ?? null,
    motivo_rechazo_gnp: (row.motivo_rechazo_gnp as string | null) ?? null,
    paso_pipeline_actual: (row.paso_pipeline_actual as string | null) ?? null,
    agente_id: (row.agente_id as string | null) ?? null,
    poliza_id: (row.poliza_id as string | null) ?? null,
    asegurado_id: (row.asegurado_id as string | null) ?? null,
    analista_id: (row.analista_id as string | null) ?? null,
    gerente_id: (row.gerente_id as string | null) ?? null,
    agente_nombre: agente.nombre ?? null,
    agente_cua: agente.cua ?? null,
    analista_nombre: analista.nombre ?? null,
    gerente_nombre: null,
    poliza_numero: poliza.numero_poliza ?? null,
    asegurado_nombre: asegurado.nombre ?? null,
    correo_origen_email,
    correo_origen_nombre,
    sla_estado: null,
    riesgo_sla: riesgoSla(fechaLimite),
    transiciones_disponibles: [],
  } satisfies TramiteDetalle
}

export default async function TramiteDetallePage({
  params,
}: {
  params: Promise<{ id: string }>
}) {
  const { id } = await params
  const tramite = await fetchTramiteDetalle(id)

  if (!tramite) notFound()

  return (
    <div className="flex h-full min-h-0 flex-col">
      {/* Breadcrumb */}
      <div className="flex items-center gap-2 border-b px-6 py-3">
        <Link
          href="/tramites"
          className="flex items-center gap-1 text-sm text-slate-500 hover:text-slate-700 transition-colors"
        >
          <ChevronLeft className="h-4 w-4" />
          Trámites
        </Link>
        <span className="text-slate-300">/</span>
        <span className="font-mono text-sm font-semibold text-slate-800">{tramite.folio}</span>
      </div>

      {/* Header con folio, estado y badges */}
      <TramiteHeader tramite={tramite} />

      {/* Cuerpo — dos columnas */}
      <div className="flex min-h-0 flex-1 overflow-hidden">
        {/* Panel izquierdo — meta */}
        <aside className="hidden w-72 shrink-0 overflow-y-auto border-r bg-slate-50/50 lg:block xl:w-80">
          <TramiteMeta tramite={tramite} />
        </aside>

        {/* Panel derecho — tabs */}
        <main className="min-w-0 flex-1 overflow-y-auto">
          <TramiteTabs tramiteId={tramite.id} />
        </main>
      </div>
    </div>
  )
}
