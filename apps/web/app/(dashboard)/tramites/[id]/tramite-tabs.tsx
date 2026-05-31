"use client"

import * as React from "react"
import {
  CheckCircle,
  Clock,
  FileText,
  Mail,
  MailOpen,
  MessageSquare,
  Paperclip,
  Phone,
  Send,
  Users,
} from "lucide-react"
import { cn } from "@/lib/utils"
import { Badge } from "@/components/ui/badge"
import { formatFechaCorta, ESTADO_BADGE } from "../shared"
import type {
  EventoTramite,
  DocumentoTramite,
  ComunicacionUnificada,
  ContactoTramite,
  CorreoTramiteItem,
} from "../types"

// ---------------------------------------------------------------------------
// Tabs config
// ---------------------------------------------------------------------------

type TabId = "historial" | "documentos" | "comunicaciones" | "comentarios" | "contactos"

const TABS: { id: TabId; label: string; icon: React.ElementType }[] = [
  { id: "historial", label: "Historial", icon: Clock },
  { id: "documentos", label: "Documentos", icon: Paperclip },
  { id: "comunicaciones", label: "Comunicaciones", icon: Mail },
  { id: "comentarios", label: "Comentarios", icon: MessageSquare },
  { id: "contactos", label: "Contactos", icon: Users },
]

// ---------------------------------------------------------------------------
// Sub-componentes de cada tab
// ---------------------------------------------------------------------------

function EventoItem({ evento }: { evento: EventoTramite }) {
  const esIA = !!evento.agente_ia_nombre
  const actor = esIA ? evento.agente_ia_nombre : (evento.usuario_nombre ?? "Sistema")
  const esCambioEstado = !!evento.estado_nuevo

  return (
    <div className="flex gap-3 py-3">
      <div
        className={cn(
          "mt-0.5 flex h-6 w-6 shrink-0 items-center justify-center rounded-full",
          esIA ? "bg-violet-50 text-violet-500" : "bg-slate-100 text-slate-400"
        )}
      >
        {esCambioEstado ? (
          <CheckCircle className="h-3.5 w-3.5" />
        ) : (
          <div className="h-1.5 w-1.5 rounded-full bg-current" />
        )}
      </div>
      <div className="min-w-0 flex-1">
        <div className="flex items-baseline justify-between gap-2">
          <span className="text-xs font-medium text-slate-500">{actor}</span>
          <span className="shrink-0 text-[11px] text-slate-400">
            {formatFechaCorta(evento.created_at)}
          </span>
        </div>
        <p className="mt-0.5 text-sm text-slate-700">{evento.descripcion}</p>
        {evento.estado_nuevo && (
          <div className="mt-1">
            {(() => {
              const e = ESTADO_BADGE[evento.estado_nuevo]
              return e ? (
                <Badge variant={e.variant}>{e.label}</Badge>
              ) : (
                <Badge variant="slate">{evento.estado_nuevo}</Badge>
              )
            })()}
          </div>
        )}
      </div>
    </div>
  )
}

const VALIDACION_CONFIG: Record<string, { label: string; variant: Parameters<typeof Badge>[0]["variant"] }> = {
  valido:               { label: "Válido",    variant: "emerald" },
  invalido:             { label: "Inválido",  variant: "red" },
  pendiente_validacion: { label: "Pendiente", variant: "amber" },
  ilegible:             { label: "Ilegible",  variant: "orange" },
  vencido:              { label: "Vencido",   variant: "rose" },
  duplicado:            { label: "Duplicado", variant: "violet" },
}

const TIPO_DOC_LABEL: Record<string, string> = {
  ine: "INE", pasaporte: "Pasaporte", acta_nacimiento: "Acta de Nacimiento",
  curp: "CURP", comprobante_domicilio: "Comp. Domicilio", solicitud_alta: "Solicitud Alta",
  formulario_gnp: "Formulario GNP", carta_medica: "Carta Médica", dictamen_medico: "Dictamen",
  cuestionario_salud: "Cuestionario Salud", poliza_anterior: "Póliza Anterior",
  endoso: "Endoso", tarjeta_circulacion: "Tarjeta Circulación", factura_vehiculo: "Factura Veh.",
  fotografia_vehiculo: "Fotografía", acta_constitutiva: "Acta Constitutiva",
  poder_notarial: "Poder Notarial", cedula_fiscal: "Cédula Fiscal",
  estado_cuenta: "Estado de Cuenta", comprobante_pago: "Comp. Pago", recibo_prima: "Recibo Prima",
  otro: "Otro",
}

