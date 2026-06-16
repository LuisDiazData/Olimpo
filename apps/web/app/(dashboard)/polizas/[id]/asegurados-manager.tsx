"use client"

import * as React from "react"
import { Plus, Trash2, Loader2, UserPlus } from "lucide-react"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { cn } from "@/lib/utils"
import { api, ApiError } from "@/lib/api"
import { useUser } from "@/components/providers/user-provider"
import { ROL_ASEGURADO_BADGE } from "../shared"
import type { AseguradoVinculo } from "../types"

const ROL_OPTIONS = [
  { value: "titular", label: "Titular" },
  { value: "asegurado_adicional", label: "Asegurado adicional" },
  { value: "beneficiario", label: "Beneficiario" },
]

const SELECT_CLASS =
  "h-9 w-full rounded-md border bg-white px-2.5 text-sm text-slate-700 shadow-sm focus:outline-none focus:ring-2 focus:ring-slate-300"

interface Candidato {
  id: string
  nombre: string
  rfc: string | null
  curp: string | null
  similitud: number
}

interface BuscarOCrearResp {
  asegurado_id: string | null
  accion: string
  requiere_atencion: boolean
  candidatos: Candidato[]
}

interface PolizaConAsegurados {
  asegurados: AseguradoVinculo[]
}

