"use client"

import { PieChart, Pie, Cell, Tooltip, Legend, ResponsiveContainer } from "recharts"
import type { SlaCount } from "@/app/(dashboard)/dashboard/data"

const SLA_CONFIG: Record<string, { label: string; color: string }> = {
  en_curso:   { label: "En Curso",   color: "#3b82f6" },
  cumplido:   { label: "Cumplido",   color: "#22c55e" },
  incumplido: { label: "Incumplido", color: "#ef4444" },
  pausado:    { label: "Pausado",    color: "#94a3b8" },
}

interface Props {
  data: SlaCount[]
  pct: number
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
      <p className="text-slate-600">{d.value} SLAs</p>
    </div>
  )
}

export function SlaRing({ data, pct }: Props) {
  const chartData = data.map((d) => ({
    name: SLA_CONFIG[d.estado]?.label ?? d.estado,
    value: d.count,
    fill: SLA_CONFIG[d.estado]?.color ?? "#94a3b8",
  }))

  if (chartData.length === 0 || chartData.every((d) => d.value === 0)) {
    return (
      <div className="flex h-44 items-center justify-center text-sm text-muted-foreground">
        Sin SLAs activos
      </div>
    )
  }

  const pctColor = pct >= 80 ? "#22c55e" : pct >= 60 ? "#f59e0b" : "#ef4444"

  return (
    <div className="relative">
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
      {/* Porcentaje en el centro */}
      <div
        className="pointer-events-none absolute inset-0 flex flex-col items-center justify-center"
        style={{ top: "-12px" }}
      >
        <span className="text-lg font-bold" style={{ color: pctColor }}>
          {pct}%
        </span>
        <span className="text-[10px] text-slate-400">cumplimiento</span>
      </div>
    </div>
  )
}
