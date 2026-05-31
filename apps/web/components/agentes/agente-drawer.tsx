"use client"

import { useState, useEffect, useCallback } from "react"
import { useForm } from "react-hook-form"
import { zodResolver } from "@hookform/resolvers/zod"
import { z } from "zod"
import {
  X, Plus, Trash2, Pencil, CheckCircle2, Mail, Phone, User,
  Save, AlertCircle, Shield, ShieldOff,
} from "lucide-react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { useUser } from "@/components/providers/user-provider"
import { api } from "@/lib/api"
import type { AgenteDetail, AsistenteItem } from "./types"

const ROLES_ESCRITURA = ["director_general", "director_ops", "gerente"]

const TIPO_LABELS: Record<string, string> = {
  celular: "Cel", oficina: "Ofic", casa: "Casa", whatsapp: "WA", otro: "Otro",
}

// ── Schemas ─────────────────────────────────────────────────────────────────

const datosSchema = z.object({
  nombre: z.string().min(2, "Mínimo 2 caracteres").max(150),
  nombre_comercial: z.string().max(150).optional(),
  rfc: z
    .string()
    .max(13)
    .regex(/^[A-ZÑ&]{3,4}[0-9]{6}[A-Z0-9]{3}$|^$/, "RFC inválido")
    .optional(),
  fecha_afiliacion: z.string().optional(),
  notas: z.string().max(2000).optional(),
})

const emailSchema = z.object({
  email: z.string().email("Correo inválido"),
})

const telefonoSchema = z.object({
  numero: z.string().min(7, "Mínimo 7 dígitos").max(20),
  tipo: z.enum(["celular", "oficina", "casa", "whatsapp", "otro"]),
})

const asistenteSchema = z.object({
  nombre: z.string().min(2, "Nombre requerido").max(100),
  email: z.string().email("Correo inválido"),
  telefono: z.string().max(20).optional(),
})

type DatosForm = z.infer<typeof datosSchema>
type EmailForm = z.infer<typeof emailSchema>
type TelForm = z.infer<typeof telefonoSchema>
type AsistenteForm = z.infer<typeof asistenteSchema>

type Tab = "datos" | "contacto" | "asistentes"

interface Props {
  agenteId: string | null
  open: boolean
  onClose: () => void
  onUpdated?: () => void
}

// ── Component ────────────────────────────────────────────────────────────────