function DocumentoItem({ doc }: { doc: DocumentoTramite }) {
  const config = VALIDACION_CONFIG[doc.estado_validacion] ?? { label: doc.estado_validacion, variant: "slate" as const }

  return (
    <div className="flex items-center justify-between gap-3 rounded-lg border px-3 py-2.5">
      <div className="flex min-w-0 items-center gap-2">
        <FileText className="h-4 w-4 shrink-0 text-slate-400" />
        <div className="min-w-0">
          <p className="truncate text-sm text-slate-700">
            {doc.adjunto_nombre ?? doc.tipo_documento}
          </p>
          <p className="text-[11px] text-slate-400">
            {TIPO_DOC_LABEL[doc.tipo_documento] ?? doc.tipo_documento}
            {doc.confianza_ocr != null && (
              <span className="ml-1.5">
                OCR {Math.round(Number(doc.confianza_ocr) * 100)}%
              </span>
            )}
          </p>
        </div>
      </div>
      <Badge variant={config.variant}>{config.label}</Badge>
    </div>
  )
}

const MEDIO_ICON: Record<string, React.ElementType> = {
  whatsapp: MessageSquare,
  telefono: Phone,
  presencial: Users,
}

const MEDIO_COLOR: Record<string, string> = {
  whatsapp: "bg-emerald-100 text-emerald-600",
  telefono: "bg-slate-100 text-slate-600",
  presencial: "bg-amber-100 text-amber-600",
}

function ComunicacionItem({ item }: { item: ComunicacionUnificada }) {
  if (item.fuente === "correo") {
    const esEntrante = item.tipo_correo === "entrante"
    return (
      <div className="flex items-start gap-3 rounded-lg border px-3 py-2.5">
        <div
          className={cn(
            "mt-0.5 flex h-6 w-6 shrink-0 items-center justify-center rounded-full",
            esEntrante ? "bg-emerald-100" : "bg-blue-100"
          )}
        >
          {esEntrante ? (
            <MailOpen className="h-3.5 w-3.5 text-emerald-600" />
          ) : (
            <Send className="h-3.5 w-3.5 text-blue-600" />
          )}
        </div>
        <div className="min-w-0 flex-1">
          <div className="flex items-baseline justify-between gap-2">
            <span className="truncate text-sm font-medium text-slate-700">
              {item.de_nombre ?? item.de_email}
            </span>
            <span className="shrink-0 text-[11px] text-slate-400">
              {formatFechaCorta(item.fecha)}
            </span>
          </div>
          <p className="mt-0.5 truncate text-xs text-slate-500">{item.asunto}</p>
          {item.es_origen && (
            <span className="mt-1 inline-block rounded bg-violet-100 px-1.5 py-0.5 text-[10px] font-semibold text-violet-700">
              Origen
            </span>
          )}
        </div>
      </div>
    )
  }

  // Comunicación informal
  const IconComp = MEDIO_ICON[item.medio!] ?? MessageSquare
  const colorClass = MEDIO_COLOR[item.medio!] ?? "bg-slate-100 text-slate-600"
  const medioLabel = { whatsapp: "WhatsApp", telefono: "Teléfono", presencial: "Presencial" }[item.medio!] ?? item.medio

  return (
    <div className="flex items-start gap-3 rounded-lg border px-3 py-2.5">
      <div className={cn("mt-0.5 flex h-6 w-6 shrink-0 items-center justify-center rounded-full", colorClass)}>
        <IconComp className="h-3.5 w-3.5" />
      </div>
      <div className="min-w-0 flex-1">
        <div className="flex items-baseline justify-between gap-2">
          <span className="text-xs font-semibold text-slate-500">
            {medioLabel}
            {item.comunicacion_entrante ? " (entrante)" : " (saliente)"}
          </span>
          <span className="shrink-0 text-[11px] text-slate-400">
            {formatFechaCorta(item.fecha)}
          </span>
        </div>
        <p className="mt-0.5 text-sm text-slate-700">{item.nota}</p>
        {item.usuario_nombre && (
          <p className="mt-0.5 text-[11px] text-slate-400">por {item.usuario_nombre}</p>
        )}
        {item.requiere_seguimiento && (
          <span className="mt-1 inline-block rounded bg-amber-100 px-1.5 py-0.5 text-[10px] font-semibold text-amber-700">
            Seguimiento pendiente
          </span>
        )}
      </div>
    </div>
  )
}

