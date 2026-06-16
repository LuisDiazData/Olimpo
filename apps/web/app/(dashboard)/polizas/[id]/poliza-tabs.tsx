"use client"

import * as React from "react"
import Link from "next/link"
import {
  Clock,
  FileText,
  Users,
  Coins,
  Paperclip,
  CheckCircle,
  Building2,
  ArrowDownRight,
} from "lucide-react"
import { cn } from "@/lib/utils"
import { Badge } from "@/components/ui/badge"
import { api } from "@/lib/api"
import { ESTADO_BADGE, TIPO_BADGE } from "../../tramites/shared"
import { formatFechaCorta, formatFecha, formatMoney, relativeTime } from "../shared"
import { AseguradosManager } from "./asegurados-manager"
import type {
  EventoPoliza,
  TramiteDePoliza,
  ReciboComision,
  DocumentoPoliza,
  AseguradoVinculo,
} from "../types"

type TabId = "historial" | "tramites" | "asegurados" | "comisiones" | "documentos"

const VALIDACION_CONFIG: Record<string, { label: string; variant: Parameters<typeof Badge>[0]["variant"] }> = {
  valido: { label: "Válido", variant: "emerald" },
  invalido: { label: "Inválido", variant: "red" },
  pendiente_validacion: { label: "Pendiente", variant: "amber" },
  ilegible: { label: "Ilegible", variant: "orange" },
  vencido: { label: "Vencido", variant: "rose" },
  duplicado: { label: "Duplicado", variant: "violet" },
}

// ---------------------------------------------------------------------------
// Sub-componentes
// ---------------------------------------------------------------------------

function EventoItem({ evento }: { evento: EventoPoliza }) {
  const esComision = evento.fuente === "comision"
  const esActivacion = evento.tipo === "activacion_gnp"
  const esCambioEstado = evento.tipo === "cambio_estado"

  const Icon = esComision ? Coins : esActivacion ? Building2 : esCambioEstado ? CheckCircle : null

  return (
    <div className="flex gap-3 py-3">
      <div
        className={cn(
          "mt-0.5 flex h-6 w-6 shrink-0 items-center justify-center rounded-full",
          esComision ? "bg-emerald-50 text-emerald-500" : "bg-slate-100 text-slate-400"
        )}
      >
        {Icon ? <Icon className="h-3.5 w-3.5" /> : <div className="h-1.5 w-1.5 rounded-full bg-current" />}
      </div>
      <div className="min-w-0 flex-1">
        <div className="flex items-baseline justify-between gap-2">
          <span className="text-xs font-medium text-slate-600">{evento.titulo}</span>
          <span className="shrink-0 text-[11px] text-slate-400">{formatFechaCorta(evento.fecha)}</span>
        </div>
        <p className="mt-0.5 text-sm text-slate-700">{evento.descripcion}</p>
        <div className="mt-1 flex flex-wrap items-center gap-2 text-[11px] text-slate-400">
          {evento.actor && <span>{evento.actor}</span>}
          {evento.tramite_folio && evento.tramite_id && (
            <Link
              href={`/tramites/${evento.tramite_id}`}
              className="font-mono text-blue-600 hover:underline"
            >
              {evento.tramite_folio}
            </Link>
          )}
        </div>
      </div>
    </div>
  )
}

function TramiteItem({ t }: { t: TramiteDePoliza }) {
  const estado = ESTADO_BADGE[t.estado]
  const tipo = TIPO_BADGE[t.tipo_tramite]
  return (
    <Link
      href={`/tramites/${t.id}`}
      className="flex items-center justify-between gap-3 rounded-lg border px-3 py-2.5 transition-colors hover:bg-slate-50"
    >
      <div className="min-w-0">
        <div className="flex items-center gap-2">
          <span className="font-mono text-xs font-semibold text-slate-800">{t.folio}</span>
          {tipo && <Badge variant={tipo.variant}>{tipo.label}</Badge>}
        </div>
        <p className="mt-0.5 truncate text-xs text-slate-500">{t.titulo}</p>
      </div>
      <div className="flex shrink-0 flex-col items-end gap-1">
        {estado && <Badge variant={estado.variant}>{estado.label}</Badge>}
        <span className="text-[11px] text-slate-400">{relativeTime(t.ultima_actividad)}</span>
      </div>
    </Link>
  )
}

