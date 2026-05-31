"use client"

import { PieChart, Pie, Cell, Tooltip, Legend, ResponsiveContainer } from "recharts"
import type { RamoCount } from "@/app/(dashboard)/dashboard/data"

const RAMO_CONFIG: Record<string, { label: string; color: string }> = {
  vida:  { label: "Vida",  color: "#f43f5e" },
  gmm:   { label: "GMM",   color: "#0ea5e9" },
  autos: { label: "Autos", color: "#f59e0b" },
  pyme:  { label: "PyME",  color: "#8b5cf6" },
}

interface Props {
  data: RamoCount[]
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
function CustomTooltip({ active, payload }: any) {
  if (!active || !payload?.length) return null
  const d = payload[0]
  return (
    <div className="rounded-lg border bg-white px-3 py-2 text-sm shadow-md">
      <p className="font-medium" style={{ color: d.payload.fill }}>
        {d.name}
      </p>
      <p className="text-slate-600">
        {d.value} {d.value === 1 ? "trámite" : "trámites"}
      </p>
    </div>
  )
}

export function RamoDonut({ data }: Props) {
  const chartData = data.map((d) => ({
    name: RAMO_CONFIG[d.ramo]?.label ?? d.ramo,
    value: d.count,
    fill: RAMO_CONFIG[d.ramo]?.color ?? "#94a3b8",
  }))

  if (chartData.length === 0 || chartData.every((d) => d.value === 0)) {
    return (
      <div className="flex h-44 items-center justify-center text-sm text-muted-foreground">
        Sin datos de ramo
      </div>
    )
  }

  return (
    <ResponsiveContainer width="100%" height={180}>
      <PieChart>
        <Pie
          data={chartData}
          cx="50%"
          cy="45%"
          innerRadius={42}
          outerRadius={68}
          paddingAngle={2}
          dataKey="value"
        >
          {chartData.map((entry, i) => (
            <Cell key={i} fill={entry.fill} />
          ))}
        </Pie>
        <Tooltip content={<CustomTooltip />} />
        <Legend
          iconType="circle"
          iconSize={8}
          wrapperStyle={{ fontSize: 11 }}
        />
      </PieChart>
    </ResponsiveContainer>
  )
}
