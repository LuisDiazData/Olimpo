"use client"

import * as React from "react"
import Link from "next/link"
import { useState, useEffect, useCallback } from "react"
import {
  ArrowUpRight,
  CheckCircle,
  Clock,
  FileText,
  Mail,
  MailOpen,
  Paperclip,
  Send,
  User,
  X,
} from "lucide-react"
import { cn } from "@/lib/utils"
import { Badge } from "@/components/ui/badge"
import { useUser } from "@/components/providers/user-provider"
import { Button } from "@/components/ui/button"
import { api } from "@/lib/api"
import { ReasignarTramiteModal } from "@/components/asignaciones/reasignar-tramite-modal"
import { ESTADO_BADGE, TIPO_BADGE, PRIORIDAD_BADGE, RAMO_BADGE, formatFechaCorta } from "./shared"
import type { TramiteRow } from "./types"

interface TramiteDetalleDrawerProps {
  tramite: TramiteRow | null
  onClose: () => void
  onTramiteUpdated?: () => void
}

type TabSection = "historial" | "documentos" | "comunicaciones" | "contactos"

interface Evento {
  id: string
  tipo_evento: string
  descripcion: string
  agente_ia_nombre: string | null
  usuario_nombre: string | null
  created_at: string
  estado_anterior: string | null
  estado_nuevo: string | null
}

interface Documento {
  id: string
  tipo_documento: string
  nombre_archivo: string
  estado_validacion: string
  confianza_ocr: number | null
}

interface Comunicacion {
  id: string
  tipo: "entrante" | "saliente"
  de_email: string
  de_nombre: string | null
  asunto: string
  fecha_correo: string
  estado: string
}

interface Contacto {
  id: string
  nombre: string
  email: string
  telefono: string | null
  rol: string
}

interface AnalistaItem {
  id: string
  nombre: string
  email: string
  ramo: string
  activo: boolean
}

const TABS: { id: TabSection; label: string; icon: React.ElementType }[] = [
  { id: "historial", label: "Historial", icon: Clock },
  { id: "documentos", label: "Documentos", icon: Paperclip },
  { id: "comunicaciones", label: "Comunicaciones", icon: Mail },
  { id: "contactos", label: "Contactos", icon: User },
]

function diasTranscurridos(fechaRecepcion: string): number {
  const diff = Date.now() - new Date(fechaRecepcion).getTime()
  return Math.floor(diff / (1000 * 60 * 60 * 24))
}

function EventoItem({ evento }: { evento: Evento }) {
  const iconColor = evento.agente_ia_nombre ? "text-violet-500" : "text-slate-400"
  const actor = evento.agente_ia_nombre
    ? evento.agente_ia_nombre
    : evento.usuario_nombre ?? "Sistema"

  return (
    <div className="flex gap-3 py-3">
      <div className={cn("mt-0.5 flex h-6 w-6 shrink-0 items-center justify-center rounded-full", iconColor, evento.agente_ia_nombre ? "bg-violet-50" : "bg-slate-100")}>
        {evento.estado_nuevo ? (
          <CheckCircle className="h-3.5 w-3.5" />
        ) : (
          <div className="h-1.5 w-1.5 rounded-full bg-current" />
        )}
      </div>
      <div className="min-w-0 flex-1">
        <div className="flex items-baseline justify-between gap-2">
          <span className="text-xs font-medium text-slate-500">{actor}</span>
          <span className="text-[11px] text-slate-400 shrink-0">
            {formatFechaCorta(evento.created_at)}
          </span>
        </div>
        <p className="mt-0.5 text-sm text-slate-700">{evento.descripcion}</p>
        {evento.estado_nuevo && (
          <div className="mt-1">
            <Badge variant="slate">{evento.estado_nuevo}</Badge>
          </div>
        )}
      </div>
    </div>
  )
}

