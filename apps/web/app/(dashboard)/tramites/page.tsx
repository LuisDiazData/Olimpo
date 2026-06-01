import Link from "next/link"
import { AlertTriangle, ChevronLeft, ChevronRight } from "lucide-react"
import { getSupabaseServer } from "@/lib/supabase/server"
import { cn } from "@/lib/utils"
import { TramitesView } from "./tramites-view"
import { TramitesFiltros } from "./filters"
import { riesgoSla } from "./shared"
import type { TramiteRow, GerenteOption, TabValue, VistaValue } from "./types"

const PAGE_SIZE = 50

// ─────────────────────────────────────────────────────────────────────────────
// Sub-componentes de presentación (Server)
// ─────────────────────────────────────────────────────────────────────────────

function EscaladosBanner({ count }: { count: number }) {
  return (
    <div className="flex items-start gap-3 rounded-xl border border-red-200 bg-red-50 px-4 py-3.5">
      <AlertTriangle className="mt-0.5 h-5 w-5 shrink-0 text-red-500" />
      <div>
        <p className="text-sm font-semibold text-red-800">
          {count} {count === 1 ? "caso escalado requiere" : "casos escalados requieren"} tu atención
        </p>
        <p className="mt-0.5 text-xs text-red-600">
          El agente IA no pudo resolver estos trámites de forma automática. Requieren
          una decisión o acción directa del equipo.
        </p>
      </div>
    </div>
  )
}

function Pagination({
  page,
  totalPages,
  totalCount,
  tab,
  vista,
  ramo,
  gerenteId,
  estado,
  prioridad,
  agenteQuery,
}: {
  page: number
  totalPages: number
  totalCount: number
  tab: string
  vista: VistaValue
  ramo: string
  gerenteId: string
  estado: string
  prioridad: string
  agenteQuery: string
}) {
  function pageUrl(p: number) {
    const params = new URLSearchParams()
    if (tab !== "todos") params.set("tab", tab)
    if (vista !== "lista") params.set("vista", vista)
    if (ramo) params.set("ramo", ramo)
    if (gerenteId) params.set("gerente", gerenteId)
    if (estado) params.set("estado", estado)
    if (prioridad) params.set("prioridad", prioridad)
    if (agenteQuery) params.set("agente", agenteQuery)
    if (p > 1) params.set("page", String(p))
    const qs = params.toString()
    return `/tramites${qs ? `?${qs}` : ""}`
  }

  const from = (page - 1) * PAGE_SIZE + 1
  const to = Math.min(page * PAGE_SIZE, totalCount)

  const pages: (number | "…")[] = []
  if (totalPages <= 7) {
    for (let i = 1; i <= totalPages; i++) pages.push(i)
  } else {
    pages.push(1)
    if (page > 3) pages.push("…")
    for (let i = Math.max(2, page - 1); i <= Math.min(totalPages - 1, page + 1); i++) {
      pages.push(i)
    }
    if (page < totalPages - 2) pages.push("…")
    pages.push(totalPages)
  }

  return (
    <div className="flex items-center justify-between border-t bg-white px-4 py-3">
      <p className="text-xs text-slate-500">
        Mostrando{" "}
        <span className="font-medium text-slate-700">
          {from.toLocaleString("es-MX")}–{to.toLocaleString("es-MX")}
        </span>{" "}
        de{" "}
        <span className="font-medium text-slate-700">
          {totalCount.toLocaleString("es-MX")}
        </span>{" "}
        trámites
      </p>

      <div className="flex items-center gap-1">
        {page > 1 ? (
          <Link
            href={pageUrl(page - 1)}
            className="flex h-7 w-7 items-center justify-center rounded border text-slate-600 hover:bg-slate-50"
          >
            <ChevronLeft className="h-4 w-4" />
          </Link>
        ) : (
          <span className="flex h-7 w-7 items-center justify-center rounded border text-slate-300 cursor-not-allowed">
            <ChevronLeft className="h-4 w-4" />
          </span>
        )}

        {pages.map((p, i) =>
          p === "…" ? (
            <span
              key={`ellipsis-${i}`}
              className="flex h-7 w-7 items-center justify-center text-xs text-slate-400"
            >
              …
            </span>
          ) : (
            <Link
              key={p}
              href={pageUrl(p)}
              className={cn(
                "flex h-7 w-7 items-center justify-center rounded border text-xs transition-colors",
                p === page
                  ? "border-slate-900 bg-slate-900 text-white"
                  : "text-slate-600 hover:bg-slate-50"
              )}
            >
              {p}
            </Link>
          )
        )}

        {page < totalPages ? (
          <Link
            href={pageUrl(page + 1)}
            className="flex h-7 w-7 items-center justify-center rounded border text-slate-600 hover:bg-slate-50"
          >
            <ChevronRight className="h-4 w-4" />
          </Link>
        ) : (
          <span className="flex h-7 w-7 items-center justify-center rounded border text-slate-300 cursor-not-allowed">
            <ChevronRight className="h-4 w-4" />
          </span>
        )}
      </div>
    </div>
  )
}

