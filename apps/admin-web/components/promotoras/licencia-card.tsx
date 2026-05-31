"use client"

import { useState } from "react"
import { useForm } from "react-hook-form"
import { zodResolver } from "@hookform/resolvers/zod"
import { RefreshCw, PlayCircle, PauseCircle } from "lucide-react"
import { renovarLicenciaSchema, type RenovarLicenciaInput } from "@/lib/schemas"
import { useRenovarLicencia, useSuspenderLicencia, useActivarLicencia } from "@/hooks/use-licencias"
import type { TenantDetail } from "@/hooks/use-tenants"
import { TenantBadge } from "./tenant-badge"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import { Dialog, DialogContent, DialogHeader, DialogTitle, DialogFooter } from "@/components/ui/dialog"

function formatDate(iso: string | null) {
  if (!iso) return "—"
  return new Date(iso).toLocaleDateString("es-MX", { day: "2-digit", month: "long", year: "numeric" })
}

const planLabels: Record<string, string> = {
  basico: "Básico",
  profesional: "Profesional",
  enterprise: "Enterprise",
}

export function LicenciaCard({ tenant }: { tenant: TenantDetail }) {
  const [openRenovar, setOpenRenovar] = useState(false)

  const renovar = useRenovarLicencia(tenant.id)
  const suspender = useSuspenderLicencia(tenant.id)
  const activar = useActivarLicencia(tenant.id)

  const { register, handleSubmit, formState: { errors } } = useForm<RenovarLicenciaInput>({
    resolver: zodResolver(renovarLicenciaSchema),
    defaultValues: { dias: 365 },
  })

  async function onRenovar(data: RenovarLicenciaInput) {
    await renovar.mutateAsync(data)
    setOpenRenovar(false)
  }

  const isSuspendida = tenant.estado_licencia === "suspendida"

  return (
    <>
      <Card>
        <CardHeader className="flex flex-row items-center justify-between pb-2">
          <CardTitle className="text-sm font-semibold">Licencia</CardTitle>
          <TenantBadge estado={tenant.estado_licencia} />
        </CardHeader>
        <CardContent className="space-y-4">
          <div className="grid grid-cols-2 gap-4 text-sm">
            <div>
              <p className="text-muted-foreground">Plan</p>
              <p className="font-medium">{planLabels[tenant.tipo_plan] ?? tenant.tipo_plan}</p>
            </div>
            <div>
              <p className="text-muted-foreground">Inicio</p>
              <p className="font-medium">{formatDate(tenant.fecha_inicio_licencia)}</p>
            </div>
            <div>
              <p className="text-muted-foreground">Vencimiento</p>
              <p className="font-medium">{formatDate(tenant.fecha_vencimiento_licencia)}</p>
            </div>
          </div>

          <div className="flex flex-wrap gap-2 pt-2">
            <Button size="sm" variant="outline" onClick={() => setOpenRenovar(true)}>
              <RefreshCw className="h-3.5 w-3.5" />
              Renovar
            </Button>
            {isSuspendida ? (
              <Button
                size="sm"
                variant="outline"
                onClick={() => activar.mutate()}
                disabled={activar.isPending}
              >
                <PlayCircle className="h-3.5 w-3.5" />
                Activar licencia
              </Button>
            ) : (
              <Button
                size="sm"
                variant="outline"
                className="text-destructive hover:text-destructive"
                onClick={() => suspender.mutate()}
                disabled={suspender.isPending}
              >
                <PauseCircle className="h-3.5 w-3.5" />
                Suspender
              </Button>
            )}
          </div>
        </CardContent>
      </Card>

      <Dialog open={openRenovar} onOpenChange={setOpenRenovar}>
        <DialogContent className="max-w-sm">
          <DialogHeader>
            <DialogTitle>Renovar licencia</DialogTitle>
          </DialogHeader>
          <form onSubmit={handleSubmit(onRenovar)} className="space-y-4">
            <div className="space-y-1.5">
              <Label htmlFor="dias">Días a extender desde hoy</Label>
              <Input
                id="dias"
                type="number"
                min={30}
                max={1095}
                {...register("dias", { valueAsNumber: true })}
              />
              {errors.dias && <p className="text-xs text-destructive">{errors.dias.message}</p>}
              <p className="text-xs text-muted-foreground">Mínimo 30, máximo 1095 días.</p>
            </div>
            <DialogFooter>
              <Button type="button" variant="outline" onClick={() => setOpenRenovar(false)}>
                Cancelar
              </Button>
              <Button type="submit" disabled={renovar.isPending}>
                {renovar.isPending ? "Renovando..." : "Renovar"}
              </Button>
            </DialogFooter>
          </form>
        </DialogContent>
      </Dialog>
    </>
  )
}
