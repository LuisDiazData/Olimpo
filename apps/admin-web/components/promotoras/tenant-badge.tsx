import { Badge } from "@/components/ui/badge"

const config: Record<string, { label: string; variant: "success" | "info" | "destructive" | "outline" }> = {
  activa: { label: "Activa", variant: "success" },
  prueba: { label: "Prueba", variant: "info" },
  suspendida: { label: "Suspendida", variant: "destructive" },
  expirada: { label: "Expirada", variant: "outline" },
}

export function TenantBadge({ estado }: { estado: string }) {
  const { label, variant } = config[estado] ?? { label: estado, variant: "outline" }
  return <Badge variant={variant}>{label}</Badge>
}
