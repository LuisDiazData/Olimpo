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
import type { TipoCount } from "@/app/(dashboard)/dashboard/data"

const TIPO_CONFIG: Record<string, { label: string; color: string }> = {
  alta:         { label: "Alta",         color: "#3b82f6" },
  endoso:       { label: "Endoso",       color: "#8b5cf6" },
  renovacion:   { label: "Renovación",   color: "#0ea5e9" },
  cancelacion:  { label: "Cancelación",  color: "#f43f5e" },
  siniestro:    { label: "Siniestro",    color: "#f97316" },
  reactivacion: { label: "Reactivación", color: "#10b981" },
  consulta:     { label: "Consulta",     color: "#94a3b8" },
  desconocido:  { label: "Desconocido",  color: "#cbd5e1" },
}

interface Props {
  data: TipoCount[]
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

export function TipoChart({ data }: Props) {
  const chartData = data.map((d) => ({
    tipo: d.tipo,
    label: TIPO_CONFIG[d.tipo]?.label ?? d.tipo,
    count: d.count,
    color: TIPO_CONFIG[d.tipo]?.color ?? "#94a3b8",
  }))

  if (chartData.length === 0) {
    return (
      <div className="flex h-44 items-center justify-center text-sm text-muted-foreground">
        Sin trámites registrados
      </div>
    )
  }

  return (
    <ResponsiveContainer width="100%" height={180}>
      <BarChart data={chartData} margin={{ left: -16, right: 8, top: 4, bottom: 0 }}>
        <CartesianGrid strokeDasharray="3 3" vertical={false} stroke="#f1f5f9" />
        <XAxis
          dataKey="label"
          tick={{ fontSize: 10 }}
          axisLine={false}
          tickLine={false}
          interval={0}
          angle={-30}
          textAnchor="end"
          height={40}
        />
        <YAxis allowDecimals={false} tick={{ fontSize: 11 }} axisLine={false} tickLine={false} />
        <Tooltip content={<CustomTooltip />} cursor={{ fill: "#f8fafc" }} />
        <Bar dataKey="count" radius={[4, 4, 0, 0]}>
          {chartData.map((entry, i) => (
            <Cell key={i} fill={entry.color} />
          ))}
        </Bar>
      </BarChart>
    </ResponsiveContainer>
  )
}
