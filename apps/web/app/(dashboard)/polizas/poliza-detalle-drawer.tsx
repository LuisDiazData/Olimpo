"use client"

import * as React from "react"
import Link from "next/link"
import { ArrowUpRight, Building2, FileText, Users, X } from "lucide-react"
import { Badge } from "@/components/ui/badge"
import { api } from "@/lib/api"
import {
  ESTADO_POLIZA_BADGE,
  RAMO_BADGE,
  ROL_ASEGURADO_BADGE,
  formatMoney,
  vigenciaLabel,
} from "./shared"
import { ESTADO_BADGE, TIPO_BADGE } from "../tramites/shared"
import type { PolizaRow, AseguradoVinculo, TramiteDePoliza } from "./types"

interface DrawerPolizaApi {
  analista_nombre: string | null
  porcentaje_comision: number | string | null
  monto_comision: number | string | null
  asegurados: AseguradoVinculo[]
}

interface Props {
  poliza: PolizaRow | null
  onClose: () => void
}

export function PolizaDetalleDrawer({ poliza, onClose }: Props) {
  const [loading, setLoading] = React.useState(false)
  const [detalle, setDetalle] = React.useState<DrawerPolizaApi | null>(null)
  const [tramites, setTramites] = React.useState<TramiteDePoliza[]>([])

  React.useEffect(() => {
    if (!poliza) return
    const handleKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") onClose()
    }
    document.addEventListener("keydown", handleKey)
    return () => document.removeEventListener("keydown", handleKey)
  }, [poliza, onClose])

  React.useEffect(() => {
    if (!poliza) return
    setLoading(true)
    setDetalle(null)
    setTramites([])

    Promise.all([
      api.get<DrawerPolizaApi>(`/polizas/${poliza.id}`).catch(() => null),
      api.get<TramiteDePoliza[]>(`/polizas/${poliza.id}/tramites`).catch(() => []),
    ]).then(([det, tr]) => {
      setDetalle(det)
      setTramites(tr ?? [])
      setLoading(false)
    })
  }, [poliza])

  if (!poliza) return null

  const estado = ESTADO_POLIZA_BADGE[poliza.estado]
  const ramo = RAMO_BADGE[poliza.ramo]
  const asegurados = detalle?.asegurados ?? []
  const titular = asegurados.find((a) => a.rol === "titular")

  return (
    <>
      <div className="fixed inset-0 z-40 bg-black/40 backdrop-blur-sm" onClick={onClose} />
      <div
        className="fixed right-0 top-0 z-50 flex h-full w-full flex-col bg-white shadow-xl animate-in slide-in-from-right duration-300 sm:max-w-lg"
        role="dialog"
        aria-modal="true"
      >
        {/* Header */}
        <div className="border-b px-6 py-4">
          <div className="flex items-start justify-between">
            <div className="min-w-0">
              <div className="flex items-center gap-2">
                <span className="font-mono text-base font-bold text-slate-900">
                  {poliza.numero_poliza}
                </span>
                {estado && <Badge variant={estado.variant}>{estado.label}</Badge>}
              </div>
              {titular?.asegurado_nombre && (
                <p className="mt-1 truncate text-sm text-slate-500">
                  Titular: {titular.asegurado_nombre}
                </p>
              )}
            </div>
            <div className="ml-2 flex shrink-0 items-center gap-1">
              <Link
                href={`/polizas/${poliza.id}`}
                onClick={onClose}
                className="flex items-center gap-1 rounded-md px-2 py-1.5 text-xs font-medium text-slate-500 transition-colors hover:bg-slate-100 hover:text-slate-700"
                title="Ver ficha completa"
              >
                <ArrowUpRight className="h-3.5 w-3.5" />
                Ficha completa
              </Link>
              <button
                onClick={onClose}
                className="rounded-md p-1.5 text-slate-400 transition-colors hover:bg-slate-100 hover:text-slate-600"
              >
                <X className="h-5 w-5" />
              </button>
            </div>
          </div>
          <div className="mt-2 flex flex-wrap gap-1.5">
            {ramo && <Badge variant={ramo.variant}>{ramo.label}</Badge>}
            {poliza.plan && (
              <span className="rounded-full border border-slate-200 bg-slate-50 px-2 py-0.5 text-[11px] font-medium text-slate-500">
                {poliza.plan}
              </span>
            )}
          </div>
        </div>

        <div className="flex-1 overflow-y-auto">
          {/* Datos */}
          <div className="grid grid-cols-2 gap-px border-b bg-slate-100">
            <div className="bg-white px-4 py-3">
              <p className="text-[10px] uppercase tracking-wider text-slate-400">Vigencia</p>
              <p className="mt-0.5 text-sm text-slate-700">
                {vigenciaLabel(poliza.fecha_inicio, poliza.fecha_fin)}
              </p>
            </div>
            <div className="bg-white px-4 py-3">
              <p className="text-[10px] uppercase tracking-wider text-slate-400">Prima neta</p>
              <p className="mt-0.5 text-sm font-semibold text-slate-700">
                {formatMoney(poliza.prima_neta, poliza.moneda ?? "MXN")}
              </p>
            </div>
            <div className="bg-white px-4 py-3">
              <p className="text-[10px] uppercase tracking-wider text-slate-400">Agente</p>
              <p className="mt-0.5 truncate text-sm text-slate-700">
                {poliza.agente_nombre ?? "—"}
              </p>
            </div>
            <div className="bg-white px-4 py-3">
              <p className="text-[10px] uppercase tracking-wider text-slate-400">Analista</p>
              <p className="mt-0.5 truncate text-sm text-slate-700">
                {detalle?.analista_nombre ?? poliza.analista_nombre ?? "Sin asignar"}
              </p>
            </div>
          </div>

          {loading ? (
            <div className="flex items-center justify-center py-10 text-sm text-slate-400">
              Cargando…
            </div>
          ) : (
            <>
              {/* Asegurados */}
              <div className="border-b px-6 py-4">
                <h3 className="mb-3 flex items-center gap-1.5 text-xs font-semibold uppercase tracking-wider text-slate-400">
                  <Users className="h-3.5 w-3.5" /> Asegurados
                </h3>
                {asegurados.length === 0 ? (
                  <p className="text-sm italic text-slate-400">Sin asegurados vinculados</p>
                ) : (
                  <div className="space-y-1.5">
                    {asegurados.map((a) => {
                      const rol = ROL_ASEGURADO_BADGE[a.rol]
                      return (
                        <div
                          key={a.id}
                          className="flex items-center justify-between gap-2 rounded-lg border px-3 py-2"
                        >
                          <span className="truncate text-sm text-slate-700">
                            {a.asegurado_nombre ?? "—"}
                          </span>
                          {rol ? (
                            <Badge variant={rol.variant}>{rol.label}</Badge>
                          ) : (
                            <Badge variant="slate">{a.rol}</Badge>
                          )}
                        </div>
                      )
                    })}
                  </div>
                )}
              </div>

              {/* Trámites */}
              <div className="px-6 py-4">
                <h3 className="mb-3 flex items-center gap-1.5 text-xs font-semibold uppercase tracking-wider text-slate-400">
                  <FileText className="h-3.5 w-3.5" /> Trámites ({tramites.length})
                </h3>
                {tramites.length === 0 ? (
                  <p className="text-sm italic text-slate-400">Sin trámites vinculados</p>
                ) : (
                  <div className="space-y-1.5">
                    {tramites.slice(0, 6).map((t) => {
                      const est = ESTADO_BADGE[t.estado]
                      const tipo = TIPO_BADGE[t.tipo_tramite]
                      return (
                        <Link
                          key={t.id}
                          href={`/tramites/${t.id}`}
                          onClick={onClose}
                          className="flex items-center justify-between gap-2 rounded-lg border px-3 py-2 transition-colors hover:bg-slate-50"
                        >
                          <div className="min-w-0">
                            <span className="font-mono text-xs font-semibold text-slate-800">
                              {t.folio}
                            </span>
                            <p className="truncate text-xs text-slate-500">{t.titulo}</p>
                          </div>
                          <div className="flex shrink-0 items-center gap-1.5">
                            {tipo && <Badge variant={tipo.variant}>{tipo.label}</Badge>}
                            {est && <Badge variant={est.variant}>{est.label}</Badge>}
                          </div>
                        </Link>
                      )
                    })}
                    {tramites.length > 6 && (
                      <Link
                        href={`/polizas/${poliza.id}`}
                        onClick={onClose}
                        className="block py-1 text-center text-xs font-medium text-blue-600 hover:underline"
                      >
                        Ver los {tramites.length} trámites en la ficha
                      </Link>
                    )}
                  </div>
                )}
              </div>

              {detalle && (detalle.porcentaje_comision != null || detalle.monto_comision != null) && (
                <div className="border-t px-6 py-4">
                  <h3 className="mb-2 flex items-center gap-1.5 text-xs font-semibold uppercase tracking-wider text-slate-400">
                    <Building2 className="h-3.5 w-3.5" /> Comisión
                  </h3>
                  <div className="flex items-center justify-between text-sm">
                    <span className="text-slate-500">
                      {detalle.porcentaje_comision != null ? `${detalle.porcentaje_comision}%` : "—"}
                    </span>
                    <span className="font-semibold text-slate-700">
                      {formatMoney(detalle.monto_comision, poliza.moneda ?? "MXN")}
                    </span>
                  </div>
                </div>
              )}
            </>
          )}
        </div>
      </div>
    </>
  )
}