function ContactoItem({ contacto }: { contacto: ContactoTramite }) {
  const rolLabel = {
    agente: "Agente",
    asistente: "Asistente",
    analista: "Analista",
    gerente: "Gerente",
  }[contacto.rol] ?? contacto.rol

  return (
    <div className="flex items-center gap-3 rounded-lg border px-3 py-2.5">
      <div className="flex h-9 w-9 shrink-0 items-center justify-center rounded-full bg-slate-100">
        <Users className="h-4 w-4 text-slate-500" />
      </div>
      <div className="min-w-0 flex-1">
        <p className="text-sm font-medium text-slate-800">{contacto.nombre}</p>
        {contacto.email && <p className="text-xs text-slate-500">{contacto.email}</p>}
        {contacto.cua && (
          <p className="font-mono text-xs text-slate-400">CUA {contacto.cua}</p>
        )}
      </div>
      <Badge variant="slate">{rolLabel}</Badge>
    </div>
  )
}

// ---------------------------------------------------------------------------
// Componente principal
// ---------------------------------------------------------------------------

interface TramiteTabsProps {
  tramiteId: string
}

type TabData = {
  eventos: EventoTramite[]
  comentarios: EventoTramite[]
  documentos: DocumentoTramite[]
  comunicaciones: ComunicacionUnificada[]
  contactos: ContactoTramite[]
}

