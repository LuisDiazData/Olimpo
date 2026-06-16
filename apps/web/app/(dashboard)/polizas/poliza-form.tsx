"use client"

import * as React from "react"
import { useRouter } from "next/navigation"
import { Plus, Pencil, Loader2 } from "lucide-react"
import { SlideOver } from "@/components/ui/slide-over"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { cn } from "@/lib/utils"
import { api, ApiError } from "@/lib/api"
import type { AgenteOption, AnalistaOption, PolizaDetalle } from "./types"

const RAMO_OPTIONS = [
  { value: "vida", label: "Vida" },
  { value: "gmm", label: "GMM" },
  { value: "autos", label: "Autos" },
  { value: "pyme", label: "PyME" },
]

const ESTADO_OPTIONS = [
  { value: "en_tramite", label: "En trámite" },
  { value: "activa", label: "Activa" },
  { value: "vencida", label: "Vencida" },
  { value: "cancelada", label: "Cancelada" },
]

const MONEDA_OPTIONS = ["MXN", "USD"]

const SELECT_CLASS =
  "h-9 w-full rounded-md border bg-white px-2.5 text-sm text-slate-700 shadow-sm " +
  "focus:outline-none focus:ring-2 focus:ring-slate-300"

interface PolizaCreada {
  id: string
}

interface PolizaFormProps {
  open: boolean
  onClose: () => void
  agentes: AgenteOption[]
  analistas: AnalistaOption[]
  /** Si se provee, el formulario opera en modo edición. */
  poliza?: PolizaDetalle
}

function num(value: string): number | null {
  if (value.trim() === "") return null
  const n = Number(value)
  return Number.isNaN(n) ? null : n
}

