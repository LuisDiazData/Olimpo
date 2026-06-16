"use client";

import { useEffect, useState } from "react";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Activity, Server, AlertTriangle, CheckCircle2, Clock } from "lucide-react";
import { Badge } from "@/components/ui/badge";
import { api } from "@/lib/api";

interface EstadoMonitor {
  status: string;
  total_active_tasks: number;
  total_queued_tasks: number;
  workers: unknown[];
}
interface EventoIA {
  id: string;
  es_error: boolean;
  created_at: string;
  agente_ia_nombre: string;
  tramite_id: string;
  descripcion: string;
}

export default function ObservabilidadPage() {
  const [estado, setEstado] = useState<EstadoMonitor>({
    status: "Cargando...",
    total_active_tasks: 0,
    total_queued_tasks: 0,
    workers: []
  });
  const [eventos, setEventos] = useState<EventoIA[]>([]);
  const [loading, setLoading] = useState(true);

  const fetchData = async () => {
    try {
      const [resEstado, resEventos] = await Promise.all([
        api.get<EstadoMonitor>("/observabilidad/estado"),
        api.get<EventoIA[]>("/observabilidad/eventos"),
      ]);
      setEstado(resEstado);
      setEventos(resEventos);
    } catch (error) {
      console.error(error);
      setEstado(prev => ({ ...prev, status: "OFFLINE" }));
    } finally {
      setLoading(false);
    }
  };

  // Poll every 10 seconds
  useEffect(() => {
    fetchData();
    const interval = setInterval(fetchData, 10000);
    return () => clearInterval(interval);
  }, []);

  return (
    <div className="flex-1 space-y-4 p-8 pt-6">
      <div className="flex items-center justify-between space-y-2">
        <h2 className="text-3xl font-bold tracking-tight">Monitor IA (Command Center)</h2>
        <div className="flex items-center space-x-2">
          {estado.status === "ONLINE" ? (
            <Badge variant="green">Sistema Operativo</Badge>
          ) : estado.status === "OFFLINE" ? (
            <Badge variant="red">Celery Apagado</Badge>
          ) : (
            <Badge variant="slate">{estado.status}</Badge>
          )}
        </div>
      </div>

      <div className="grid gap-4 md:grid-cols-3">
        <Card>
          <CardHeader className="flex flex-row items-center justify-between space-y-0 pb-2">
            <CardTitle className="text-sm font-medium">Workers Activos</CardTitle>
            <Server className="h-4 w-4 text-muted-foreground" />
          </CardHeader>
          <CardContent>
            <div className="text-2xl font-bold">{estado.workers?.length || 0}</div>
            <p className="text-xs text-muted-foreground">Procesos de Celery</p>
          </CardContent>
        </Card>
        <Card>
          <CardHeader className="flex flex-row items-center justify-between space-y-0 pb-2">
            <CardTitle className="text-sm font-medium">Tareas Procesando</CardTitle>
            <Activity className="h-4 w-4 text-muted-foreground" />
          </CardHeader>
          <CardContent>
            <div className="text-2xl font-bold">{estado.total_active_tasks}</div>
            <p className="text-xs text-muted-foreground">En ejecución este segundo</p>
          </CardContent>
        </Card>
        <Card>
          <CardHeader className="flex flex-row items-center justify-between space-y-0 pb-2">
            <CardTitle className="text-sm font-medium">Tareas Encoladas</CardTitle>
            <Clock className="h-4 w-4 text-muted-foreground" />
          </CardHeader>
          <CardContent>
            <div className="text-2xl font-bold">{estado.total_queued_tasks}</div>
            <p className="text-xs text-muted-foreground">Esperando recursos</p>
          </CardContent>
        </Card>
      </div>

      <Card className="col-span-4">
        <CardHeader>
          <CardTitle>Consola de Actividad (Live Feed)</CardTitle>
        </CardHeader>
        <CardContent>
          <table className="w-full text-sm">
            <thead>
              <tr className="border-b text-left text-muted-foreground">
                <th className="py-2 font-medium">Hora</th>
                <th className="py-2 font-medium">Agente</th>
                <th className="py-2 font-medium">Trámite</th>
                <th className="py-2 font-medium">Acción</th>
              </tr>
            </thead>
            <tbody>
              {loading && eventos.length === 0 ? (
                <tr><td colSpan={4} className="py-3">Cargando eventos...</td></tr>
              ) : eventos.length === 0 ? (
                <tr><td colSpan={4} className="py-3">No hay actividad reciente de los agentes.</td></tr>
              ) : (
                eventos.map(ev => (
                  <tr key={ev.id} className={`border-b last:border-0 ${ev.es_error ? "bg-red-50" : ""}`}>
                    <td className="py-2 font-medium text-xs text-muted-foreground">
                      {new Date(ev.created_at).toLocaleTimeString()}
                    </td>
                    <td className="py-2">
                      <Badge variant="slate" className="font-mono">{ev.agente_ia_nombre}</Badge>
                    </td>
                    <td className="py-2 font-mono text-xs">
                      {ev.tramite_id?.substring(0, 8)}...
                    </td>
                    <td className="py-2">
                      <div className="flex items-center">
                        {ev.es_error ? (
                          <AlertTriangle className="mr-2 h-4 w-4 text-red-500" />
                        ) : (
                          <CheckCircle2 className="mr-2 h-4 w-4 text-green-500" />
                        )}
                        <span className={ev.es_error ? "text-red-700 font-medium" : ""}>
                          {ev.descripcion}
                        </span>
                      </div>
                    </td>
                  </tr>
                ))
              )}
            </tbody>
          </table>
        </CardContent>
      </Card>
    </div>
  );
}