export function AgenteDrawer({ agenteId, open, onClose, onUpdated }: Props) {
  const { perfil } = useUser()
  const puedeEditar = perfil ? ROLES_ESCRITURA.includes(perfil.rol) : false

  const [agente, setAgente] = useState<AgenteDetail | null>(null)
  const [loading, setLoading] = useState(false)
  const [tab, setTab] = useState<Tab>("datos")

  // datos state
  const [savingDatos, setSavingDatos] = useState(false)
  const [datosSaved, setDatosSaved] = useState(false)
  const [datosError, setDatosError] = useState<string | null>(null)

  // contacto state
  const [showEmailForm, setShowEmailForm] = useState(false)
  const [showTelForm, setShowTelForm] = useState(false)
  const [addingEmail, setAddingEmail] = useState(false)
  const [addingTel, setAddingTel] = useState(false)
  const [emailErr, setEmailErr] = useState<string | null>(null)
  const [telErr, setTelErr] = useState<string | null>(null)

  // asistentes state
  const [showAsisForm, setShowAsisForm] = useState(false)
  const [editingAsis, setEditingAsis] = useState<AsistenteItem | null>(null)
  const [savingAsis, setSavingAsis] = useState(false)
  const [asisErr, setAsisErr] = useState<string | null>(null)

  const datosForm = useForm<DatosForm>({ resolver: zodResolver(datosSchema) })
  const emailForm = useForm<EmailForm>({ resolver: zodResolver(emailSchema) })
  const telForm = useForm<TelForm>({
    resolver: zodResolver(telefonoSchema),
    defaultValues: { tipo: "celular" },
  })
  const asisForm = useForm<AsistenteForm>({ resolver: zodResolver(asistenteSchema) })

  // ── Fetch ────────────────────────────────────────────────────────────────

  const fetchAgente = useCallback(async () => {
    if (!agenteId) return
    setLoading(true)
    try {
      const data = await api.get<AgenteDetail>(`/agentes/${agenteId}`)
      setAgente(data)
      datosForm.reset({
        nombre: data.nombre,
        nombre_comercial: data.nombre_comercial ?? "",
        rfc: data.rfc ?? "",
        fecha_afiliacion: data.fecha_afiliacion ?? "",
        notas: data.notas ?? "",
      })
    } catch {
      /* silencioso */
    } finally {
      setLoading(false)
    }
  }, [agenteId, datosForm])

  useEffect(() => {
    if (!open) {
      setAgente(null)
      setTab("datos")
      setShowEmailForm(false)
      setShowTelForm(false)
      setShowAsisForm(false)
      setEditingAsis(null)
      setDatosError(null)
      setDatosSaved(false)
      return
    }
    if (agenteId) fetchAgente()
  }, [open, agenteId, fetchAgente])

  // ── Datos ────────────────────────────────────────────────────────────────

  async function guardarDatos(data: DatosForm) {
    if (!agenteId) return
    setSavingDatos(true)
    setDatosError(null)
    setDatosSaved(false)
    const payload: Record<string, unknown> = { nombre: data.nombre.trim() }
    if (data.nombre_comercial !== undefined) payload.nombre_comercial = data.nombre_comercial.trim() || null
    if (data.rfc) payload.rfc = data.rfc.trim().toUpperCase()
    if (data.fecha_afiliacion) payload.fecha_afiliacion = data.fecha_afiliacion
    if (data.notas !== undefined) payload.notas = data.notas.trim() || null
    try {
      await api.patch(`/agentes/${agenteId}`, payload)
      await fetchAgente()
      onUpdated?.()
      setDatosSaved(true)
      setTimeout(() => setDatosSaved(false), 3000)
    } catch (err: unknown) {
      setDatosError((err as Error).message)
    } finally {
      setSavingDatos(false)
    }
  }

  async function toggleActivo() {
    if (!agente) return
    const msg = agente.activo
      ? "¿Desactivar este agente? No podrá enviar trámites."
      : "¿Reactivar este agente?"
    if (!confirm(msg)) return
    await api.patch(`/agentes/${agente.id}`, { activo: !agente.activo })
    await fetchAgente()
    onUpdated?.()
  }

  // ── Emails ───────────────────────────────────────────────────────────────

  async function agregarEmail(data: EmailForm) {
    if (!agenteId) return
    setAddingEmail(true)
    setEmailErr(null)
    try {
      await api.post(`/agentes/${agenteId}/emails`, { email: data.email, preferente: false })
      emailForm.reset()
      setShowEmailForm(false)
      await fetchAgente()
    } catch (err: unknown) {
      setEmailErr((err as Error).message)
    } finally {
      setAddingEmail(false)
    }
  }

  async function eliminarEmail(id: string) {
    if (!agenteId) return
    await api.delete(`/agentes/${agenteId}/emails/${id}`)
    await fetchAgente()
  }

  async function preferenteEmail(id: string) {
    if (!agenteId) return
    await api.patch(`/agentes/${agenteId}/emails/${id}/preferente`, {})
    await fetchAgente()
  }

  // ── Teléfonos ────────────────────────────────────────────────────────────

  async function agregarTel(data: TelForm) {
    if (!agenteId) return
    setAddingTel(true)
    setTelErr(null)
    try {
      await api.post(`/agentes/${agenteId}/telefonos`, { numero: data.numero, tipo: data.tipo, preferente: false })
      telForm.reset({ tipo: "celular" })
      setShowTelForm(false)
      await fetchAgente()
    } catch (err: unknown) {
      setTelErr((err as Error).message)
    } finally {
      setAddingTel(false)
    }
  }

  async function eliminarTel(id: string) {
    if (!agenteId) return
    await api.delete(`/agentes/${agenteId}/telefonos/${id}`)
    await fetchAgente()
  }

  async function preferenteTel(id: string) {
    if (!agenteId) return
    await api.patch(`/agentes/${agenteId}/telefonos/${id}/preferente`, {})
    await fetchAgente()
  }

  // ── Asistentes ───────────────────────────────────────────────────────────

  function abrirFormAsistente(a?: AsistenteItem) {
    setEditingAsis(a ?? null)
    setAsisErr(null)
    asisForm.reset(
      a
        ? { nombre: a.nombre, email: a.email, telefono: a.telefono ?? "" }
        : { nombre: "", email: "", telefono: "" }
    )
    setShowAsisForm(true)
  }

  async function guardarAsistente(data: AsistenteForm) {
    if (!agenteId) return
    setSavingAsis(true)
    setAsisErr(null)
    try {
      if (editingAsis) {
        await api.patch(`/agentes/${agenteId}/asistentes/${editingAsis.id}`, {
          nombre: data.nombre.trim(),
          telefono: data.telefono?.trim() || null,
        })
      } else {
        await api.post(`/agentes/${agenteId}/asistentes`, {
          nombre: data.nombre.trim(),
          email: data.email.trim().toLowerCase(),
          telefono: data.telefono?.trim() || null,
        })
      }
      setShowAsisForm(false)
      setEditingAsis(null)
      asisForm.reset()
      await fetchAgente()
    } catch (err: unknown) {
      setAsisErr((err as Error).message)
    } finally {
      setSavingAsis(false)
    }
  }

  async function toggleAsistente(a: AsistenteItem) {
    if (!agenteId) return
    await api.patch(`/agentes/${agenteId}/asistentes/${a.id}`, { activo: !a.activo })
    await fetchAgente()
  }

  async function eliminarAsistente(id: string) {
    if (!agenteId || !confirm("¿Eliminar este asistente permanentemente?")) return
    await api.delete(`/agentes/${agenteId}/asistentes/${id}`)
    await fetchAgente()
  }

  // ── Render ───────────────────────────────────────────────────────────────

  if (!open) return null

  const asistentesActivos = agente?.asistentes.filter((a) => a.activo).length ?? 0
  const asistentesTotal = agente?.asistentes.length ?? 0

  return (
    <>
      {/* Backdrop */}
      <div className="fixed inset-0 z-40 bg-black/40 backdrop-blur-sm" onClick={onClose} />

      {/* Panel — más ancho que el SlideOver por defecto */}
      <div
        className="fixed right-0 top-0 z-50 flex h-full w-full flex-col bg-white shadow-2xl sm:max-w-xl"
        role="dialog"
        aria-modal="true"
      >
        {/* ── Header ── */}
        <div className="flex items-start gap-3 border-b px-6 py-4">
          <div className="flex-1 min-w-0">
            {loading || !agente ? (
              <div className="space-y-2">
                <div className="h-5 w-48 animate-pulse rounded bg-slate-200" />
                <div className="h-3 w-24 animate-pulse rounded bg-slate-100" />
              </div>
            ) : (
              <>
                <div className="flex flex-wrap items-center gap-2">
                  <h2 className="text-base font-bold text-slate-900 truncate">{agente.nombre}</h2>
                  <span
                    className={`inline-flex items-center gap-1 rounded-full px-2 py-0.5 text-xs font-medium ${
                      agente.activo
                        ? "bg-emerald-100 text-emerald-700"
                        : "bg-red-100 text-red-600"
                    }`}
                  >
                    {agente.activo ? "Activo" : "Inactivo"}
                  </span>
                </div>
                <p className="mt-0.5 font-mono text-xs text-slate-500">
                  CUA&nbsp;·&nbsp;{agente.cua}
                  {agente.rfc && <span className="ml-3">RFC&nbsp;·&nbsp;{agente.rfc}</span>}
                </p>
              </>
            )}
          </div>
          <button
            onClick={onClose}
            className="rounded-md p-1.5 text-slate-400 hover:bg-slate-100 hover:text-slate-600"
          >
            <X className="h-5 w-5" />
          </button>
        </div>

        {/* ── Tab bar ── */}
        {agente && (
          <div className="flex border-b bg-white px-2">
            {(
              [
                { key: "datos" as Tab, label: "Información", badge: undefined },
                { key: "contacto" as Tab, label: "Contacto", badge: undefined },
                {
                  key: "asistentes" as Tab,
                  label: "Asistentes",
                  badge: asistentesTotal > 0 ? asistentesTotal : undefined,
                },
              ] satisfies { key: Tab; label: string; badge?: number }[]
            ).map(({ key, label, badge }) => (
              <button
                key={key}
                onClick={() => setTab(key)}
                className={`relative px-4 py-3 text-sm font-medium transition-colors ${
                  tab === key
                    ? "text-blue-600 after:absolute after:bottom-0 after:left-0 after:right-0 after:h-0.5 after:bg-blue-600"
                    : "text-slate-500 hover:text-slate-700"
                }`}
              >
                <span className="flex items-center gap-1.5">
                  {label}
                  {badge !== undefined && (
                    <span className="rounded-full bg-slate-200 px-1.5 py-0.5 text-xs text-slate-600">
                      {badge}
                    </span>
                  )}
                </span>
              </button>
            ))}
          </div>
        )}

        {/* ── Body ── */}
        <div className="flex-1 overflow-y-auto">
          {loading ? (
            <div className="flex items-center justify-center py-24 text-sm text-slate-400">
              Cargando...
            </div>
          ) : agente ? (
            <>
              {/* ════ TAB: Información ════ */}
              {tab === "datos" && (
                <form
                  onSubmit={datosForm.handleSubmit(guardarDatos)}
                  className="flex flex-col"
                >
                  <div className="flex flex-col gap-5 px-6 py-5">

                    <div className="space-y-1.5">
                      <Label>
                        Nombre completo <span className="text-destructive">*</span>
                      </Label>
                      <Input
                        {...datosForm.register("nombre")}
                        disabled={!puedeEditar}
                        placeholder="Juan Pérez García"
                      />
                      {datosForm.formState.errors.nombre && (
                        <p className="text-xs text-destructive">
                          {datosForm.formState.errors.nombre.message}
                        </p>
                      )}
                    </div>

                    <div className="space-y-1.5">
                      <Label>Nombre comercial</Label>
                      <Input
                        {...datosForm.register("nombre_comercial")}
                        disabled={!puedeEditar}
                        placeholder="Nombre de agencia o negocio"
                      />
                    </div>

                    <div className="grid grid-cols-2 gap-4">
                      <div className="space-y-1.5">
                        <Label>RFC</Label>
                        <Input
                          {...datosForm.register("rfc")}
                          disabled={!puedeEditar}
                          className="uppercase"
                          placeholder="PEGJ800101ABC"
                          onChange={(e) => {
                            e.target.value = e.target.value.toUpperCase()
                            datosForm.setValue("rfc", e.target.value)
                          }}
                        />
                        {datosForm.formState.errors.rfc && (
                          <p className="text-xs text-destructive">
                            {datosForm.formState.errors.rfc.message}
                          </p>
                        )}
                      </div>
                      <div className="space-y-1.5">
                        <Label>Fecha de afiliación</Label>
                        <Input
                          type="date"
                          {...datosForm.register("fecha_afiliacion")}
                          disabled={!puedeEditar}
                        />
                      </div>
                    </div>

                    <div className="space-y-1.5">
                      <Label>Notas internas</Label>
                      <textarea
                        rows={4}
                        className="flex w-full rounded-md border border-input bg-white px-3 py-2 text-sm placeholder:text-muted-foreground focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring resize-none disabled:opacity-50 disabled:cursor-not-allowed"
                        placeholder="Notas visibles solo para el equipo interno..."
                        {...datosForm.register("notas")}
                        disabled={!puedeEditar}
                      />
                    </div>

                    {/* Metadata */}
                    <div className="rounded-lg bg-slate-50 px-4 py-3 text-xs text-slate-500 space-y-1">
                      <p>
                        <span className="font-medium">CUA:</span>{" "}
                        <span className="font-mono">{agente.cua}</span>
                      </p>
                      <p>
                        <span className="font-medium">Alta:</span>{" "}
                        {new Date(agente.created_at).toLocaleDateString("es-MX", {
                          day: "2-digit",
                          month: "long",
                          year: "numeric",
                        })}
                      </p>
                      {agente.updated_at !== agente.created_at && (
                        <p>
                          <span className="font-medium">Últ. modificación:</span>{" "}
                          {new Date(agente.updated_at).toLocaleDateString("es-MX", {
                            day: "2-digit",
                            month: "long",
                            year: "numeric",
                          })}
                        </p>
                      )}
                    </div>

                    {datosError && (
                      <div className="flex items-center gap-2 rounded-md bg-red-50 px-3 py-2 text-sm text-red-700 border border-red-200">
                        <AlertCircle className="h-4 w-4 shrink-0" />
                        {datosError}
                      </div>
                    )}

                    {datosSaved && (
                      <div className="flex items-center gap-2 rounded-md bg-emerald-50 px-3 py-2 text-sm text-emerald-700 border border-emerald-200">
                        <CheckCircle2 className="h-4 w-4 shrink-0" />
                        Cambios guardados correctamente.
                      </div>
                    )}
                  </div>

                  {/* Sticky footer */}
                  {puedeEditar && (
                    <div className="sticky bottom-0 flex flex-col gap-2 border-t bg-white px-6 py-4">
                      <Button type="submit" disabled={savingDatos} className="w-full gap-2">
                        <Save className="h-4 w-4" />
                        {savingDatos ? "Guardando..." : "Guardar cambios"}
                      </Button>
                      <Button
                        type="button"
                        variant="outline"
                        size="sm"
                        onClick={toggleActivo}
                        className={`w-full gap-2 ${
                          agente.activo
                            ? "border-red-200 text-red-600 hover:bg-red-50"
                            : "border-emerald-200 text-emerald-700 hover:bg-emerald-50"
                        }`}
                      >
                        {agente.activo ? (
                          <>
                            <ShieldOff className="h-3.5 w-3.5" />
                            Desactivar agente
                          </>
                        ) : (
                          <>
                            <Shield className="h-3.5 w-3.5" />
                            Reactivar agente
                          </>
                        )}
                      </Button>
                    </div>
                  )}
                </form>
              )}

              {/* ════ TAB: Contacto ════ */}
              {tab === "contacto" && (
                <div className="flex flex-col gap-6 px-6 py-5">

                  {/* ── Correos ── */}
                  <section className="space-y-3">
                    <div className="flex items-center justify-between">
                      <div className="flex items-center gap-2">
                        <Mail className="h-4 w-4 text-slate-500" />
                        <span className="text-sm font-semibold text-slate-800">
                          Correos electrónicos
                        </span>
                        <span className="rounded-full bg-slate-100 px-1.5 py-0.5 text-xs text-slate-500">
                          {agente.emails.length}
                        </span>
                      </div>
                      {puedeEditar && (
                        <button
                          onClick={() => {
                            setShowEmailForm((v) => !v)
                            setShowTelForm(false)
                            setEmailErr(null)
                            emailForm.reset()
                          }}
                          className="text-xs font-medium text-blue-600 hover:text-blue-700"
                        >
                          {showEmailForm ? "Cancelar" : "+ Agregar"}
                        </button>
                      )}
                    </div>

                    {showEmailForm && (
                      <form
                        onSubmit={emailForm.handleSubmit(agregarEmail)}
                        className="space-y-2 rounded-lg border bg-slate-50 p-3"
                      >
                        <div className="flex gap-2">
                          <Input
                            type="email"
                            placeholder="correo@ejemplo.com"
                            {...emailForm.register("email")}
                            className="flex-1 text-sm"
                            autoFocus
                          />
                          <Button type="submit" size="sm" disabled={addingEmail}>
                            {addingEmail ? "..." : "Agregar"}
                          </Button>
                        </div>
                        {emailForm.formState.errors.email && (
                          <p className="text-xs text-destructive">
                            {emailForm.formState.errors.email.message}
                          </p>
                        )}
                        {emailErr && (
                          <p className="text-xs text-destructive">{emailErr}</p>
                        )}
                      </form>
                    )}

                    {agente.emails.length === 0 ? (
                      <EmptyContactState text="Sin correos registrados." />
                    ) : (
                      <ul className="space-y-1.5">
                        {agente.emails.map((e) => (
                          <li
                            key={e.id}
                            className="flex items-center justify-between rounded-lg border bg-white px-3 py-2.5"
                          >
                            <div className="flex items-center gap-2 min-w-0">
                              <Mail className="h-3.5 w-3.5 shrink-0 text-slate-400" />
                              <span
                                className={`text-sm truncate ${
                                  e.preferente
                                    ? "font-semibold text-slate-900"
                                    : "text-slate-600"
                                }`}
                              >
                                {e.email}
                              </span>
                              {e.preferente && (
                                <span className="shrink-0 rounded bg-blue-100 px-1.5 py-0.5 text-xs font-medium text-blue-700">
                                  Principal
                                </span>
                              )}
                            </div>
                            {puedeEditar && (
                              <div className="ml-2 flex shrink-0 items-center gap-0.5">
                                {!e.preferente && (
                                  <button
                                    onClick={() => preferenteEmail(e.id)}
                                    title="Marcar como principal"
                                    className="rounded p-1 text-slate-400 hover:bg-blue-50 hover:text-blue-600"
                                  >
                                    <CheckCircle2 className="h-3.5 w-3.5" />
                                  </button>
                                )}
                                <button
                                  onClick={() => eliminarEmail(e.id)}
                                  title="Eliminar"
                                  className="rounded p-1 text-slate-400 hover:bg-red-50 hover:text-red-600"
                                >
                                  <Trash2 className="h-3.5 w-3.5" />
                                </button>
                              </div>
                            )}
                          </li>
                        ))}
                      </ul>
                    )}
                  </section>

                  <div className="border-t" />

                  {/* ── Teléfonos ── */}
                  <section className="space-y-3">
                    <div className="flex items-center justify-between">
                      <div className="flex items-center gap-2">
                        <Phone className="h-4 w-4 text-slate-500" />
                        <span className="text-sm font-semibold text-slate-800">Teléfonos</span>
                        <span className="rounded-full bg-slate-100 px-1.5 py-0.5 text-xs text-slate-500">
                          {agente.telefonos.length}
                        </span>
                      </div>
                      {puedeEditar && (
                        <button
                          onClick={() => {
                            setShowTelForm((v) => !v)
                            setShowEmailForm(false)
                            setTelErr(null)
                            telForm.reset({ tipo: "celular" })
                          }}
                          className="text-xs font-medium text-blue-600 hover:text-blue-700"
                        >
                          {showTelForm ? "Cancelar" : "+ Agregar"}
                        </button>
                      )}
                    </div>

                    {showTelForm && (
                      <form
                        onSubmit={telForm.handleSubmit(agregarTel)}
                        className="space-y-2 rounded-lg border bg-slate-50 p-3"
                      >
                        <div className="flex gap-2">
                          <Input
                            placeholder="55 1234 5678"
                            {...telForm.register("numero")}
                            className="flex-1 text-sm"
                            autoFocus
                          />
                          <select
                            {...telForm.register("tipo")}
                            className="rounded-md border border-input bg-white px-2 py-1.5 text-sm focus:outline-none focus:ring-2 focus:ring-ring"
                          >
                            <option value="celular">Celular</option>
                            <option value="oficina">Oficina</option>
                            <option value="casa">Casa</option>
                            <option value="whatsapp">WhatsApp</option>
                            <option value="otro">Otro</option>
                          </select>
                        </div>
                        {telForm.formState.errors.numero && (
                          <p className="text-xs text-destructive">
                            {telForm.formState.errors.numero.message}
                          </p>
                        )}
                        {telErr && <p className="text-xs text-destructive">{telErr}</p>}
                        <div className="flex justify-end gap-2">
                          <Button
                            type="button"
                            variant="outline"
                            size="sm"
                            onClick={() => setShowTelForm(false)}
                          >
                            Cancelar
                          </Button>
                          <Button type="submit" size="sm" disabled={addingTel}>
                            {addingTel ? "..." : "Agregar"}
                          </Button>
                        </div>
                      </form>
                    )}

                    {agente.telefonos.length === 0 ? (
                      <EmptyContactState text="Sin teléfonos registrados." />
                    ) : (
                      <ul className="space-y-1.5">
                        {agente.telefonos.map((t) => (
                          <li
                            key={t.id}
                            className="flex items-center justify-between rounded-lg border bg-white px-3 py-2.5"
                          >
                            <div className="flex items-center gap-2 min-w-0">
                              <Phone className="h-3.5 w-3.5 shrink-0 text-slate-400" />
                              <span
                                className={`font-mono text-sm ${
                                  t.preferente
                                    ? "font-semibold text-slate-900"
                                    : "text-slate-600"
                                }`}
                              >
                                {t.numero}
                              </span>
                              <span className="rounded bg-slate-100 px-1.5 py-0.5 text-xs text-slate-500">
                                {TIPO_LABELS[t.tipo] ?? t.tipo}
                              </span>
                              {t.preferente && (
                                <span className="shrink-0 rounded bg-blue-100 px-1.5 py-0.5 text-xs font-medium text-blue-700">
                                  Principal
                                </span>
                              )}
                            </div>
                            {puedeEditar && (
                              <div className="ml-2 flex shrink-0 items-center gap-0.5">
                                {!t.preferente && (
                                  <button
                                    onClick={() => preferenteTel(t.id)}
                                    title="Marcar como principal"
                                    className="rounded p-1 text-slate-400 hover:bg-blue-50 hover:text-blue-600"
                                  >
                                    <CheckCircle2 className="h-3.5 w-3.5" />
                                  </button>
                                )}
                                <button
                                  onClick={() => eliminarTel(t.id)}
                                  title="Eliminar"
                                  className="rounded p-1 text-slate-400 hover:bg-red-50 hover:text-red-600"
                                >
                                  <Trash2 className="h-3.5 w-3.5" />
                                </button>
                              </div>
                            )}
                          </li>
                        ))}
                      </ul>
                    )}
                  </section>
                </div>
              )}

              {/* ════ TAB: Asistentes ════ */}
              {tab === "asistentes" && (
                <div className="flex flex-col gap-4 px-6 py-5">

                  {/* Sub-header */}
                  <div className="flex items-center justify-between">
                    <div>
                      <p className="text-sm font-semibold text-slate-800">
                        Asistentes / Empleados
                      </p>
                      <p className="text-xs text-slate-500 mt-0.5">
                        {asistentesTotal === 0
                          ? "Sin asistentes registrados."
                          : `${asistentesActivos} activo${asistentesActivos !== 1 ? "s" : ""} de ${asistentesTotal}`}
                      </p>
                    </div>
                    {puedeEditar && !showAsisForm && (
                      <Button
                        size="sm"
                        variant="outline"
                        className="gap-1.5"
                        onClick={() => abrirFormAsistente()}
                      >
                        <Plus className="h-3.5 w-3.5" />
                        Agregar
                      </Button>
                    )}
                  </div>

                  {/* Inline form */}
                  {showAsisForm && (
                    <div className="rounded-xl border bg-slate-50 p-4 space-y-4">
                      <p className="text-xs font-semibold uppercase tracking-wide text-slate-500">
                        {editingAsis ? "Editar asistente" : "Nuevo asistente"}
                      </p>
                      <form
                        onSubmit={asisForm.handleSubmit(guardarAsistente)}
                        className="space-y-3"
                      >
                        <div className="space-y-1.5">
                          <Label>
                            Nombre completo <span className="text-destructive">*</span>
                          </Label>
                          <Input
                            placeholder="Nombre completo"
                            {...asisForm.register("nombre")}
                            autoFocus
                          />
                          {asisForm.formState.errors.nombre && (
                            <p className="text-xs text-destructive">
                              {asisForm.formState.errors.nombre.message}
                            </p>
                          )}
                        </div>

                        <div className="space-y-1.5">
                          <Label>
                            Correo electrónico <span className="text-destructive">*</span>
                          </Label>
                          <Input
                            type="email"
                            placeholder="asistente@email.com"
                            {...asisForm.register("email")}
                            disabled={!!editingAsis}
                          />
                          {asisForm.formState.errors.email && (
                            <p className="text-xs text-destructive">
                              {asisForm.formState.errors.email.message}
                            </p>
                          )}
                          {editingAsis && (
                            <p className="text-xs text-slate-400">
                              El correo no puede modificarse.
                            </p>
                          )}
                        </div>

                        <div className="space-y-1.5">
                          <Label>Teléfono</Label>
                          <Input
                            placeholder="55 1234 5678"
                            {...asisForm.register("telefono")}
                          />
                        </div>

                        {asisErr && (
                          <div className="flex items-center gap-2 rounded-md bg-red-50 border border-red-200 px-3 py-2 text-sm text-red-700">
                            <AlertCircle className="h-4 w-4 shrink-0" />
                            {asisErr}
                          </div>
                        )}

                        <div className="flex gap-2 pt-1">
                          <Button
                            type="button"
                            variant="outline"
                            size="sm"
                            className="flex-1"
                            onClick={() => {
                              setShowAsisForm(false)
                              setEditingAsis(null)
                              setAsisErr(null)
                            }}
                          >
                            Cancelar
                          </Button>
                          <Button type="submit" size="sm" className="flex-1" disabled={savingAsis}>
                            {savingAsis
                              ? "Guardando..."
                              : editingAsis
                              ? "Actualizar"
                              : "Agregar"}
                          </Button>
                        </div>
                      </form>
                    </div>
                  )}

                  {/* Lista de asistentes */}
                  {agente.asistentes.length === 0 && !showAsisForm ? (
                    <div className="flex flex-col items-center gap-3 rounded-xl border border-dashed py-12 text-center">
                      <User className="h-10 w-10 text-slate-300" />
                      <div>
                        <p className="text-sm font-medium text-slate-500">
                          Sin asistentes registrados
                        </p>
                        <p className="text-xs text-slate-400 mt-0.5">
                          Agrega personas que operen a nombre del agente.
                        </p>
                      </div>
                    </div>
                  ) : (
                    <ul className="space-y-2">
                      {agente.asistentes.map((a) => (
                        <li
                          key={a.id}
                          className={`rounded-xl border bg-white px-4 py-3 transition-opacity ${
                            !a.activo ? "opacity-55" : ""
                          }`}
                        >
                          <div className="flex items-start justify-between gap-3">
                            {/* Avatar + datos */}
                            <div className="flex items-start gap-3 min-w-0">
                              <div
                                className={`mt-0.5 flex h-9 w-9 shrink-0 items-center justify-center rounded-full text-sm font-bold ${
                                  a.activo
                                    ? "bg-blue-100 text-blue-700"
                                    : "bg-slate-100 text-slate-400"
                                }`}
                              >
                                {a.nombre.charAt(0).toUpperCase()}
                              </div>
                              <div className="min-w-0">
                                <div className="flex flex-wrap items-center gap-1.5">
                                  <p className="text-sm font-semibold text-slate-900 truncate">
                                    {a.nombre}
                                  </p>
                                  {!a.activo && (
                                    <span className="rounded bg-red-100 px-1.5 py-0.5 text-xs text-red-600">
                                      Inactivo
                                    </span>
                                  )}
                                </div>
                                <p className="text-xs text-slate-500 truncate">{a.email}</p>
                                {a.telefono && (
                                  <p className="mt-0.5 font-mono text-xs text-slate-400">
                                    {a.telefono}
                                  </p>
                                )}
                              </div>
                            </div>

                            {/* Acciones */}
                            {puedeEditar && (
                              <div className="flex shrink-0 items-center gap-0.5">
                                <button
                                  onClick={() => abrirFormAsistente(a)}
                                  title="Editar"
                                  className="rounded p-1.5 text-slate-400 hover:bg-slate-100 hover:text-slate-700"
                                >
                                  <Pencil className="h-3.5 w-3.5" />
                                </button>
                                <button
                                  onClick={() => toggleAsistente(a)}
                                  title={a.activo ? "Desactivar" : "Activar"}
                                  className={`rounded p-1.5 ${
                                    a.activo
                                      ? "text-slate-400 hover:bg-red-50 hover:text-red-600"
                                      : "text-emerald-600 hover:bg-emerald-50"
                                  }`}
                                >
                                  <CheckCircle2 className="h-3.5 w-3.5" />
                                </button>
                                <button
                                  onClick={() => eliminarAsistente(a.id)}
                                  title="Eliminar"
                                  className="rounded p-1.5 text-slate-400 hover:bg-red-50 hover:text-red-600"
                                >
                                  <Trash2 className="h-3.5 w-3.5" />
                                </button>
                              </div>
                            )}
                          </div>
                        </li>
                      ))}
                    </ul>
                  )}
                </div>
              )}
            </>
          ) : null}
        </div>
      </div>
    </>
  )
}

// ── Helpers ──────────────────────────────────────────────────────────────────

function EmptyContactState({ text }: { text: string }) {
  return (
    <div className="rounded-lg border border-dashed py-6 text-center">
      <p className="text-xs text-slate-400">{text}</p>
    </div>
  )
}