function DocumentoItem({ doc }: { doc: Documento }) {
  const validacionVariant = {
    valido: "emerald",
    invalido: "red",
    pendiente_validacion: "amber",
    ilegible: "orange",
    vencido: "rose",
    duplicado: "violet",
  }[doc.estado_validacion] as keyof typeof ESTADO_BADGE | "orange" | "violet" | "rose" ?? "slate"

  const validacionLabel = {
    valido: "Válido",
    invalido: "Inválido",
    pendiente_validacion: "Pendiente",
    ilegible: "Ilegible",
    vencido: "Vencido",
    duplicado: "Duplicado",
  }[doc.estado_validacion] ?? doc.estado_validacion

  return (
    <div className="flex items-center justify-between gap-3 rounded-lg border px-3 py-2.5">
      <div className="flex items-center gap-2 min-w-0">
        <FileText className="h-4 w-4 shrink-0 text-slate-400" />
        <span className="truncate text-sm text-slate-700">{doc.nombre_archivo}</span>
      </div>
      <div className="flex items-center gap-2 shrink-0">
        <Badge variant={validacionVariant as Parameters<typeof Badge>[0]["variant"]}>
          {validacionLabel}
        </Badge>
      </div>
    </div>
  )
}

function ComunicacionItem({ com }: { com: Comunicacion }) {
  return (
    <div className="flex items-start gap-3 rounded-lg border px-3 py-2.5">
      <div className={cn("mt-0.5 flex h-6 w-6 shrink-0 items-center justify-center rounded-full", com.tipo === "entrante" ? "bg-emerald-100" : "bg-blue-100")}>
        {com.tipo === "entrante" ? (
          <MailOpen className="h-3.5 w-3.5 text-emerald-600" />
        ) : (
          <Send className="h-3.5 w-3.5 text-blue-600" />
        )}
      </div>
      <div className="min-w-0 flex-1">
        <div className="flex items-baseline justify-between gap-2">
          <span className="truncate text-sm font-medium text-slate-700">
            {com.de_nombre ?? com.de_email}
          </span>
          <span className="text-[11px] text-slate-400 shrink-0">
            {formatFechaCorta(com.fecha_correo)}
          </span>
        </div>
        <p className="mt-0.5 truncate text-xs text-slate-500">{com.asunto}</p>
      </div>
    </div>
  )
}

function ContactoItem({ contacto }: { contacto: Contacto }) {
  const rolLabel = {
    agente: "Agente",
    asistente: "Asistente",
    analista: "Analista",
    gerente: "Gerente",
  }[contacto.rol] ?? contacto.rol

  return (
    <div className="flex items-center gap-3 rounded-lg border px-3 py-2.5">
      <div className="flex h-8 w-8 shrink-0 items-center justify-center rounded-full bg-slate-100">
        <User className="h-4 w-4 text-slate-500" />
      </div>
      <div className="min-w-0 flex-1">
        <p className="text-sm font-medium text-slate-700">{contacto.nombre}</p>
        <p className="text-xs text-slate-500">{contacto.email}</p>
      </div>
      <Badge variant="slate">{rolLabel}</Badge>
    </div>
  )
}