export function PolizaForm({ open, onClose, agentes, analistas, poliza }: PolizaFormProps) {
  const router = useRouter()
  const esEdicion = !!poliza

  const [numeroPoliza, setNumeroPoliza] = React.useState("")
  const [ramo, setRamo] = React.useState("vida")
  const [agenteId, setAgenteId] = React.useState("")
  const [analistaId, setAnalistaId] = React.useState("")
  const [plan, setPlan] = React.useState("")
  const [fechaInicio, setFechaInicio] = React.useState("")
  const [fechaFin, setFechaFin] = React.useState("")
  const [estado, setEstado] = React.useState("en_tramite")
  const [primaNeta, setPrimaNeta] = React.useState("")
  const [moneda, setMoneda] = React.useState("MXN")
  const [porcentajeComision, setPorcentajeComision] = React.useState("")
  const [notas, setNotas] = React.useState("")

  const [saving, setSaving] = React.useState(false)
  const [error, setError] = React.useState<string | null>(null)

  // Sincronizar el estado del formulario al abrir (alta limpia o edición precargada)
  React.useEffect(() => {
    if (!open) return
    setError(null)
    if (poliza) {
      setNumeroPoliza(poliza.numero_poliza)
      setRamo(poliza.ramo)
      setAgenteId(poliza.agente_id)
      setAnalistaId(poliza.analista_id ?? "")
      setPlan(poliza.plan ?? "")
      setFechaInicio(poliza.fecha_inicio ?? "")
      setFechaFin(poliza.fecha_fin ?? "")
      setEstado(poliza.estado)
      setPrimaNeta(poliza.prima_neta != null ? String(poliza.prima_neta) : "")
      setMoneda(poliza.moneda ?? "MXN")
      setPorcentajeComision(
        poliza.porcentaje_comision != null ? String(poliza.porcentaje_comision) : ""
      )
      setNotas(poliza.notas ?? "")
    } else {
      setNumeroPoliza("")
      setRamo("vida")
      setAgenteId("")
      setAnalistaId("")
      setPlan("")
      setFechaInicio("")
      setFechaFin("")
      setEstado("en_tramite")
      setPrimaNeta("")
      setMoneda("MXN")
      setPorcentajeComision("")
      setNotas("")
    }
  }, [open, poliza])

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault()
    setError(null)

    if (!numeroPoliza.trim()) {
      setError("El número de póliza es obligatorio.")
      return
    }
    if (!esEdicion && !agenteId) {
      setError("Selecciona el agente de la póliza.")
      return
    }

    setSaving(true)
    try {
      if (esEdicion && poliza) {
        // PATCH: solo campos editables (numero_poliza, agente_id y ramo son inmutables)
        await api.patch(`/polizas/${poliza.id}`, {
          plan: plan.trim() || null,
          fecha_inicio: fechaInicio || null,
          fecha_fin: fechaFin || null,
          estado,
          analista_id: analistaId || null,
          prima_neta: num(primaNeta),
          moneda,
          porcentaje_comision: num(porcentajeComision),
          notas: notas.trim() || null,
        })
        onClose()
        router.refresh()
      } else {
        const creada = await api.post<PolizaCreada>("/polizas", {
          numero_poliza: numeroPoliza.trim(),
          ramo,
          agente_id: agenteId,
          analista_id: analistaId || null,
          plan: plan.trim() || null,
          fecha_inicio: fechaInicio || null,
          fecha_fin: fechaFin || null,
          prima_neta: num(primaNeta),
          moneda,
          porcentaje_comision: num(porcentajeComision),
          notas: notas.trim() || null,
        })
        onClose()
        if (creada?.id) router.push(`/polizas/${creada.id}`)
        else router.refresh()
      }
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "No se pudo guardar la póliza.")
    } finally {
      setSaving(false)
    }
  }

  return (
    <SlideOver open={open} onClose={onClose} title={esEdicion ? "Editar póliza" : "Nueva póliza"}>
      <form onSubmit={handleSubmit} className="space-y-4">
        {error && (
          <div className="rounded-lg border border-red-200 bg-red-50 px-3 py-2 text-sm text-red-700">
            {error}
          </div>
        )}

        <div className="space-y-1.5">
          <Label htmlFor="numero_poliza">Número de póliza *</Label>
          <Input
            id="numero_poliza"
            value={numeroPoliza}
            onChange={(e) => setNumeroPoliza(e.target.value)}
            placeholder="Ej: 12345678"
            disabled={esEdicion}
            autoFocus={!esEdicion}
          />
          {esEdicion && (
            <p className="text-[11px] text-slate-400">
              El número de póliza no puede modificarse.
            </p>
          )}
        </div>

        <div className="grid grid-cols-2 gap-3">
          <div className="space-y-1.5">
            <Label htmlFor="ramo">Ramo *</Label>
            <select
              id="ramo"
              value={ramo}
              onChange={(e) => setRamo(e.target.value)}
              className={cn(SELECT_CLASS, esEdicion && "cursor-not-allowed opacity-60")}
              disabled={esEdicion}
            >
              {RAMO_OPTIONS.map((o) => (
                <option key={o.value} value={o.value}>
                  {o.label}
                </option>
              ))}
            </select>
          </div>
          <div className="space-y-1.5">
            <Label htmlFor="plan">Plan</Label>
            <Input id="plan" value={plan} onChange={(e) => setPlan(e.target.value)} placeholder="Ej: Profesional" />
          </div>
        </div>

        <div className="space-y-1.5">
          <Label htmlFor="agente_id">Agente *</Label>
          <select
            id="agente_id"
            value={agenteId}
            onChange={(e) => setAgenteId(e.target.value)}
            className={cn(SELECT_CLASS, esEdicion && "cursor-not-allowed opacity-60")}
            disabled={esEdicion}
          >
            <option value="">Selecciona un agente…</option>
            {agentes.map((a) => (
              <option key={a.id} value={a.id}>
                {a.nombre}
                {a.cua ? ` · CUA ${a.cua}` : ""}
              </option>
            ))}
          </select>
          {esEdicion && (
            <p className="text-[11px] text-slate-400">
              Para cambiar de agente, crea una nueva póliza.
            </p>
          )}
        </div>

        <div className="space-y-1.5">
          <Label htmlFor="analista_id">Analista asignado</Label>
          <select
            id="analista_id"
            value={analistaId}
            onChange={(e) => setAnalistaId(e.target.value)}
            className={SELECT_CLASS}
          >
            <option value="">Sin asignar</option>
            {analistas.map((a) => (
              <option key={a.id} value={a.id}>
                {a.nombre}
              </option>
            ))}
          </select>
        </div>

        {esEdicion && (
          <div className="space-y-1.5">
            <Label htmlFor="estado">Estado</Label>
            <select
              id="estado"
              value={estado}
              onChange={(e) => setEstado(e.target.value)}
              className={SELECT_CLASS}
            >
              {ESTADO_OPTIONS.map((o) => (
                <option key={o.value} value={o.value}>
                  {o.label}
                </option>
              ))}
            </select>
          </div>
        )}

        <div className="grid grid-cols-2 gap-3">
          <div className="space-y-1.5">
            <Label htmlFor="fecha_inicio">Inicio de vigencia</Label>
            <Input
              id="fecha_inicio"
              type="date"
              value={fechaInicio}
              onChange={(e) => setFechaInicio(e.target.value)}
            />
          </div>
          <div className="space-y-1.5">
            <Label htmlFor="fecha_fin">Fin de vigencia</Label>
            <Input
              id="fecha_fin"
              type="date"
              value={fechaFin}
              onChange={(e) => setFechaFin(e.target.value)}
            />
          </div>
        </div>

        <div className="grid grid-cols-3 gap-3">
          <div className="space-y-1.5 col-span-2">
            <Label htmlFor="prima_neta">Prima neta</Label>
            <Input
              id="prima_neta"
              type="number"
              step="0.01"
              min="0"
              value={primaNeta}
              onChange={(e) => setPrimaNeta(e.target.value)}
              placeholder="0.00"
            />
          </div>
          <div className="space-y-1.5">
            <Label htmlFor="moneda">Moneda</Label>
            <select
              id="moneda"
              value={moneda}
              onChange={(e) => setMoneda(e.target.value)}
              className={SELECT_CLASS}
            >
              {MONEDA_OPTIONS.map((m) => (
                <option key={m} value={m}>
                  {m}
                </option>
              ))}
            </select>
          </div>
        </div>

        <div className="space-y-1.5">
          <Label htmlFor="porcentaje_comision">% Comisión</Label>
          <Input
            id="porcentaje_comision"
            type="number"
            step="0.01"
            min="0"
            max="100"
            value={porcentajeComision}
            onChange={(e) => setPorcentajeComision(e.target.value)}
            placeholder="Ej: 10"
          />
          <p className="text-[11px] text-slate-400">
            El monto de comisión se calcula automáticamente (prima × %).
          </p>
        </div>

        <div className="space-y-1.5">
          <Label htmlFor="notas">Notas</Label>
          <textarea
            id="notas"
            value={notas}
            onChange={(e) => setNotas(e.target.value)}
            rows={3}
            className={cn(SELECT_CLASS, "h-auto py-2 resize-y")}
            placeholder="Notas internas sobre la póliza…"
          />
        </div>

        <div className="flex items-center justify-end gap-2 border-t pt-4">
          <Button type="button" variant="ghost" onClick={onClose} disabled={saving}>
            Cancelar
          </Button>
          <Button type="submit" disabled={saving}>
            {saving && <Loader2 className="mr-1.5 h-4 w-4 animate-spin" />}
            {esEdicion ? "Guardar cambios" : "Crear póliza"}
          </Button>
        </div>
      </form>
    </SlideOver>
  )
}

export function NuevaPolizaButton({
  agentes,
  analistas,
}: {
  agentes: AgenteOption[]
  analistas: AnalistaOption[]
}) {
  const [open, setOpen] = React.useState(false)
  return (
    <>
      <Button onClick={() => setOpen(true)} className="gap-1.5">
        <Plus className="h-4 w-4" />
        Nueva póliza
      </Button>
      <PolizaForm open={open} onClose={() => setOpen(false)} agentes={agentes} analistas={analistas} />
    </>
  )
}

export function EditarPolizaButton({
  poliza,
  agentes,
  analistas,
}: {
  poliza: PolizaDetalle
  agentes: AgenteOption[]
  analistas: AnalistaOption[]
}) {
  const [open, setOpen] = React.useState(false)
  return (
    <>
      <Button variant="outline" size="sm" onClick={() => setOpen(true)} className="gap-1.5">
        <Pencil className="h-3.5 w-3.5" />
        Editar
      </Button>
      <PolizaForm
        open={open}
        onClose={() => setOpen(false)}
        agentes={agentes}
        analistas={analistas}
        poliza={poliza}
      />
    </>
  )
}
