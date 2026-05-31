"use client"

import { useState, useEffect, useCallback } from "react"
import { useForm } from "react-hook-form"
import { zodResolver } from "@hookform/resolvers/zod"
import { z } from "zod"
import { Plus, Trash2, Pencil, Wifi, Mail, Phone, CheckCircle2 } from "lucide-react"
import { SlideOver } from "@/components/ui/slide-over"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import type { AgenteDetail, TelefonoItem, EmailItem, AsistenteItem } from "./types"

const TIPO_TELEFONO_LABELS: Record<string, string> = {
  celular:  "Celular",
  oficina:  "Oficina",
  casa:     "Casa",
  whatsapp: "WhatsApp",
  otro:     "Otro",
}

const editSchema = z.object({
  nombre:            z.string().min(2).max(150),
  nombre_comercial:  z.string().max(150).optional(),
  rfc:               z.string().max(13).optional(),
  fecha_afiliacion:  z.string().optional(),
  notas:             z.string().max(2000).optional(),
})
type EditForm = z.infer<typeof editSchema>

const emailSchema = z.object({ email: z.string().email("Correo inválido") })
type EmailFormData = z.infer<typeof emailSchema>

const telefonoSchema = z.object({
  numero:    z.string().min(7, "Mínimo 7 dígitos").max(20),
  tipo:      z.enum(["celular", "oficina", "casa", "whatsapp", "otro"]),
})
type TelefonoFormData = z.infer<typeof telefonoSchema>

const asistenteSchema = z.object({
  nombre:   z.string().min(2, "Nombre requerido").max(100),
  email:    z.string().email("Correo inválido"),
  telefono:  z.string().max(20).optional(),
})
type AsistenteFormData = z.infer<typeof asistenteSchema>

interface Props {
  agenteId: string | null
  open: boolean
  onClose: () => void
  onDeleted?: () => void
  onUpdated?: () => void
}

type ActiveTab = "datos" | "contacto" | "asistentes"

