"use client"

import { useState } from "react"
import { PolizaDetalleDrawer } from "./poliza-detalle-drawer"
import { PolizasTabla } from "./polizas-tabla"
import { PolizasTarjetas } from "./polizas-tarjetas"
import type { PolizaRow, VistaValue } from "./types"

interface Props {
  rows: PolizaRow[]
  vista: VistaValue
  hasFilters: boolean
}

export function PolizasView({ rows, vista, hasFilters }: Props) {
  const [selected, setSelected] = useState<PolizaRow | null>(null)

  return (
    <>
      {vista === "lista" ? (
        <div className="overflow-hidden rounded-xl border bg-white shadow-sm">
          <PolizasTabla rows={rows} hasFilters={hasFilters} onSelect={setSelected} />
        </div>
      ) : (
        <PolizasTarjetas rows={rows} hasFilters={hasFilters} onSelect={setSelected} />
      )}
      <PolizaDetalleDrawer poliza={selected} onClose={() => setSelected(null)} />
    </>
  )
}
