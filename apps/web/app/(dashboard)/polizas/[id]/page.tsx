import { notFound } from "next/navigation"
import Link from "next/link"
import { ChevronLeft } from "lucide-react"
import { getSupabaseServer } from "@/lib/supabase/server"
import type { PolizaDetalle, AseguradoVinculo, AgenteOption, AnalistaOption } from "../types"
import { PolizaHeader } from "./poliza-header"
import { PolizaMeta } from "./poliza-meta"
import { PolizaTabs } from "./poliza-tabs"

export const dynamic = "force-dynamic"

async function fetchPolizaDetalle(id: string): Promise<PolizaDetalle | null> {
  const supabase = await getSupabaseServer()

  const { data, error } = await supabase
    .from("poliza")
    .select(`
      id, numero_poliza, ramo, estado, plan, fecha_inicio, fecha_fin,
      prima_neta, moneda, porcentaje_comision, monto_comision, datos_ramo, notas,
      activo, created_at, updated_at, agente_id, analista_id,
      agente:agente_id ( nombre, cua ),
      analista:usuario!poliza_analista_id_fkey ( nombre ),
      poliza_asegurado (
        id, asegurado_id, rol, parentesco, porcentaje,
        asegurado:asegurado_id ( nombre, rfc )
      )
    `)
    .eq("id", id)
    .single()

  if (error || !data) return null

  const row = data as Record<string, unknown>
  const agente = (row.agente as Record<string, string> | null) ?? {}
  const analista = (row.analista as Record<string, string> | null) ?? {}

  const vinculos = (row.poliza_asegurado as Record<string, unknown>[] | null) ?? []
  const asegurados: AseguradoVinculo[] = vinculos.map((v) => {
    const aseg = (v.asegurado as Record<string, string> | null) ?? {}
    return {
      id: String(v.id),
      asegurado_id: String(v.asegurado_id),
      asegurado_nombre: aseg.nombre ?? null,
      asegurado_rfc: aseg.rfc ?? null,
      rol: String(v.rol),
      parentesco: (v.parentesco as string | null) ?? null,
      porcentaje: (v.porcentaje as number | string | null) ?? null,
    }
  })

  return {
    id: row.id as string,
    numero_poliza: row.numero_poliza as string,
    ramo: row.ramo as string,
    estado: row.estado as string,
    plan: (row.plan as string | null) ?? null,
    fecha_inicio: (row.fecha_inicio as string | null) ?? null,
    fecha_fin: (row.fecha_fin as string | null) ?? null,
    prima_neta: (row.prima_neta as number | string | null) ?? null,
    moneda: (row.moneda as string | null) ?? null,
    activo: Boolean(row.activo),
    agente_nombre: agente.nombre ?? null,
    agente_cua: agente.cua ?? null,
    analista_nombre: analista.nombre ?? null,
    agente_id: row.agente_id as string,
    analista_id: (row.analista_id as string | null) ?? null,
    porcentaje_comision: (row.porcentaje_comision as number | string | null) ?? null,
    monto_comision: (row.monto_comision as number | string | null) ?? null,
    datos_ramo: (row.datos_ramo as Record<string, unknown>) ?? {},
    notas: (row.notas as string | null) ?? null,
    created_at: row.created_at as string,
    updated_at: row.updated_at as string,
    asegurados,
  } satisfies PolizaDetalle
}

async function fetchOpciones(): Promise<{ agentes: AgenteOption[]; analistas: AnalistaOption[] }> {
  const supabase = await getSupabaseServer()
  const [agentesRes, analistasRes] = await Promise.all([
    supabase.from("agente").select("id, nombre, cua").eq("activo", true).order("nombre").limit(500),
    supabase
      .from("usuario")
      .select("id, nombre")
      .eq("rol", "analista")
      .eq("activo", true)
      .order("nombre"),
  ])
  return {
    agentes: (agentesRes.data ?? []).map((a) => ({
      id: String(a.id),
      nombre: String(a.nombre),
      cua: a.cua ? String(a.cua) : null,
    })),
    analistas: (analistasRes.data ?? []).map((u) => ({
      id: String(u.id),
      nombre: String(u.nombre),
    })),
  }
}

export default async function PolizaDetallePage({
  params,
}: {
  params: Promise<{ id: string }>
}) {
  const { id } = await params
  const [poliza, opciones] = await Promise.all([fetchPolizaDetalle(id), fetchOpciones()])

  if (!poliza) notFound()

  return (
    <div className="flex h-full min-h-0 flex-col">
      {/* Breadcrumb */}
      <div className="flex items-center gap-2 border-b px-6 py-3">
        <Link
          href="/polizas"
          className="flex items-center gap-1 text-sm text-slate-500 transition-colors hover:text-slate-700"
        >
          <ChevronLeft className="h-4 w-4" />
          Pólizas
        </Link>
        <span className="text-slate-300">/</span>
        <span className="font-mono text-sm font-semibold text-slate-800">{poliza.numero_poliza}</span>
      </div>

      {/* Header */}
      <PolizaHeader poliza={poliza} agentes={opciones.agentes} analistas={opciones.analistas} />

      {/* Cuerpo — dos columnas */}
      <div className="flex min-h-0 flex-1 overflow-hidden">
        <aside className="hidden w-72 shrink-0 overflow-y-auto border-r bg-slate-50/50 lg:block xl:w-80">
          <PolizaMeta poliza={poliza} />
        </aside>
        <main className="min-w-0 flex-1 overflow-y-auto">
          <PolizaTabs polizaId={poliza.id} aseguradosIniciales={poliza.asegurados} />
        </main>
      </div>
    </div>
  )
}