export function AgenteDetailDrawer({ agenteId, open, onClose, onDeleted, onUpdated }: Props) {
  const [agente, setAgente] = useState<AgenteDetail | null>(null)
  const [loading, setLoading] = useState(false)
  const [saving, setSaving] = useState(false)
  const [serverError, setServerError] = useState<string | null>(null)
  const [activeTab, setActiveTab] = useState<ActiveTab>("datos")

  const [showEmailForm, setShowEmailForm] = useState(false)
  const [showTelForm, setShowTelForm] = useState(false)
  const [showAsistenteForm, setShowAsistenteForm] = useState(false)
  const [editingAsistente, setEditingAsistente] = useState<AsistenteItem | null>(null)
  const [addingEmail, setAddingEmail] = useState(false)
  const [addingTel, setAddingTel] = useState(false)
  const [addingAsistente, setAddingAsistente] = useState(false)
  const [emailError, setEmailError] = useState<string | null>(null)
  const [telError, setTelError] = useState<string | null>(null)
  const [asistenteError, setAsistenteError] = useState<string | null>(null)

  const {
    register,
    handleSubmit,
    reset,
    formState: { errors },
  } = useForm<EditForm>({ resolver: zodResolver(editSchema) })

  const {
    register: registerEmail,
    handleSubmit: handleEmailSubmit,
    reset: resetEmail,
    formState: { errors: emailErrors },
  } = useForm<EmailFormData>({ resolver: zodResolver(emailSchema) })

  const {
    register: registerTel,
    handleSubmit: handleTelSubmit,
    reset: resetTel,
    formState: { errors: telErrors },
  } = useForm<TelefonoFormData>({ resolver: zodResolver(telefonoSchema) })

  const {
    register: registerAsistente,
    handleSubmit: handleAsistenteSubmit,
    reset: resetAsistente,
    formState: { errors: asistenteErrors },
  } = useForm<AsistenteFormData>({ resolver: zodResolver(asistenteSchema) })

  const fetchAgente = useCallback(async () => {
    if (!agenteId) return
    setLoading(true)
    setServerError(null)
    try {
      const res = await fetch(`/api/v1/agentes/${agenteId}`, { credentials: "include" })
      if (!res.ok) throw new Error("No se pudo cargar el agente")
      const data: AgenteDetail = await res.json()
      setAgente(data)
      reset({
        nombre:           data.nombre,
        nombre_comercial: data.nombre_comercial ?? "",
        rfc:              data.rfc ?? "",
        fecha_afiliacion: data.fecha_afiliacion ?? "",
        notas:            data.notas ?? "",
      })
    } catch {
      setServerError("No se pudo cargar el agente")
    } finally {
      setLoading(false)
    }
  }, [agenteId, reset])

  useEffect(() => {
    if (open) fetchAgente()
  }, [open, fetchAgente])

  useEffect(() => {
    if (!open) {
      setActiveTab("datos")
      setShowEmailForm(false)
      setShowTelForm(false)
      setShowAsistenteForm(false)
      setEditingAsistente(null)
      setAgente(null)
      setServerError(null)
      resetEmail()
      resetTel()
      resetAsistente()
    }
  }, [open, resetEmail, resetTel, resetAsistente, reset])

  async function onSubmit(data: EditForm) {
    if (!agenteId) return
    setSaving(true)
    setServerError(null)
    const payload: Record<string, unknown> = { nombre: data.nombre.trim() }
    if (data.nombre_comercial) payload.nombre_comercial = data.nombre_comercial.trim()
    if (data.rfc)              payload.rfc              = data.rfc.trim().toUpperCase()
    if (data.fecha_afiliacion)  payload.fecha_afiliacion  = data.fecha_afiliacion
    if (data.notas)             payload.notas             = data.notas.trim()
    try {
      const res = await fetch(`/api/v1/agentes/${agenteId}`, {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        credentials: "include",
        body: JSON.stringify(payload),
      })
      if (!res.ok) {
        const body = await res.json().catch(() => ({}))
        throw new Error((body as { detail?: string }).detail ?? "Error al guardar")
      }
      await fetchAgente()
      onUpdated?.()
    } catch (err: unknown) {
      setServerError((err as Error).message)
    } finally {
      setSaving(false)
    }
  }

  async function handleAddEmail(data: EmailFormData) {
    if (!agenteId) return
    setAddingEmail(true)
    setEmailError(null)
    try {
      const res = await fetch(`/api/v1/agentes/${agenteId}/emails`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        credentials: "include",
        body: JSON.stringify({ email: data.email, preferente: false }),
      })
      if (!res.ok) {
        const body = await res.json().catch(() => ({}))
        throw new Error((body as { detail?: string }).detail ?? "Error al agregar")
      }
      resetEmail()
      setShowEmailForm(false)
      await fetchAgente()
    } catch (err: unknown) {
      setEmailError((err as Error).message)
    } finally {
      setAddingEmail(false)
    }
  }

  async function handleDeleteEmail(emailId: string) {
    if (!agenteId) return
    await fetch(`/api/v1/agentes/${agenteId}/emails/${emailId}`, {
      method: "DELETE",
      credentials: "include",
    })
    await fetchAgente()
  }

  async function handleSetPreferenteEmail(emailId: string) {
    if (!agenteId) return
    await fetch(`/api/v1/agentes/${agenteId}/emails/${emailId}/preferente`, {
      method: "PATCH",
      credentials: "include",
    })
    await fetchAgente()
  }

  async function handleAddTel(data: TelefonoFormData) {
    if (!agenteId) return
    setAddingTel(true)
    setTelError(null)
    try {
      const res = await fetch(`/api/v1/agentes/${agenteId}/telefonos`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        credentials: "include",
        body: JSON.stringify({ numero: data.numero, tipo: data.tipo, preferente: false }),
      })
      if (!res.ok) {
        const body = await res.json().catch(() => ({}))
        throw new Error((body as { detail?: string }).detail ?? "Error al agregar")
      }
      resetTel()
      setShowTelForm(false)
      await fetchAgente()
    } catch (err: unknown) {
      setTelError((err as Error).message)
    } finally {
      setAddingTel(false)
    }
  }

  async function handleDeleteTel(telId: string) {
    if (!agenteId) return
    await fetch(`/api/v1/agentes/${agenteId}/telefonos/${telId}`, {
      method: "DELETE",
      credentials: "include",
    })
    await fetchAgente()
  }

  async function handleAddAsistente(data: AsistenteFormData) {
    if (!agenteId) return
    setAddingAsistente(true)
    setAsistenteError(null)
    try {
      const res = await fetch(`/api/v1/agentes/${agenteId}/asistentes`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        credentials: "include",
        body: JSON.stringify({
          nombre:   data.nombre.trim(),
          email:    data.email.trim().toLowerCase(),
          telefono: data.telefono?.trim() || null,
        }),
      })
      if (!res.ok) {
        const body = await res.json().catch(() => ({}))
        throw new Error((body as { detail?: string }).detail ?? "Error al agregar asistente")
      }
      resetAsistente()
      setShowAsistenteForm(false)
      setEditingAsistente(null)
      await fetchAgente()
    } catch (err: unknown) {
      setAsistenteError((err as Error).message)
    } finally {
      setAddingAsistente(false)
    }
  }

  async function handleUpdateAsistente(data: AsistenteFormData) {
    if (!agenteId || !editingAsistente) return
    setAddingAsistente(true)
    setAsistenteError(null)
    try {
      const res = await fetch(`/api/v1/agentes/${agenteId}/asistentes/${editingAsistente.id}`, {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        credentials: "include",
        body: JSON.stringify({
          nombre:   data.nombre.trim(),
          telefono: data.telefono?.trim() || null,
        }),
      })
      if (!res.ok) {
        const body = await res.json().catch(() => ({}))
        throw new Error((body as { detail?: string }).detail ?? "Error al actualizar asistente")
      }
      resetAsistente()
      setEditingAsistente(null)
      setShowAsistenteForm(false)
      await fetchAgente()
    } catch (err: unknown) {
      setAsistenteError((err as Error).message)
    } finally {
      setAddingAsistente(false)
    }
  }

  async function handleDeleteAsistente(asistenteId: string) {
    if (!agenteId) return
    if (!confirm("¿Eliminar este asistente?")) return
    await fetch(`/api/v1/agentes/${agenteId}/asistentes/${asistenteId}`, {
      method: "DELETE",
      credentials: "include",
    })
    await fetchAgente()
  }

  async function handleToggleActivoAsistente(asistenteId: string, currentActivo: boolean) {
    if (!agenteId) return
    await fetch(`/api/v1/agentes/${agenteId}/asistentes/${asistenteId}`, {
      method: "PATCH",
      headers: { "Content-Type": "application/json" },
      credentials: "include",
      body: JSON.stringify({ activo: !currentActivo }),
    })
    await fetchAgente()
  }

  async function handleToggleActivo() {
    if (!agenteId || !agente) return
    const desactivar = agente.activo
    const mensaje = desactivar
      ? "¿Desactivar este agente? El agente no podrá enviar trámites."
      : "¿Reactivar este agente?"
    if (!confirm(mensaje)) return
    await fetch(`/api/v1/agentes/${agenteId}`, {
      method: "PATCH",
      headers: { "Content-Type": "application/json" },
      credentials: "include",
      body: JSON.stringify({ activo: !desactivar }),
    })
    if (desactivar) {
      onDeleted?.()
      onClose()
    } else {
      await fetchAgente()
      onUpdated?.()
    }
  }

  const TABS: { key: ActiveTab; label: string }[] = [
    { key: "datos",       label: "Datos" },
    { key: "contacto",   label: "Contacto" },
    { key: "asistentes", label: "Asistentes" },
  ]

  return (
    <SlideOver
      open={open}
      onClose={onClose}
      title={agente ? agente.nombre : "Datos del agente"}
    >
      {loading ? (
        <div className="flex items-center justify-center py-20 text-sm text-slate-400">
          Cargando...
        </div>
      ) : agente ? (
        <div className="flex flex-col gap-5">
          {/* CUA header badge */}
          <div className="flex items-center justify-between rounded-lg border bg-slate-50 px-4 py-3">
            <div>
              <p className="text-xs font-semibold uppercase tracking-wide text-slate-500">CUA</p>
              <p className="mt-0.5 font-mono text-base font-bold text-slate-900">{agente.cua}</p>
            </div>
            <div className="text-right">
              <p className="text-xs font-semibold uppercase tracking-wide text-slate-500">Estatus</p>
              <p className={`mt-0.5 text-sm font-semibold ${agente.activo ? "text-emerald-600" : "text-red-500"}`}>
                {agente.activo ? "Activo" : "Inactivo"}
              </p>
            </div>
          </div>

          {/* Tab bar */}
          <div className="flex gap-1 rounded-lg border bg-slate-100 p-1">
            {TABS.map((tab) => (
              <button
                key={tab.key}
                onClick={() => setActiveTab(tab.key)}
                className={`flex-1 rounded-md px-3 py-1.5 text-sm font-medium transition-colors ${
                  activeTab === tab.key
                    ? "bg-white text-slate-900 shadow-sm"
                    : "text-slate-500 hover:text-slate-700"
                }`}
              >
                {tab.label}
                {tab.key === "asistentes" && agente.asistentes.length > 0 && (
                  <span className="ml-1.5 rounded-full bg-slate-200 px-1.5 py-0.5 text-xs">
                    {agente.asistentes.length}
                  </span>
                )}
              </button>
            ))}
          </div>

          {/* ── TAB: Datos ── */}
          {activeTab === "datos" && (
            <form onSubmit={handleSubmit(onSubmit)} className="flex flex-col gap-4">
              <div className="space-y-1.5">
                <Label htmlFor="nombre">Nombre completo *</Label>
                <Input id="nombre" {...register("nombre")} />
                {errors.nombre && <p className="text-xs text-destructive">{errors.nombre.message}</p>}
              </div>

              <div className="space-y-1.5">
                <Label htmlFor="nombre_comercial">Nombre comercial</Label>
                <Input id="nombre_comercial" {...register("nombre_comercial")} />
              </div>

              <div className="grid grid-cols-2 gap-3">
                <div className="space-y-1.5">
                  <Label htmlFor="rfc">RFC</Label>
                  <Input id="rfc" {...register("rfc")} className="uppercase" />
                </div>
                <div className="space-y-1.5">
                  <Label htmlFor="fecha_afiliacion">Fecha de afiliación</Label>
                  <Input id="fecha_afiliacion" type="date" {...register("fecha_afiliacion")} />
                </div>
              </div>

              <div className="space-y-1.5">
                <Label htmlFor="notas">Notas</Label>
                <textarea
                  id="notas"
                  rows={3}
                  className="flex w-full rounded-md border border-input bg-white px-3 py-2 text-sm resize-none"
                  {...register("notas")}
                />
              </div>

              {serverError && (
                <div className="rounded-md bg-destructive/10 px-3 py-2 text-sm text-destructive">{serverError}</div>
              )}

              <Button type="submit" disabled={saving} className="w-full">
                {saving ? "Guardando..." : "Guardar cambios"}
              </Button>
            </form>
          )}

          {/* ── TAB: Contacto ── */}
          {activeTab === "contacto" && (
            <div className="flex flex-col gap-5">
              {/* Emails */}
              <div className="space-y-3">
                <div className="flex items-center justify-between">
                  <div className="flex items-center gap-2">
                    <Mail className="h-4 w-4 text-slate-400" />
                    <p className="text-sm font-semibold text-slate-700">Correos</p>
                  </div>
                  <button
                    onClick={() => { setShowEmailForm(!showEmailForm); setShowTelForm(false) }}
                    className="text-xs text-blue-600 hover:text-blue-700 font-medium"
                  >
                    {showEmailForm ? "Cancelar" : "+ Agregar"}
                  </button>
                </div>

                {showEmailForm && (
                  <form onSubmit={handleEmailSubmit(handleAddEmail)} className="flex gap-2">
                    <Input
                      placeholder="correo@ejemplo.com"
                      {...registerEmail("email")}
                      className="flex-1 text-sm"
                    />
                    <Button type="submit" size="sm" disabled={addingEmail}>
                      {addingEmail ? "..." : "Agregar"}
                    </Button>
                  </form>
                )}
                {emailError && <p className="text-xs text-destructive">{emailError}</p>}
                {emailErrors.email && <p className="text-xs text-destructive">{emailErrors.email.message}</p>}

                {agente.emails.length === 0 ? (
                  <p className="text-xs text-slate-400 py-2">Sin correos registrados.</p>
                ) : (
                  <ul className="space-y-1.5">
                    {agente.emails.map((e) => (
                      <li
                        key={e.id}
                        className="flex items-center justify-between rounded-lg border px-3 py-2.5 text-sm"
                      >
                        <div className="flex items-center gap-2 min-w-0">
                          <Mail className="h-3.5 w-3.5 shrink-0 text-slate-400" />
                          <span className={`truncate ${e.preferente ? "font-semibold text-slate-900" : "text-slate-600"}`}>
                            {e.email}
                          </span>
                          {e.preferente && (
                            <span className="shrink-0 rounded bg-blue-100 px-1.5 py-0.5 text-xs text-blue-700 font-medium">
                              Principal
                            </span>
                          )}
                        </div>
                        <div className="flex items-center gap-1 shrink-0">
                          {!e.preferente && (
                            <button
                              onClick={() => handleSetPreferenteEmail(e.id)}
                              title="Marcar como principal"
                              className="rounded p-1 text-slate-400 hover:bg-slate-100 hover:text-blue-600"
                            >
                              <CheckCircle2 className="h-3.5 w-3.5" />
                            </button>
                          )}
                          <button
                            onClick={() => handleDeleteEmail(e.id)}
                            title="Eliminar"
                            className="rounded p-1 text-slate-400 hover:bg-red-50 hover:text-red-600"
                          >
                            <Trash2 className="h-3.5 w-3.5" />
                          </button>
                        </div>
                      </li>
                    ))}
                  </ul>
                )}
              </div>

              {/* Teléfonos */}
              <div className="space-y-3">
                <div className="flex items-center justify-between">
                  <div className="flex items-center gap-2">
                    <Phone className="h-4 w-4 text-slate-400" />
                    <p className="text-sm font-semibold text-slate-700">Teléfonos</p>
                  </div>
                  <button
                    onClick={() => { setShowTelForm(!showTelForm); setShowEmailForm(false) }}
                    className="text-xs text-blue-600 hover:text-blue-700 font-medium"
                  >
                    {showTelForm ? "Cancelar" : "+ Agregar"}
                  </button>
                </div>

                {showTelForm && (
                  <form onSubmit={handleTelSubmit(handleAddTel)} className="space-y-2 rounded-lg border bg-white p-3">
                    <div className="flex gap-2">
                      <Input
                        placeholder="55 1234 5678"
                        {...registerTel("numero")}
                        className="flex-1 text-sm"
                      />
                      <select
                        {...registerTel("tipo")}
                        className="rounded-md border border-input bg-white px-2 py-1.5 text-sm"
                      >
                        <option value="celular">Celular</option>
                        <option value="oficina">Oficina</option>
                        <option value="casa">Casa</option>
                        <option value="whatsapp">WhatsApp</option>
                        <option value="otro">Otro</option>
                      </select>
                    </div>
                    {telErrors.numero && <p className="text-xs text-destructive">{telErrors.numero.message}</p>}
                    {telError && <p className="text-xs text-destructive">{telError}</p>}
                    <div className="flex justify-end gap-2">
                      <Button type="button" size="sm" variant="outline" onClick={() => setShowTelForm(false)}>
                        Cancelar
                      </Button>
                      <Button type="submit" size="sm" disabled={addingTel}>
                        {addingTel ? "..." : "Agregar"}
                      </Button>
                    </div>
                  </form>
                )}

                {agente.telefonos.length === 0 ? (
                  <p className="text-xs text-slate-400 py-2">Sin teléfonos registrados.</p>
                ) : (
                  <ul className="space-y-1.5">
                    {agente.telefonos.map((t) => (
                      <li
                        key={t.id}
                        className="flex items-center justify-between rounded-lg border px-3 py-2.5 text-sm"
                      >
                        <div className="flex items-center gap-2 min-w-0">
                          <Phone className="h-3.5 w-3.5 shrink-0 text-slate-400" />
                          <span className={`font-mono text-sm ${t.preferente ? "font-semibold text-slate-900" : "text-slate-600"}`}>
                            {t.numero}
                          </span>
                          <span className="text-xs text-slate-400">
                            {TIPO_TELEFONO_LABELS[t.tipo] ?? t.tipo}
                          </span>
                          {t.preferente && (
                            <span className="shrink-0 rounded bg-blue-100 px-1.5 py-0.5 text-xs text-blue-700 font-medium">
                              Principal
                            </span>
                          )}
                        </div>
                        <button
                          onClick={() => handleDeleteTel(t.id)}
                          title="Eliminar"
                          className="rounded p-1 text-slate-400 hover:bg-red-50 hover:text-red-600 shrink-0"
                        >
                          <Trash2 className="h-3.5 w-3.5" />
                        </button>
                      </li>
                    ))}
                  </ul>
                )}
              </div>
            </div>
          )}

          {/* ── TAB: Asistentes ── */}
          {activeTab === "asistentes" && (
            <div className="space-y-3">
              <div className="flex items-center justify-between">
                <div className="flex items-center gap-2">
                  <Wifi className="h-4 w-4 text-slate-400" />
                  <p className="text-sm font-semibold text-slate-700">Asistentes / Trabajadores</p>
                </div>
                <button
                  onClick={() => {
                    setEditingAsistente(null)
                    resetAsistente()
                    setShowAsistenteForm(!showAsistenteForm)
                  }}
                  className="text-xs text-blue-600 hover:text-blue-700 font-medium"
                >
                  {showAsistenteForm ? "Cancelar" : "+ Agregar asistente"}
                </button>
              </div>

              {showAsistenteForm && (
                <form
                  onSubmit={handleAsistenteSubmit(editingAsistente ? handleUpdateAsistente : handleAddAsistente)}
                  className="space-y-3 rounded-lg border bg-slate-50 p-4"
                >
                  <p className="text-xs font-semibold uppercase tracking-wide text-slate-500">
                    {editingAsistente ? "Editar asistente" : "Nuevo asistente"}
                  </p>

                  <div className="space-y-1.5">
                    <Label>Nombre completo *</Label>
                    <Input
                      placeholder="Nombre completo"
                      {...registerAsistente("nombre")}
                    />
                    {asistenteErrors.nombre && (
                      <p className="text-xs text-destructive">{asistenteErrors.nombre.message}</p>
                    )}
                  </div>

                  <div className="space-y-1.5">
                    <Label>Correo electrónico *</Label>
                    <Input
                      type="email"
                      placeholder="asistente@email.com"
                      {...registerAsistente("email")}
                      disabled={!!editingAsistente}
                    />
                    {asistenteErrors.email && (
                      <p className="text-xs text-destructive">{asistenteErrors.email.message}</p>
                    )}
                    {editingAsistente && (
                      <p className="text-xs text-slate-400">El correo no se puede cambiar.</p>
                    )}
                  </div>

                  <div className="space-y-1.5">
                    <Label>Teléfono</Label>
                    <Input
                      placeholder="55 1234 5678"
                      {...registerAsistente("telefono")}
                    />
                  </div>

                  {asistenteError && (
                    <p className="text-xs text-destructive">{asistenteError}</p>
                  )}

                  <div className="flex gap-2">
                    <Button
                      type="button"
                      variant="outline"
                      size="sm"
                      onClick={() => {
                        setShowAsistenteForm(false)
                        setEditingAsistente(null)
                        resetAsistente()
                      }}
                      className="flex-1"
                    >
                      Cancelar
                    </Button>
                    <Button type="submit" size="sm" disabled={addingAsistente} className="flex-1">
                      {addingAsistente ? "..." : editingAsistente ? "Actualizar" : "Agregar"}
                    </Button>
                  </div>
                </form>
              )}

              {agente.asistentes.length === 0 && !showAsistenteForm ? (
                <div className="flex flex-col items-center gap-2 rounded-lg border border-dashed py-8 text-center">
                  <Wifi className="h-8 w-8 text-slate-300" />
                  <div>
                    <p className="text-sm font-medium text-slate-500">Sin asistentes registrados</p>
                    <p className="text-xs text-slate-400">Agrega asistentes que operan a nombre del agente.</p>
                  </div>
                </div>
              ) : (
                <ul className="space-y-2">
                  {agente.asistentes.map((a) => (
                    <li
                      key={a.id}
                      className={`rounded-lg border px-4 py-3 text-sm ${a.activo ? "" : "opacity-50 bg-slate-50"}`}
                    >
                      <div className="flex items-start justify-between gap-2">
                        <div className="min-w-0">
                          <p className={`font-medium ${a.activo ? "text-slate-900" : "text-slate-400"}`}>
                            {a.nombre}
                          </p>
                          <p className="text-xs text-slate-500">{a.email}</p>
                          {a.telefono && (
                            <p className="text-xs text-slate-400 font-mono">{a.telefono}</p>
                          )}
                        </div>
                        <div className="flex items-center gap-1 shrink-0">
                          {!a.activo && (
                            <span className="rounded bg-red-100 px-1.5 py-0.5 text-xs text-red-600">Inactivo</span>
                          )}
                          <button
                            onClick={() => {
                              setEditingAsistente(a)
                              setShowAsistenteForm(true)
                              setShowEmailForm(false)
                              setShowTelForm(false)
                              resetAsistente({
                                nombre:   a.nombre,
                                email:      a.email,
                                telefono:   a.telefono ?? "",
                              })
                            }}
                            className="rounded p-1 text-slate-400 hover:bg-slate-100 hover:text-blue-600"
                            title="Editar"
                          >
                            <Pencil className="h-3.5 w-3.5" />
                          </button>
                          <button
                            onClick={() => handleToggleActivoAsistente(a.id, a.activo)}
                            title={a.activo ? "Desactivar" : "Activar"}
                            className={`rounded p-1 ${a.activo ? "text-slate-400 hover:bg-red-50 hover:text-red-600" : "text-emerald-600 hover:bg-emerald-50"}`}
                          >
                            <CheckCircle2 className="h-3.5 w-3.5" />
                          </button>
                          <button
                            onClick={() => handleDeleteAsistente(a.id)}
                            title="Eliminar asistente"
                            className="rounded p-1 text-slate-400 hover:bg-red-50 hover:text-red-600"
                          >
                            <Trash2 className="h-3.5 w-3.5" />
                          </button>
                        </div>
                      </div>
                    </li>
                  ))}
                </ul>
              )}
            </div>
          )}

          {/* Cambiar estatus */}
          <div className={`mt-4 rounded-lg border px-4 py-3 ${agente.activo ? "border-red-200 bg-red-50" : "border-emerald-200 bg-emerald-50"}`}>
            <p className={`text-xs font-semibold uppercase tracking-wide ${agente.activo ? "text-red-700" : "text-emerald-700"}`}>
              {agente.activo ? "Zona de riesgo" : "Agente inactivo"}
            </p>
            <p className={`mt-0.5 text-xs mb-2 ${agente.activo ? "text-red-600" : "text-emerald-600"}`}>
              {agente.activo
                ? "Desactivar un agente lo marca como inactivo. No elimina su historial."
                : "Este agente está inactivo y no puede enviar trámites."}
            </p>
            <Button
              type="button"
              variant="outline"
              size="sm"
              className={`w-full ${agente.activo ? "border-red-200 text-red-600 hover:bg-red-100" : "border-emerald-200 text-emerald-700 hover:bg-emerald-100"}`}
              onClick={handleToggleActivo}
            >
              {agente.activo ? "Desactivar agente" : "Reactivar agente"}
            </Button>
          </div>
        </div>
      ) : null}
    </SlideOver>
  )
}
