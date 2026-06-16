import Link from "next/link"
import { ChevronLeft, ChevronRight } from "lucide-react"
import { getSupabaseServer } from "@/lib/supabase/server"
import { cn } from "@/lib/utils"
import { PolizasView } from "./polizas-view"
import { PolizasFiltros } from "./filters"
import { NuevaPolizaButton } from "./poliza-form"
import type { PolizaRow, VistaValue, AgenteOption, AnalistaOption } from "./types"

const PAGE_SIZE = 50

function Pagination({
  page,
  totalPages,
  totalCount,
  vista,
  ramo,
  estado,
  q,
}: {
  page: number
  totalPages: number
  totalCount: number
  vista: VistaValue
  ramo: string
  estado: string
  q: string
}) {
  function pageUrl(p: number) {
    const params = new URLSearchParams()
    if (vista !== "lista") params.set("vista", vista)
    if (ramo) params.set("ramo", ramo)
    if (estado) params.set("estado", estado)
    if (q) params.set("q", q)
    if (p > 1) params.set("page", String(p))
    const qs = params.toString()
    return `/polizas${qs ? `?${qs}` : ""}`
  }

  const from = (page - 1) * PAGE_SIZE + 1
  const to = Math.min(page * PAGE_SIZE, totalCount)

  const pages: (number | "…")[] = []
  if (totalPages <= 7) {
    for (let i = 1; i <= totalPages; i++) pages.push(i)
  } else {
    pages.push(1)
    if (page > 3) pages.push("…")
    for (let i = Math.max(2, page - 1); i <= Math.min(totalPages - 1, page + 1); i++) pages.push(i)
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
        de <span className="font-medium text-slate-700">{totalCount.toLocaleString("es-MX")}</span>{" "}
        pólizas
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
          <span className="flex h-7 w-7 cursor-not-allowed items-center justify-center rounded border text-slate-300">
            <ChevronLeft className="h-4 w-4" />
          </span>
        )}
        {pages.map((p, i) =>
          p === "…" ? (
            <span key={`e-${i}`} className="flex h-7 w-7 items-center justify-center text-xs text-slate-400">
              …
            </span>
          ) : (
            <Link
              key={p}
              href={pageUrl(p)}
              className={cn(
                "flex h-7 w-7 items-center justify-center rounded border text-xs transition-colors",
                p === page ? "border-slate-900 bg-slate-900 text-white" : "text-slate-600 hover:bg-slate-50"
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
          <span className="flex h-7 w-7 cursor-not-allowed items-center justify-center rounded border text-slate-300">
            <ChevronRight className="h-4 w-4" />
          </span>
        )}
      </div>
    </div>
  )
}

export default async function PolizasPage({
  searchParams,
}: {
  searchParams: Promise<Record<string, string | string[] | undefined>>
}) {
  const params = await searchParams

  const vista: VistaValue = String(params.vista ?? "") === "tarjetas" ? "tarjetas" : "lista"
  const ramo = String(params.ramo ?? "")
  const estado = String(params.estado ?? "")
  const q = String(params.q ?? "").trim()
  const page = Math.max(1, parseInt(String(params.page ?? "1"), 10) || 1)
  const offset = (page - 1) * PAGE_SIZE

  const supabase = await getSupabaseServer()

  // Catálogos para el formulario (agentes + analistas)
  const [agentesRes, analistasRes] = await Promise.all([
    supabase.from("agente").select("id, nombre, cua").eq("activo", true).order("nombre").limit(500),
    supabase
      .from("usuario")
      .select("id, nombre")
      .eq("rol", "analista")
      .eq("activo", true)
      .order("nombre"),
  ])

  const agentes: AgenteOption[] = (agentesRes.data ?? []).map((a) => ({
    id: String(a.id),
    nombre: String(a.nombre),
    cua: a.cua ? String(a.cua) : null,
  }))
  const analistas: AnalistaOption[] = (analistasRes.data ?? []).map((u) => ({
    id: String(u.id),
    nombre: String(u.nombre),
  }))

  // Lista de pólizas (RLS por rol)
  let query = supabase
    .from("poliza")
    .select(
      `
        id, numero_poliza, ramo, estado, plan, fecha_inicio, fecha_fin,
        prima_neta, moneda, activo,
        agente:agente_id ( nombre, cua ),
        analista:usuario!poliza_analista_id_fkey ( nombre )
      `,
      { count: "exact" }
    )
    .eq("activo", true)
    .order("created_at", { ascending: false })
    .range(offset, offset + PAGE_SIZE - 1)

  if (ramo) query = query.eq("ramo", ramo)
  if (estado) query = query.eq("estado", estado)
  if (q) query = query.ilike("numero_poliza", `%${q}%`)

  const { data, count } = await query
  const totalCount = count ?? 0

  const rows: PolizaRow[] = (data ?? []).map((p) => ({
    id: String(p.id),
    numero_poliza: String(p.numero_poliza),
    ramo: String(p.ramo),
    estado: String(p.estado),
    plan: p.plan ? String(p.plan) : null,
    fecha_inicio: (p.fecha_inicio as string | null) ?? null,
    fecha_fin: (p.fecha_fin as string | null) ?? null,
    prima_neta: (p.prima_neta as number | string | null) ?? null,
    moneda: p.moneda ? String(p.moneda) : null,
    activo: Boolean(p.activo),
    agente_nombre: (p.agente as { nombre?: string } | null)?.nombre ?? null,
    agente_cua: (p.agente as { cua?: string } | null)?.cua ?? null,
    analista_nombre: (p.analista as { nombre?: string } | null)?.nombre ?? null,
  }))

  const totalPages = Math.max(1, Math.ceil(totalCount / PAGE_SIZE))
  const hasFilters = !!(ramo || estado || q)

  return (
    <div className="space-y-5">
      {/* Header */}
      <div className="flex items-start justify-between gap-3">
        <div>
          <h2 className="text-xl font-bold text-slate-900">Pólizas</h2>
          <p className="text-sm text-muted-foreground">
            Gestión de pólizas y trámites con ficha completa e historial
          </p>
        </div>
        <NuevaPolizaButton agentes={agentes} analistas={analistas} />
      </div>

      {/* Filtros */}
      <PolizasFiltros vista={vista} ramo={ramo} estado={estado} q={q} />

      {/* Vista */}
      <PolizasView rows={rows} vista={vista} hasFilters={hasFilters} />

      {/* Paginación */}
      {totalCount > PAGE_SIZE && (
        <div className="overflow-hidden rounded-xl border bg-white shadow-sm">
          <Pagination
            page={page}
            totalPages={totalPages}
            totalCount={totalCount}
            vista={vista}
            ramo={ramo}
            estado={estado}
            q={q}
          />
        </div>
      )}
    </div>
  )
}