function ReciboItem({ r }: { r: ReciboComision }) {
  return (
    <div
      className={cn(
        "flex items-center justify-between gap-3 rounded-lg border px-3 py-2.5",
        r.es_estorno && "border-red-200 bg-red-50/40"
      )}
    >
      <div className="flex min-w-0 items-center gap-2">
        <div
          className={cn(
            "flex h-7 w-7 shrink-0 items-center justify-center rounded-full",
            r.es_estorno ? "bg-red-100 text-red-600" : "bg-emerald-100 text-emerald-600"
          )}
        >
          {r.es_estorno ? <ArrowDownRight className="h-3.5 w-3.5" /> : <Coins className="h-3.5 w-3.5" />}
        </div>
        <div className="min-w-0">
          <p className="text-sm text-slate-700">
            {r.es_estorno ? "Estorno" : "Comisión"}
            {r.numero_recibo && <span className="ml-1 text-slate-400">· {r.numero_recibo}</span>}
          </p>
          <p className="text-[11px] text-slate-400">
            {r.fecha_pago ? formatFecha(r.fecha_pago) : "Sin fecha de pago"} · Prima{" "}
            {formatMoney(r.prima_pagada, r.moneda)}
          </p>
        </div>
      </div>
      <div className="shrink-0 text-right">
        <p className={cn("text-sm font-semibold", r.es_estorno ? "text-red-600" : "text-slate-800")}>
          {formatMoney(r.comision_total, r.moneda)}
        </p>
        <p className="text-[11px] text-slate-400">Agente {formatMoney(r.comision_agente, r.moneda)}</p>
      </div>
    </div>
  )
}

function DocumentoItem({ doc }: { doc: DocumentoPoliza }) {
  const config = VALIDACION_CONFIG[doc.estado_validacion] ?? {
    label: doc.estado_validacion,
    variant: "slate" as const,
  }
  return (
    <div className="flex items-center justify-between gap-3 rounded-lg border px-3 py-2.5">
      <div className="flex min-w-0 items-center gap-2">
        <FileText className="h-4 w-4 shrink-0 text-slate-400" />
        <div className="min-w-0">
          <p className="truncate text-sm text-slate-700">{doc.adjunto_nombre ?? doc.tipo_documento}</p>
          <p className="text-[11px] text-slate-400">
            {doc.tipo_documento}
            {doc.vigente_hasta && <span className="ml-1.5">vence {formatFecha(doc.vigente_hasta)}</span>}
          </p>
        </div>
      </div>
      <Badge variant={config.variant}>{config.label}</Badge>
    </div>
  )
}

// ---------------------------------------------------------------------------
// Componente principal
// ---------------------------------------------------------------------------

interface Props {
  polizaId: string
  aseguradosIniciales: AseguradoVinculo[]
}