// ─────────────────────────────────────────────────────────────────────────────
// Page — Server Component
// ─────────────────────────────────────────────────────────────────────────────

export default async function TramitesPage({
  searchParams,
}: {
  searchParams: Promise<Record<string, string | string[] | undefined>>
}) {
  const params = await searchParams

  const tab: TabValue =
    String(params.tab ?? "") === "escalados" ? "escalados" : "todos"
  const vista: VistaValue =
    String(params.vista ?? "") === "tarjetas" ? "tarjetas" : "lista"
  const ramo = String(params.ramo ?? "")
  const gerenteId = String(params.gerente ?? "")
  const estado = String(params.estado ?? "")
  const prioridad = String(params.prioridad ?? "")
  const agenteQuery = String(params.agente ?? "").trim()
  const page = Math.max(1, parseInt(String(params.page ?? "1"), 10) || 1)
  const offset = (page - 1) * PAGE_SIZE

  const supabase = await getSupabaseServer()

  // ── Fetch filter catalogs + escalados count in parallel ──────────────────
  const [gerentesRes, escaladosCountRes, agenteSearchRes] = await Promise.all([
    supabase
      .from("usuario")
      .select("id, nombre")
      .eq("rol", "gerente")
      .eq("activo", true)
      .order("nombre"),

    supabase
      .from("tramite")
      .select("*", { count: "exact", head: true })
      .eq("activo", true)
      .eq("requiere_atencion", true)
      .not("estado", "in", "(completado,rechazado_gnp,cancelado)"),

    agenteQuery
      ? supabase
          .from("agente")
          .select("id")
          .or(`nombre.ilike.%${agenteQuery}%,cua.ilike.%${agenteQuery}%`)
          .limit(200)
      : Promise.resolve({ data: null, error: null }),
  ])

  const gerentes: GerenteOption[] = (gerentesRes.data ?? []).map((g) => ({
    id: String(g.id),
    nombre: String(g.nombre),
  }))

  const escaladosCount = escaladosCountRes.count ?? 0

  const agenteIds: string[] | null = agenteSearchRes.data
    ? (agenteSearchRes.data as { id: string }[]).map((a) => a.id)
    : null

  const noAgenteResults = agenteQuery !== "" && agenteIds !== null && agenteIds.length === 0

  // ── Build main tramites query ─────────────────────────────────────────────
  let tramiteCount = 0
  let rows: TramiteRow[] = []
  const hasFilters = !!(ramo || gerenteId || estado || prioridad || agenteQuery)

  if (!noAgenteResults) {
    let q = supabase
      .from("tramite")
      .select(
        `
          id, folio, folio_ot, tipo_tramite, titulo, estado, prioridad, ramo,
          requiere_atencion, fecha_recepcion, ultima_actividad, fecha_limite_sla,
          resumen_ia,
          agente:agente_id ( nombre, cua ),
          analista:usuario!analista_id ( nombre ),
          gerente:usuario!gerente_id ( nombre ),
          sla:sla_tramite ( estado, fecha_limite )
        `,
        { count: "exact" }
      )
      .eq("activo", true)
      .order("ultima_actividad", { ascending: false })
      .range(offset, offset + PAGE_SIZE - 1)

    if (tab === "escalados") q = q.eq("requiere_atencion", true).not("estado", "in", "('completado','rechazado_gnp','cancelado')")
    if (ramo) q = q.eq("ramo", ramo)
    if (gerenteId) q = q.eq("gerente_id", gerenteId)
    if (estado) q = q.eq("estado", estado)
    if (prioridad) q = q.eq("prioridad", prioridad)
    if (agenteIds && agenteIds.length > 0) q = q.in("agente_id", agenteIds)

    const { data, count } = await q
    tramiteCount = count ?? 0

    rows = (data ?? []).map((t) => {
      const sla = Array.isArray(t.sla) ? (t.sla[0] ?? null) : (t.sla ?? null)
      const slaFecha = (sla?.fecha_limite as string) ?? (t.fecha_limite_sla as string) ?? null

      return {
        id: String(t.id),
        folio: String(t.folio),
        folio_ot: t.folio_ot ? String(t.folio_ot) : null,
        tipo_tramite: String(t.tipo_tramite),
        titulo: String(t.titulo),
        estado: String(t.estado),
        prioridad: String(t.prioridad),
        ramo: t.ramo ? String(t.ramo) : null,
        requiere_atencion: Boolean(t.requiere_atencion),
        fecha_recepcion: String(t.fecha_recepcion),
        ultima_actividad: String(t.ultima_actividad),
        fecha_limite_sla: slaFecha,
        agente_nombre: (t.agente as { nombre?: string } | null)?.nombre ?? null,
        agente_cua: (t.agente as { cua?: string } | null)?.cua ?? null,
        analista_nombre: (t.analista as { nombre?: string } | null)?.nombre ?? null,
        gerente_nombre: (t.gerente as { nombre?: string } | null)?.nombre ?? null,
        sla_estado: (sla?.estado as string) ?? null,
        riesgo_sla: riesgoSla(slaFecha),
        resumen_ia: t.resumen_ia ? String(t.resumen_ia) : null,
      }
    })
  }

  const totalPages = Math.max(1, Math.ceil(tramiteCount / PAGE_SIZE))

  // ─────────────────────────────────────────────────────────────────────────
  // Render
  // ─────────────────────────────────────────────────────────────────────────

  return (
    <div className="space-y-5">
      {/* Header */}
      <div>
        <h2 className="text-xl font-bold text-slate-900">Trámites</h2>
        <p className="text-sm text-muted-foreground">Vista completa · Director General</p>
      </div>

      {/* Tabs + Filters + View toggle (Client Component) */}
      <TramitesFiltros
        gerentes={gerentes}
        tab={tab}
        vista={vista}
        ramo={ramo}
        gerenteId={gerenteId}
        estado={estado}
        prioridad={prioridad}
        agenteQuery={agenteQuery}
        tramiteCount={tramiteCount}
        escaladosCount={escaladosCount}
      />

      {/* Escalados banner */}
      {tab === "escalados" && escaladosCount > 0 && (
        <EscaladosBanner count={escaladosCount} />
      )}

      {/* No agente results notice */}
      {noAgenteResults && (
        <div className="rounded-lg border border-amber-200 bg-amber-50 px-4 py-3 text-sm text-amber-800">
          No se encontró ningún agente con el nombre o CUA{" "}
          <strong>&quot;{agenteQuery}&quot;</strong>. Verifica el texto ingresado.
        </div>
      )}

      {/* Main view with toggle */}
      <TramitesView rows={rows} tab={tab} vista={vista} hasFilters={hasFilters || tab === "escalados"} />

      {/* Pagination */}
      {tramiteCount > PAGE_SIZE && (
        <div className="overflow-hidden rounded-xl border bg-white shadow-sm">
          <Pagination
            page={page}
            totalPages={totalPages}
            totalCount={tramiteCount}
            tab={tab}
            vista={vista}
            ramo={ramo}
            gerenteId={gerenteId}
            estado={estado}
            prioridad={prioridad}
            agenteQuery={agenteQuery}
          />
        </div>
      )}
    </div>
  )
}