export function TramiteDetalleDrawer({ tramite, onClose, onTramiteUpdated }: TramiteDetalleDrawerProps) {
  const { perfil } = useUser()
  const [activeTab, setActiveTab] = useState<TabSection>("historial")
  const [loading, setLoading] = useState(false)
  const [eventos, setEventos] = useState<Evento[]>([])
  const [documentos, setDocumentos] = useState<Documento[]>([])
  const [comunicaciones, setComunicaciones] = useState<Comunicacion[]>([])
  const [contactos, setContactos] = useState<Contacto[]>([])
  const [analistas, setAnalistas] = useState<AnalistaItem[]>([])
  const [showReasignar, setShowReasignar] = useState(false)

  const ROLES_REASIGNAR = ["director_general", "director_ops", "gerente"]
  const puedeReasignar = perfil ? ROLES_REASIGNAR.includes(perfil.rol) : false

  useEffect(() => {
    if (!tramite) return

    const handleKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") onClose()
    }
    document.addEventListener("keydown", handleKey)
    return () => document.removeEventListener("keydown", handleKey)
  }, [tramite, onClose])

  useEffect(() => {
    if (!tramite) return
    setLoading(true)
      setEventos([])
    setDocumentos([])
    setComunicaciones([])
    setContactos([])
    setActiveTab("historial")

    Promise.all([
      fetch(`/api/tramites/${tramite.id}/eventos`).then(r => r.json()).catch(() => ({ data: [] })),
      fetch(`/api/tramites/${tramite.id}/documentos`).then(r => r.json()).catch(() => ({ data: [] })),
      fetch(`/api/tramites/${tramite.id}/comunicaciones`).then(r => r.json()).catch(() => ({ data: [] })),
      fetch(`/api/tramites/${tramite.id}/contactos`).then(r => r.json()).catch(() => ({ data: [] })),
      puedeReasignar
        ? api.get<AnalistaItem[]>("/usuarios?rol=analista&activo=true&limit=200")
        : Promise.resolve({ data: [] }),
    ]).then(([ev, doc, com, cont, analy]) => {
      setEventos(ev.data ?? [])
      setDocumentos(doc.data ?? [])
      setComunicaciones(com.data ?? [])
      setContactos(cont.data ?? [])
      setAnalistas(analy.data ?? [])
      setLoading(false)
    })
  }, [tramite, puedeReasignar])

  const handleReasignado = useCallback((nuevoNombre: string) => {
    if (onTramiteUpdated) onTramiteUpdated()
  }, [onTramiteUpdated])

  if (!tramite) return null

  const estado = ESTADO_BADGE[tramite.estado]
  const tipo = TIPO_BADGE[tramite.tipo_tramite]
  const prioridad = PRIORIDAD_BADGE[tramite.prioridad]
  const ramo = tramite.ramo ? RAMO_BADGE[tramite.ramo] : null
  const dias = diasTranscurridos(tramite.fecha_recepcion)
  const riesgoColor = {
    verde: "text-emerald-600",
    amarillo: "text-amber-600",
    rojo: "text-red-600",
  }[tramite.riesgo_sla]

  return (
    <>
      <div className="fixed inset-0 z-40 bg-black/40 backdrop-blur-sm" onClick={onClose} />
      <div
        className="fixed right-0 top-0 z-50 flex h-full w-full flex-col bg-white shadow-xl sm:max-w-lg animate-in slide-in-from-right duration-300"
        role="dialog"
        aria-modal="true"
      >
        {/* Header */}
        <div className="border-b px-6 py-4">
          <div className="flex items-start justify-between">
            <div>
              <div className="flex items-center gap-2">
                <span className="font-mono text-base font-bold text-slate-900">{tramite.folio}</span>
                {tramite.folio_ot && (
                  <span className="rounded bg-violet-100 px-1.5 py-0.5 text-[11px] font-medium text-violet-700">
                    OT {tramite.folio_ot}
                  </span>
                )}
              </div>
              <p className="mt-1 text-sm text-slate-500 line-clamp-1">{tramite.titulo}</p>
            </div>
            <div className="ml-2 flex shrink-0 items-center gap-1">
              <Link
                href={`/tramites/${tramite.id}`}
                onClick={onClose}
                className="flex items-center gap-1 rounded-md px-2 py-1.5 text-xs font-medium text-slate-500 hover:bg-slate-100 hover:text-slate-700 transition-colors"
                title="Ver detalle completo"
              >
                <ArrowUpRight className="h-3.5 w-3.5" />
                Detalle
              </Link>
              <button
                onClick={onClose}
                className="rounded-md p-1.5 text-slate-400 hover:bg-slate-100 hover:text-slate-600 transition-colors"
              >
                <X className="h-5 w-5" />
              </button>
            </div>
          </div>
        </div>

        {/* Meta row */}
        <div className="flex flex-wrap gap-1.5 border-b px-6 py-3">
          {estado && <Badge variant={estado.variant}>{estado.label}</Badge>}
          {ramo && <Badge variant={ramo.variant}>{ramo.label}</Badge>}
          {tipo && <Badge variant={tipo.variant}>{tipo.label}</Badge>}
          {prioridad && <Badge variant={prioridad.variant}>{prioridad.label}</Badge>}
        </div>

        {/* Scrollable body */}
        <div className="flex-1 overflow-y-auto">
          {/* Agent + ramo section */}
          <div className="px-6 py-4 border-b">
            <h3 className="text-xs font-semibold uppercase tracking-wider text-slate-400 mb-3">Agente</h3>
            {tramite.agente_nombre ? (
              <div className="flex items-center gap-3">
                <div className="flex h-9 w-9 items-center justify-center rounded-full bg-slate-100">
                  <User className="h-4 w-4 text-slate-500" />
                </div>
                <div>
                  <p className="text-sm font-medium text-slate-800">{tramite.agente_nombre}</p>
                  {tramite.agente_cua && (
                    <p className="text-xs font-mono text-slate-400">CUA {tramite.agente_cua}</p>
                  )}
                </div>
              </div>
            ) : (
              <p className="text-sm italic text-slate-400">Sin agente identificado</p>
            )}
            {tramite.ramo && (
              <div className="mt-3 flex items-center gap-2 text-sm text-slate-600">
                <span className="text-xs font-medium text-slate-400">Ramo:</span>
                <span>{tramite.ramo}</span>
              </div>
            )}
          </div>

          {/* Resumen IA */}
          <div className="px-6 py-4 border-b bg-slate-50">
            <h3 className="text-xs font-semibold uppercase tracking-wider text-slate-400 mb-2">Resumen IA</h3>
            <p className="text-sm text-slate-600 leading-relaxed">
              {tramite.resumen_ia ?? "El resumen se generará cuando el agente IA procese el trámite."}
            </p>
          </div>

          {/* Stats row */}
          <div className="grid grid-cols-3 divide-x border-b">
            <div className="px-4 py-3 text-center">
              <p className={cn("text-lg font-bold", riesgoColor)}>{dias}</p>
              <p className="text-[10px] uppercase tracking-wider text-slate-400">Días</p>
            </div>
            <div className="px-4 py-3 text-center">
              <p className="text-lg font-bold text-slate-700">
                {tramite.fecha_limite_sla ? formatFechaCorta(tramite.fecha_limite_sla).split(",")[0] : "—"}
              </p>
              <p className="text-[10px] uppercase tracking-wider text-slate-400">Límite SLA</p>
            </div>
            <div className="px-4 py-3 text-center">
              <p className="text-lg font-bold text-slate-700">{tramite.analista_nombre ?? "—"}</p>
              <p className="text-[10px] uppercase tracking-wider text-slate-400">Analista</p>
              {puedeReasignar && (
                <button
                  onClick={() => setShowReasignar(true)}
                  className="mt-1 text-[10px] text-blue-600 hover:text-blue-700 hover:underline"
                >
                  Reasignar
                </button>
              )}
            </div>
          </div>

          {/* Tabs */}
          <div className="flex border-b px-6">
            {TABS.map((tab) => {
              const Icon = tab.icon
              return (
                <button
                  key={tab.id}
                  onClick={() => setActiveTab(tab.id)}
                  className={cn(
                    "flex items-center gap-1.5 border-b-2 px-3 py-2.5 text-sm transition-colors",
                    activeTab === tab.id
                      ? "border-slate-900 text-slate-900 font-medium"
                      : "border-transparent text-slate-500 hover:text-slate-700"
                  )}
                >
                  <Icon className="h-4 w-4" />
                  {tab.label}
                </button>
              )
            })}
          </div>

          {/* Tab content */}
          <div className="px-6 py-4">
            {loading ? (
              <div className="flex items-center justify-center py-8 text-slate-400 text-sm">
                Cargando...
              </div>
            ) : (
              <>
                {activeTab === "historial" && (
                  <div className="divide-y">
                    {eventos.length === 0 ? (
                      <p className="py-4 text-center text-sm text-slate-400">Sin eventos registrados</p>
                    ) : (
                      eventos.map((e) => <EventoItem key={e.id} evento={e} />)
                    )}
                  </div>
                )}

                {activeTab === "documentos" && (
                  <div className="space-y-2">
                    {documentos.length === 0 ? (
                      <p className="py-4 text-center text-sm text-slate-400">Sin documentos</p>
                    ) : (
                      documentos.map((d) => <DocumentoItem key={d.id} doc={d} />)
                    )}
                  </div>
                )}

                {activeTab === "comunicaciones" && (
                  <div className="space-y-2">
                    {comunicaciones.length === 0 ? (
                      <p className="py-4 text-center text-sm text-slate-400">Sin comunicaciones</p>
                    ) : (
                      comunicaciones.map((c) => <ComunicacionItem key={c.id} com={c} />)
                    )}
                  </div>
                )}

                {activeTab === "contactos" && (
                  <div className="space-y-2">
                    {contactos.length === 0 ? (
                      <p className="py-4 text-center text-sm text-slate-400">Sin contactos</p>
                    ) : (
                      contactos.map((c) => <ContactoItem key={c.id} contacto={c} />)
                    )}
                  </div>
                )}
              </>
            )}
          </div>
        </div>
      </div>

      {showReasignar && tramite && (
        <ReasignarTramiteModal
          tramite={{ id: tramite.id, folio: tramite.folio, titulo: tramite.titulo, ramo: tramite.ramo, analista_nombre: tramite.analista_nombre }}
          analistas={analistas}
          ramoUsuario={perfil?.ramo ?? null}
          onClose={() => setShowReasignar(false)}
          onReasignado={handleReasignado}
        />
      )}
    </>
  )
}
