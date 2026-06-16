import { AgentStatusCards } from "@/components/observabilidad/AgentStatusCards";
import { LiveFeed } from "@/components/observabilidad/LiveFeed";
import { AgentMetricsChart } from "@/components/observabilidad/AgentMetricsChart";

export const metadata = {
  title: "Observabilidad de Agentes IA",
};

export default function ObservabilidadPage() {
  return (
    <div className="flex-1 space-y-6 p-8 pt-6">
      <div className="flex items-center justify-between space-y-2">
        <h2 className="text-3xl font-bold tracking-tight">Observabilidad de Agentes IA</h2>
      </div>

      <div className="flex items-center space-x-2">
        <p className="text-muted-foreground">
          Monitoreo en tiempo real de la salud y actividad del enjambre de agentes (Swarm).
        </p>
      </div>

      {/* Tarjetas de estado */}
      <AgentStatusCards />

      {/* Feed en vivo y Métricas */}
      <div className="grid gap-4 grid-cols-1 xl:grid-cols-3">
        <LiveFeed />
        <AgentMetricsChart />
      </div>
    </div>
  );
}
