"use client"

import { AlertTriangle } from "lucide-react"
import type { TopRechazo } from "@/app/(dashboard)/dashboard/data"

interface Props {
  rechazos: TopRechazo[]
}

export function TopRechazosList({ rechazos }: Props) {
  if (rechazos.length === 0) {
    return (
      <div className="flex items-center gap-2 rounded-lg border border-dashed bg-slate-50 px-4 py-6 text-sm text-muted-foreground">
        <AlertTriangle className="h-4 w-4" />
        Sin rechazos validados aún.
      </div>
    )
  }

  return (
    <div className="space-y-2">
      {rechazos.map((r, i) => (
        <div key={i} className="flex items-start gap-3 rounded-lg border px-3 py-2.5">
          <div className="flex h-5 w-5 shrink-0 items-center justify-center rounded-full bg-red-100">
            <span className="text-[10px] font-bold text-red-600">{i + 1}</span>
          </div>
          <div className="min-w-0 flex-1">
            <p className="text-sm text-slate-700 leading-relaxed">{r.motivo_rechazo}</p>
          </div>
        </div>
      ))}
    </div>
  )
}
