import Link from "next/link"
import { UserPlus, KeyRound } from "lucide-react"
import type { TenantDetail } from "@/hooks/use-tenants"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import { Button } from "@/components/ui/button"

export function DirectorCard({ tenant }: { tenant: TenantDetail }) {
  const tieneDirector = !!tenant.usuario_maestro_id

  return (
    <Card>
      <CardHeader className="pb-2">
        <CardTitle className="text-sm font-semibold">Director general</CardTitle>
      </CardHeader>
      <CardContent className="space-y-3">
        {tieneDirector ? (
          <>
            <div className="text-sm">
              <p className="text-muted-foreground">Email</p>
              <p className="font-medium">{tenant.usuario_maestro_email}</p>
            </div>
            <Button asChild size="sm" variant="outline">
              <Link href={`/promotoras/${tenant.id}/director`}>
                <KeyRound className="h-3.5 w-3.5" />
                Resetear contraseña
              </Link>
            </Button>
          </>
        ) : (
          <div className="space-y-3">
            <p className="text-sm text-muted-foreground">
              Esta promotoría no tiene director general asignado todavía.
            </p>
            <Button asChild size="sm">
              <Link href={`/promotoras/${tenant.id}/director`}>
                <UserPlus className="h-3.5 w-3.5" />
                Crear director
              </Link>
            </Button>
          </div>
        )}
      </CardContent>
    </Card>
  )
}
