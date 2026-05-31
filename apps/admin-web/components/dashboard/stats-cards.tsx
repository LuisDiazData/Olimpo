import { AlertTriangle, Building2, CheckCircle2, PauseCircle } from "lucide-react"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import type { StatsResponse } from "@/hooks/use-tenants"

export function StatsCards({ stats }: { stats: StatsResponse }) {
  const cards = [
    {
      title: "Total promotorías",
      value: stats.total_promotorias,
      icon: Building2,
      description: `${stats.en_prueba} en periodo de prueba`,
    },
    {
      title: "Licencias activas",
      value: stats.activas,
      icon: CheckCircle2,
      description: "Con pago confirmado",
      className: "text-green-600",
    },
    {
      title: "Suspendidas",
      value: stats.suspendidas,
      icon: PauseCircle,
      description: "Acceso bloqueado",
      className: stats.suspendidas > 0 ? "text-destructive" : undefined,
    },
    {
      title: "Vencen en 30 días",
      value: stats.venciendo_30_dias,
      icon: AlertTriangle,
      description: "Requieren renovación pronta",
      className: stats.venciendo_30_dias > 0 ? "text-amber-600" : undefined,
    },
  ]

  return (
    <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
      {cards.map((card) => (
        <Card key={card.title}>
          <CardHeader className="flex flex-row items-center justify-between pb-2">
            <CardTitle className="text-sm font-medium text-muted-foreground">{card.title}</CardTitle>
            <card.icon className={`h-4 w-4 text-muted-foreground ${card.className ?? ""}`} />
          </CardHeader>
          <CardContent>
            <div className={`text-2xl font-bold ${card.className ?? ""}`}>{card.value}</div>
            <p className="mt-1 text-xs text-muted-foreground">{card.description}</p>
          </CardContent>
        </Card>
      ))}
    </div>
  )
}