export function AseguradosManager({
  polizaId,
  aseguradosIniciales,
}: {
  polizaId: string
  aseguradosIniciales: AseguradoVinculo[]
}) {
  const { perfil } = useUser()
  const puedeDesvincular = perfil ? ["director_general", "director_ops"].includes(perfil.rol) : false

  const [lista, setLista] = React.useState<AseguradoVinculo[]>(aseguradosIniciales)
  const [showForm, setShowForm] = React.useState(false)
  const [saving, setSaving] = React.useState(false)
  const [error, setError] = React.useState<string | null>(null)
  const [candidatos, setCandidatos] = React.useState<Candidato[]>([])

  // Form
  const [nombre, setNombre] = React.useState("")
  const [rfc, setRfc] = React.useState("")
  const [curp, setCurp] = React.useState("")
  const [rol, setRol] = React.useState("titular")
  const [parentesco, setParentesco] = React.useState("")
  const [porcentaje, setPorcentaje] = React.useState("")

  const esBeneficiario = rol === "beneficiario"

  function resetForm() {
    setNombre("")
    setRfc("")
    setCurp("")
    setRol("titular")
    setParentesco("")
    setPorcentaje("")
    setCandidatos([])
    setError(null)
  }

  async function refrescar() {
    try {
      const det = await api.get<PolizaConAsegurados>(`/polizas/${polizaId}`)
      setLista(det.asegurados ?? [])
    } catch {
      /* el estado local ya refleja el cambio principal */
    }
  }

  async function vincular(aseguradoId: string) {
    setSaving(true)
    setError(null)
    try {
      await api.post(`/polizas/${polizaId}/asegurados`, {
        asegurado_id: aseguradoId,
        rol,
        parentesco: esBeneficiario && parentesco.trim() ? parentesco.trim() : null,
        porcentaje: esBeneficiario && porcentaje.trim() ? Number(porcentaje) : null,
      })
      await refrescar()
      resetForm()
      setShowForm(false)
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "No se pudo vincular el asegurado.")
    } finally {
      setSaving(false)
    }
  }

  async function handleAgregar(e: React.FormEvent) {
    e.preventDefault()
    setError(null)
    if (!nombre.trim()) {
      setError("El nombre del asegurado es obligatorio.")
      return
    }
    setSaving(true)
    setCandidatos([])
    try {
      // 1. Resolución de identidad (RFC → CURP → nombre fuzzy → crear)
      const res = await api.post<BuscarOCrearResp>("/asegurados/buscar-o-crear", {
        nombre: nombre.trim(),
        rfc: rfc.trim() || null,
        curp: curp.trim() || null,
      })

      if (res.accion === "ambiguo" || !res.asegurado_id) {
        // Identidad ambigua: el analista debe elegir un candidato o afinar los datos
        setCandidatos(res.candidatos ?? [])
        setError(
          "Se encontraron asegurados similares. Vincula uno existente o afina RFC/CURP para crear uno nuevo."
        )
        setSaving(false)
        return
      }

      // 2. Vincular el asegurado resuelto a la póliza
      await vincular(res.asegurado_id)
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "No se pudo agregar el asegurado.")
      setSaving(false)
    }
  }

  async function handleDesvincular(vinculoId: string) {
    if (!confirm("¿Desvincular este asegurado de la póliza?")) return
    try {
      await api.delete(`/polizas/${polizaId}/asegurados/${vinculoId}`)
      setLista((prev) => prev.filter((a) => a.id !== vinculoId))
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "No se pudo desvincular.")
    }
  }

  return (
    <div className="space-y-3">
      {/* Lista */}
      {lista.length === 0 ? (
        <p className="py-6 text-center text-sm text-slate-400">Sin asegurados vinculados</p>
      ) : (
        <div className="space-y-2">
          {lista.map((a) => {
            const rolBadge = ROL_ASEGURADO_BADGE[a.rol]
            return (
              <div
                key={a.id}
                className="flex items-center justify-between gap-3 rounded-lg border px-3 py-2.5"
              >
                <div className="min-w-0">
                  <p className="truncate text-sm font-medium text-slate-800">
                    {a.asegurado_nombre ?? "—"}
                  </p>
                  <div className="mt-0.5 flex items-center gap-2 text-[11px] text-slate-400">
                    {a.asegurado_rfc && <span className="font-mono">{a.asegurado_rfc}</span>}
                    {a.parentesco && <span>{a.parentesco}</span>}
                    {a.porcentaje != null && <span>{a.porcentaje}%</span>}
                  </div>
                </div>
                <div className="flex shrink-0 items-center gap-2">
                  {rolBadge ? (
                    <Badge variant={rolBadge.variant}>{rolBadge.label}</Badge>
                  ) : (
                    <Badge variant="slate">{a.rol}</Badge>
                  )}
                  {puedeDesvincular && (
                    <button
                      onClick={() => handleDesvincular(a.id)}
                      className="rounded p-1 text-slate-400 transition-colors hover:bg-red-50 hover:text-red-600"
                      title="Desvincular"
                    >
                      <Trash2 className="h-4 w-4" />
                    </button>
                  )}
                </div>
              </div>
            )
          })}
        </div>
      )}

      {/* Acción agregar */}
      {!showForm ? (
        <Button variant="outline" size="sm" onClick={() => setShowForm(true)} className="gap-1.5">
          <Plus className="h-3.5 w-3.5" />
          Agregar asegurado
        </Button>
      ) : (
        <form onSubmit={handleAgregar} className="space-y-3 rounded-lg border bg-slate-50/60 p-4">
          {error && (
            <div className="rounded-md border border-amber-200 bg-amber-50 px-3 py-2 text-xs text-amber-800">
              {error}
            </div>
          )}

          {candidatos.length > 0 && (
            <div className="space-y-1.5">
              <p className="text-[11px] font-semibold uppercase tracking-wider text-slate-400">
                Candidatos existentes
              </p>
              {candidatos.map((c) => (
                <button
                  key={c.id}
                  type="button"
                  disabled={saving}
                  onClick={() => vincular(c.id)}
                  className="flex w-full items-center justify-between gap-2 rounded-md border bg-white px-3 py-2 text-left text-sm transition-colors hover:bg-slate-50 disabled:opacity-50"
                >
                  <span className="min-w-0">
                    <span className="block truncate text-slate-800">{c.nombre}</span>
                    {c.rfc && <span className="font-mono text-[11px] text-slate-400">{c.rfc}</span>}
                  </span>
                  <span className="flex shrink-0 items-center gap-1.5 text-xs text-blue-600">
                    <UserPlus className="h-3.5 w-3.5" />
                    Vincular
                  </span>
                </button>
              ))}
            </div>
          )}

          <div className="space-y-1.5">
            <Label htmlFor="aseg_nombre">Nombre *</Label>
            <Input
              id="aseg_nombre"
              value={nombre}
              onChange={(e) => setNombre(e.target.value)}
              placeholder="Nombre completo del asegurado"
            />
          </div>

          <div className="grid grid-cols-2 gap-3">
            <div className="space-y-1.5">
              <Label htmlFor="aseg_rfc">RFC</Label>
              <Input
                id="aseg_rfc"
                value={rfc}
                onChange={(e) => setRfc(e.target.value.toUpperCase())}
                placeholder="Opcional"
              />
            </div>
            <div className="space-y-1.5">
              <Label htmlFor="aseg_curp">CURP</Label>
              <Input
                id="aseg_curp"
                value={curp}
                onChange={(e) => setCurp(e.target.value.toUpperCase())}
                placeholder="Opcional"
              />
            </div>
          </div>

          <div className="space-y-1.5">
            <Label htmlFor="aseg_rol">Rol en la póliza</Label>
            <select id="aseg_rol" value={rol} onChange={(e) => setRol(e.target.value)} className={SELECT_CLASS}>
              {ROL_OPTIONS.map((o) => (
                <option key={o.value} value={o.value}>
                  {o.label}
                </option>
              ))}
            </select>
          </div>

          {esBeneficiario && (
            <div className="grid grid-cols-2 gap-3">
              <div className="space-y-1.5">
                <Label htmlFor="aseg_parentesco">Parentesco</Label>
                <Input
                  id="aseg_parentesco"
                  value={parentesco}
                  onChange={(e) => setParentesco(e.target.value)}
                  placeholder="Ej: Cónyuge"
                />
              </div>
              <div className="space-y-1.5">
                <Label htmlFor="aseg_porcentaje">% Beneficio</Label>
                <Input
                  id="aseg_porcentaje"
                  type="number"
                  min="0"
                  max="100"
                  step="0.01"
                  value={porcentaje}
                  onChange={(e) => setPorcentaje(e.target.value)}
                />
              </div>
            </div>
          )}

          <div className="flex items-center justify-end gap-2">
            <Button
              type="button"
              variant="ghost"
              size="sm"
              onClick={() => {
                setShowForm(false)
                resetForm()
              }}
              disabled={saving}
            >
              Cancelar
            </Button>
            <Button type="submit" size="sm" disabled={saving} className="gap-1.5">
              {saving && <Loader2 className="h-4 w-4 animate-spin" />}
              Buscar y vincular
            </Button>
          </div>
        </form>
      )}
    </div>
  )
}