export function TramiteTabs({ tramiteId }: TramiteTabsProps) {
  const [activeTab, setActiveTab] = React.useState<TabId>("historial")
  const [loading, setLoading] = React.useState(true)
  const [data, setData] = React.useState<TabData>({
    eventos: [],
    comentarios: [],
    documentos: [],
    comunicaciones: [],
    contactos: [],
  })

  React.useEffect(() => {
    let cancelled = false
    setLoading(true)

    Promise.all([
      fetch(`/api/tramites/${tramiteId}/eventos`).then(r => r.json()).catch(() => ({ data: [] })),
      fetch(`/api/tramites/${tramiteId}/documentos`).then(r => r.json()).catch(() => ({ data: [] })),
      fetch(`/api/tramites/${tramiteId}/comunicaciones`).then(r => r.json()).catch(() => ({ data: [] })),
      fetch(`/api/tramites/${tramiteId}/contactos`).then(r => r.json()).catch(() => ({ data: [] })),
      fetch(`/api/comunicaciones?tramite_id=${tramiteId}`).then(r => r.json()).catch(() => ({ data: [] })),
    ]).then(([eventosRes, docsRes, correosRes, contactosRes, informalesRes]) => {
      if (cancelled) return

      const todosEventos: EventoTramite[] = eventosRes.data ?? []
      const comentarios = todosEventos.filter(e => e.tipo_evento === "nota_analista")
      const historial = todosEventos.filter(e => e.tipo_evento !== "nota_analista")

      // Unificar correos + comunicaciones informales
      const correos: CorreoTramiteItem[] = correosRes.data ?? []
      const informales = informalesRes.data ?? []

      const comunicacionesUnificadas: ComunicacionUnificada[] = [
        ...correos.map((c): ComunicacionUnificada => ({
          id: c.id,
          fuente: "correo",
          fecha: c.fecha_correo,
          asunto: c.asunto,
          de_email: c.de_email,
          de_nombre: c.de_nombre ?? undefined,
          tipo_correo: c.tipo as "entrante" | "saliente",
          es_origen: c.es_origen,
        })),
        ...informales.map((i: Record<string, unknown>): ComunicacionUnificada => ({
          id: i.id as string,
          fuente: "informal",
          fecha: i.created_at as string,
          medio: i.medio as "whatsapp" | "telefono" | "presencial",
          nota: i.nota as string,
          comunicacion_entrante: i.comunicacion_entrante as boolean,
          requiere_seguimiento: i.requiere_seguimiento as boolean,
          usuario_nombre: (i.usuario_nombre as string) ?? null,
        })),
      ].sort((a, b) => new Date(b.fecha).getTime() - new Date(a.fecha).getTime())

      setData({
        eventos: historial,
        comentarios,
        documentos: docsRes.data ?? [],
        comunicaciones: comunicacionesUnificadas,
        contactos: contactosRes.data ?? [],
      })
      setLoading(false)
    })

    return () => { cancelled = true }
  }, [tramiteId])

  function TabButton({ tab }: { tab: typeof TABS[number] }) {
    const Icon = tab.icon
    return (
      <button
        onClick={() => setActiveTab(tab.id)}
        className={cn(
          "flex items-center gap-1.5 border-b-2 px-3 py-2.5 text-sm whitespace-nowrap transition-colors",
          activeTab === tab.id
            ? "border-slate-900 font-semibold text-slate-900"
            : "border-transparent text-slate-500 hover:text-slate-700"
        )}
      >
        <Icon className="h-4 w-4" />
        {tab.label}
      </button>
    )
  }

  return (
    <div className="flex h-full flex-col">
      {/* Tab bar */}
      <div className="flex overflow-x-auto border-b px-6 scrollbar-none">
        {TABS.map(tab => <TabButton key={tab.id} tab={tab} />)}
      </div>

      {/* Content */}
      <div className="flex-1 px-6 py-4">
        {loading ? (
          <div className="flex items-center justify-center py-12 text-sm text-slate-400">
            Cargando...
          </div>
        ) : (
          <>
            {activeTab === "historial" && (
              <div className="divide-y">
                {data.eventos.length === 0 ? (
                  <p className="py-8 text-center text-sm text-slate-400">Sin eventos registrados</p>
                ) : (
                  data.eventos.map(e => <EventoItem key={e.id} evento={e} />)
                )}
              </div>
            )}

            {activeTab === "documentos" && (
              <div className="space-y-2">
                {data.documentos.length === 0 ? (
                  <p className="py-8 text-center text-sm text-slate-400">Sin documentos</p>
                ) : (
                  data.documentos.map(d => <DocumentoItem key={d.id} doc={d} />)
                )}
              </div>
            )}

            {activeTab === "comunicaciones" && (
              <div className="space-y-2">
                {data.comunicaciones.length === 0 ? (
                  <p className="py-8 text-center text-sm text-slate-400">
                    Sin comunicaciones registradas
                  </p>
                ) : (
                  data.comunicaciones.map(c => <ComunicacionItem key={c.id} item={c} />)
                )}
              </div>
            )}

            {activeTab === "comentarios" && (
              <div className="space-y-2">
                {data.comentarios.length === 0 ? (
                  <p className="py-8 text-center text-sm text-slate-400">Sin comentarios</p>
                ) : (
                  data.comentarios.map(e => (
                    <div key={e.id} className="rounded-lg border bg-amber-50/40 px-4 py-3">
                      <div className="flex items-baseline justify-between gap-2">
                        <span className="text-xs font-semibold text-slate-600">
                          {e.usuario_nombre ?? "Sistema"}
                        </span>
                        <span className="text-[11px] text-slate-400">
                          {formatFechaCorta(e.created_at)}
                        </span>
                      </div>
                      <p className="mt-1 text-sm text-slate-700">{e.descripcion}</p>
                    </div>
                  ))
                )}
              </div>
            )}

            {activeTab === "contactos" && (
              <div className="space-y-2">
                {data.contactos.length === 0 ? (
                  <p className="py-8 text-center text-sm text-slate-400">Sin contactos</p>
                ) : (
                  data.contactos.map(c => <ContactoItem key={c.id} contacto={c} />)
                )}
              </div>
            )}
          </>
        )}
      </div>
    </div>
  )
}
