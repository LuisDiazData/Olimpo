"use client"

import { useState } from "react"
import { cn } from "@/lib/utils"
import { TramiteDetalleDrawer } from "./tramite-detalle-drawer"
import { TramitesTarjetas } from "./tramites-tarjetas"
import { TramitesTabla } from "./tramites-tabla"
import type { TramiteRow, TabValue, VistaValue } from "./types"

interface Props {
  rows: TramiteRow[]
  tab: TabValue
  vista: VistaValue
  hasFilters: boolean
}

export function TramitesView({ rows, tab, vista, hasFilters }: Props) {
  const [selected, setSelected] = useState<TramiteRow | null>(null)

  return (
    <>
      {vista === "lista" ? (
        <div className="overflow-hidden rounded-xl border bg-white shadow-sm">
          <TramitesTabla rows={rows} tab={tab} hasFilters={hasFilters} onSelect={setSelected} />
        </div>
      ) : (
        <TramitesTarjetas rows={rows} tab={tab} hasFilters={hasFilters} onSelect={setSelected} />
      )}
      <TramiteDetalleDrawer tramite={selected} onClose={() => setSelected(null)} />
    </>
  )
}