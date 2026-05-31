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
import type { AnalistaCount } from "@/app/(dashboard)/dashboard/data"

interface Props {
  data: AnalistaCount[]
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
function CustomTooltip({ active, payload }: any) {
  if (!active || !payload?.length) return null
  const d = payload[0]
  return (
    <div className="rounded-lg border bg-white px-3 py-2 text-sm shadow-md">
      <p className="font-medium text-slate-800">{d.payload.nombre}</p>
      <p className="text-slate-600">
        {d.value} trámite{d.value !== 1 ? "s" : ""} activos
      </p>
    </div>
  )
}

export function AnalystWorkloadChart({ data }: Props) {
  const chartData = data.map((d) => ({
    id: d.analista_id,
    nombre: d.analista_nombre ?? "Sin asignar",
    count: d.count,
  }))

  if (chartData.length === 0) {
    return (
      <div className="flex h-44 items-center justify-center text-sm text-muted-foreground">
        Sin datos de carga
      </div>
    )
  }

  const max = Math.max(...chartData.map((d) => d.count))

  return (
    <ResponsiveContainer width="100%" height={220}>
      <BarChart
        data={chartData}
        layout="vertical"
        margin={{ left: 8, right: 16, top: 4, bottom: 4 }}
      >
        <CartesianGrid strokeDasharray="3 3" horizontal={false} stroke="#f1f5f9" />
        <XAxis type="number" tick={{ fontSize: 11 }} axisLine={false} tickLine={false} />
        <YAxis
          type="category"
          dataKey="nombre"
          width={120}
          tick={{ fontSize: 11 }}
          axisLine={false}
          tickLine={false}
        />
        <Tooltip content={<CustomTooltip />} cursor={{ fill: "#f8fafc" }} />
        <Bar dataKey="count" radius={[0, 4, 4, 0]}>
          {chartData.map((entry, i) => {
            const pct = entry.count / max
            const fill =
              pct >= 0.8 ? "#ef4444" : pct >= 0.5 ? "#f59e0b" : "#22c55e"
            return <Cell key={i} fill={fill} />
          })}
        </Bar>
      </BarChart>
    </ResponsiveContainer>
  )
}