export function PolizaTabs({ polizaId, aseguradosIniciales }: Props) {
  const [activeTab, setActiveTab] = React.useState<TabId>("historial")
  const [loading, setLoading] = React.useState(true)
  const [historial, setHistorial] = React.useState<EventoPoliza[]>([])
  const [tramites, setTramites] = React.useState<TramiteDePoliza[]>([])
  const [comisiones, setComisiones] = React.useState<ReciboComision[]>([])
  const [documentos, setDocumentos] = React.useState<DocumentoPoliza[]>([])

  const TABS: { id: TabId; label: string; icon: React.ElementType; count?: number }[] = [
    { id: "historial", label: "Historial", icon: Clock },
    { id: "tramites", label: "Trámites", icon: FileText, count: tramites.length },
    { id: "asegurados", label: "Asegurados", icon: Users, count: aseguradosIniciales.length },
    { id: "comisiones", label: "Comisiones", icon: Coins, count: comisiones.length },
    { id: "documentos", label: "Documentos", icon: Paperclip, count: documentos.length },
  ]

  React.useEffect(() => {
    let cancelled = false
    setLoading(true)
    Promise.all([
      api.get<EventoPoliza[]>(`/polizas/${polizaId}/historial`).catch(() => []),
      api.get<TramiteDePoliza[]>(`/polizas/${polizaId}/tramites`).catch(() => []),
      api.get<ReciboComision[]>(`/polizas/${polizaId}/comisiones`).catch(() => []),
      api.get<DocumentoPoliza[]>(`/polizas/${polizaId}/documentos`).catch(() => []),
    ]).then(([hist, tr, com, docs]) => {
      if (cancelled) return
      setHistorial(hist ?? [])
      setTramites(tr ?? [])
      setComisiones(com ?? [])
      setDocumentos(docs ?? [])
      setLoading(false)
    })
    return () => {
      cancelled = true
    }
  }, [polizaId])

  return (
    <div className="flex h-full flex-col">
      {/* Tab bar */}
      <div className="scrollbar-none flex overflow-x-auto border-b px-6">
        {TABS.map((tab) => {
          const Icon = tab.icon
          return (
            <button
              key={tab.id}
              onClick={() => setActiveTab(tab.id)}
              className={cn(
                "flex items-center gap-1.5 whitespace-nowrap border-b-2 px-3 py-2.5 text-sm transition-colors",
                activeTab === tab.id
                  ? "border-slate-900 font-semibold text-slate-900"
                  : "border-transparent text-slate-500 hover:text-slate-700"
              )}
            >
              <Icon className="h-4 w-4" />
              {tab.label}
              {tab.count != null && tab.count > 0 && (
                <span className="rounded-full bg-slate-100 px-1.5 text-[11px] font-medium text-slate-500">
                  {tab.count}
                </span>
              )}
            </button>
          )
        })}
      </div>

      {/* Content */}
      <div className="flex-1 px-6 py-4">
        {loading && activeTab !== "asegurados" ? (
          <div className="flex items-center justify-center py-12 text-sm text-slate-400">Cargando…</div>
        ) : (
          <>
            {activeTab === "historial" && (
              <div className="divide-y">
                {historial.length === 0 ? (
                  <p className="py-8 text-center text-sm text-slate-400">Sin eventos en el historial</p>
                ) : (
                  historial.map((e, i) => <EventoItem key={`${e.fuente}-${i}`} evento={e} />)
                )}
              </div>
            )}

            {activeTab === "tramites" && (
              <div className="space-y-2">
                {tramites.length === 0 ? (
                  <p className="py-8 text-center text-sm text-slate-400">Sin trámites vinculados</p>
                ) : (
                  tramites.map((t) => <TramiteItem key={t.id} t={t} />)
                )}
              </div>
            )}

            {activeTab === "asegurados" && (
              <AseguradosManager polizaId={polizaId} aseguradosIniciales={aseguradosIniciales} />
            )}

            {activeTab === "comisiones" && (
              <div className="space-y-2">
                {comisiones.length === 0 ? (
                  <p className="py-8 text-center text-sm text-slate-400">Sin movimientos de comisión</p>
                ) : (
                  comisiones.map((r) => <ReciboItem key={r.id} r={r} />)
                )}
              </div>
            )}

            {activeTab === "documentos" && (
              <div className="space-y-2">
                {documentos.length === 0 ? (
                  <p className="py-8 text-center text-sm text-slate-400">Sin documentos</p>
                ) : (
                  documentos.map((d) => <DocumentoItem key={d.id} doc={d} />)
                )}
              </div>
            )}
          </>
        )}
      </div>
    </div>
  )
}
