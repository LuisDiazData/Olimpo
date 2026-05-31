"use client"

import { use } from "react"
import Link from "next/link"
import { ArrowLeft, Globe, Lock, LockOpen } from "lucide-react"
import { useTenant, useBlockTenant, useActivateTenant } from "@/hooks/use-tenants"
import { LicenciaCard } from "@/components/promotoras/licencia-card"
import { DirectorCard } from "@/components/promotoras/director-card"
import { Button } from "@/components/ui/button"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"

function formatDate(iso: string) {
  return new Date(iso).toLocaleDateString("es-MX", {
    day: "2-digit", month: "long", year: "numeric",
  })
}

export default function TenantDetailPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = use(params)
  const { data: tenant, isLoading, error } = useTenant(id)
  const block = useBlockTenant()
  const activate = useActivateTenant()

  if (isLoading) return <div className="text-sm text-muted-foreground">Cargando...</div>
  if (error || !tenant) return <div className="text-sm text-destructive">Promotoría no encontrada.</div>

  return (
    <div className="max-w-2xl space-y-6">
      <div className="flex items-center gap-3">
        <Button asChild variant="ghost" size="sm">
          <Link href="/promotoras">
            <ArrowLeft className="h-4 w-4" />
          </Link>
        </Button>
        <div>
          <h1 className="text-xl font-semibold">{tenant.nombre}</h1>
          <p className="text-sm text-muted-foreground">{tenant.subdominio}</p>
        </div>
      </div>

      {/* Información general */}
      <Card>
        <CardHeader className="pb-2">
          <CardTitle className="text-sm font-semibold">Información general</CardTitle>
        </CardHeader>
        <CardContent className="space-y-4">
          <div className="grid grid-cols-2 gap-4 text-sm">
            <div>
              <p className="text-muted-foreground">URL Supabase</p>
              <a
                href={tenant.supabase_url}
                target="_blank"
                rel="noopener noreferrer"
                className="flex items-center gap-1 font-medium hover:underline"
              >
                <Globe className="h-3.5 w-3.5" />
                {tenant.supabase_url}
              </a>
            </div>
            <div>
              <p className="text-muted-foreground">Registrada el</p>
              <p className="font-medium">{formatDate(tenant.created_at)}</p>
            </div>
            <div>
              <p className="text-muted-foreground">Acceso superadmin</p>
              <p className={`font-medium ${tenant.activo ? "text-green-700" : "text-destructive"}`}>
                {tenant.activo ? "Habilitado" : "Bloqueado"}
              </p>
            </div>
          </div>

          <div className="flex gap-2 pt-2">
            {tenant.activo ? (
              <Button
                size="sm"
                variant="outline"
                className="text-destructive hover:text-destructive"
                onClick={() => block.mutate(id)}
                disabled={block.isPending}
              >
                <Lock className="h-3.5 w-3.5" />
                Bloquear acceso
              </Button>
            ) : (
              <Button
                size="sm"
                variant="outline"
                onClick={() => activate.mutate(id)}
                disabled={activate.isPending}
              >
                <LockOpen className="h-3.5 w-3.5" />
                Reactivar acceso
              </Button>
            )}
          </div>
        </CardContent>
      </Card>

      {/* Licencia */}
      <LicenciaCard tenant={tenant} />

      {/* Director */}
      <DirectorCard tenant={tenant} />
    </div>
  )
}
