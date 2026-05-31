"use client"

import {
  BarChart,
  Bar,
  XAxis,
  YAxis,
  CartesianGrid,
  Tooltip,
  ResponsiveContainer,
  Cell,
} from "recharts"
import type { EstadoCount } from "@/app/(dashboard)/dashboard/data"

const ESTADO_CONFIG: Record<string, { label: string; color: string }> = {
  recibido:                   { label: "Recibido",              color: "#94a3b8" },
  en_revision:                { label: "En revisión",           color: "#3b82f6" },
  pendiente_documentos_agente:{ label: "Docs. pendientes",      color: "#f59e0b" },
  turnado_a_gnp:              { label: "Turnado a GNP",         color: "#8b5cf6" },
  activado_gnp:               { label: "Activado por GNP",      color: "#f97316" },
  complemento_en_revision:    { label: "Complemento en rev.",   color: "#06b6d4" },
  escalado:                   { label: "Escalado",              color: "#ec4899" },
  completado:                 { label: "Completado",             color: "#22c55e" },
  rechazado_gnp:              { label: "Rechazado por GNP",      color: "#ef4444" },
  cancelado:                  { label: "Cancelado",              color: "#6b7280" },
}

const ESTADO_ORDER = [
  "recibido",
  "en_revision",
  "pendiente_documentos_agente",
  "turnado_a_gnp",
  "activado_gnp",
  "complemento_en_revision",
  "escalado",
  "completado",
  "rechazado_gnp",
  "cancelado",
]

interface Props {
  data: EstadoCount[]
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
function CustomTooltip({ active, payload }: any) {
  if (!active || !payload?.length) return null
  const d = payload[0]
  return (
    <div className="rounded-lg border bg-white px-3 py-2 text-sm shadow-md">
      <p className="font-medium text-slate-800">{d.payload.label}</p>
      <p className="text-slate-600">
        {d.value} {d.value === 1 ? "trámite" : "trámites"}
      </p>
    </div>
  )
}

export function EstadoChart({ data }: Props) {
  const chartData = ESTADO_ORDER
    .map((estado) => {
      const found = data.find((d) => d.estado === estado)
      return {
        estado,
        label: ESTADO_CONFIG[estado]?.label ?? estado,
        count: found?.count ?? 0,
        color: ESTADO_CONFIG[estado]?.color ?? "#94a3b8",
      }
    })
    .filter((d) => d.count > 0)

  if (chartData.length === 0) {
    return (
      <div className="flex h-56 items-center justify-center text-sm text-muted-foreground">
        Sin trámites registrados
      </div>
    )
  }

  return (
    <ResponsiveContainer width="100%" height={220}>
      <BarChart data={chartData} layout="vertical" margin={{ left: 8, right: 16, top: 4, bottom: 4 }}>
        <CartesianGrid strokeDasharray="3 3" horizontal={false} stroke="#f1f5f9" />
        <XAxis type="number" tick={{ fontSize: 11 }} axisLine={false} tickLine={false} />
        <YAxis
          type="category"
          dataKey="label"
          width={150}
          tick={{ fontSize: 11 }}
          axisLine={false}
          tickLine={false}
        />
        <Tooltip content={<CustomTooltip />} cursor={{ fill: "#f8fafc" }} />
        <Bar dataKey="count" radius={[0, 4, 4, 0]}>
          {chartData.map((entry, i) => (
            <Cell key={i} fill={entry.color} />
          ))}
        </Bar>
      </BarChart>
    </ResponsiveContainer>
  )
}