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
  LabelList,
} from "recharts"
import type { RamoRechazo } from "@/app/(dashboard)/dashboard/data"

const RAMO_CONFIG: Record<string, { label: string; color: string }> = {
  vida:  { label: "Vida",  color: "#f43f5e" },
  gmm:   { label: "GMM",   color: "#0ea5e9" },
  autos: { label: "Autos", color: "#f59e0b" },
  pyme:  { label: "PyME",  color: "#8b5cf6" },
}

interface Props {
  data: RamoRechazo[]
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
function CustomTooltip({ active, payload }: any) {
  if (!active || !payload?.length) return null
  const d = payload[0]
  const item = d.payload as RamoRechazo & { label: string }
  return (
    <div className="rounded-lg border bg-white px-3 py-2 text-sm shadow-md">
      <p className="font-medium text-slate-800">{item.label ?? item.ramo}</p>
      <p className="text-slate-600">
        {item.rechazados} rechazos de {item.total} resueltos ({item.pct_rechazo}%)
      </p>
    </div>
  )
}

export function GNPRejectionChart({ data }: Props) {
  const chartData = data.map((d) => ({
    ...d,
    label: RAMO_CONFIG[d.ramo]?.label ?? d.ramo,
    color: RAMO_CONFIG[d.ramo]?.color ?? "#94a3b8",
  }))

  if (chartData.length === 0) {
    return (
      <div className="flex h-44 items-center justify-center text-sm text-muted-foreground">
        Sin datos de rechazo
      </div>
    )
  }

  return (
    <ResponsiveContainer width="100%" height={180}>
      <BarChart data={chartData} margin={{ left: 0, right: 12, top: 4, bottom: 4 }}>
        <CartesianGrid strokeDasharray="3 3" vertical={false} stroke="#f1f5f9" />
        <XAxis
          dataKey="label"
          tick={{ fontSize: 11 }}
          axisLine={false}
          tickLine={false}
        />
        <YAxis
          allowDecimals={false}
          tick={{ fontSize: 11 }}
          axisLine={false}
          tickLine={false}
          width={28}
        />
        <Tooltip content={<CustomTooltip />} cursor={{ fill: "#f8fafc" }} />
        <Bar dataKey="rechazados" radius={[4, 4, 0, 0]} maxBarSize={50}>
          {chartData.map((entry, i) => (
            <Cell key={i} fill={entry.color} />
          ))}
          <LabelList
            dataKey="pct_rechazo"
            position="top"
            fontSize={10}
            formatter={(val: number) => (val > 0 ? `${val}%` : "")}
          />
        </Bar>
      </BarChart>
    </ResponsiveContainer>
  )
}
