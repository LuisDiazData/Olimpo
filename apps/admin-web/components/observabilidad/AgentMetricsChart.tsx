"use client";

import { useEffect, useState } from "react";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Bar, BarChart, ResponsiveContainer, Tooltip, XAxis, YAxis } from "recharts";
import { api } from "@/lib/api-client";

interface MetricaAgente {
  nombre: string;
  eventos_24h: number;
  tasa_exito_estimada: number;
}

export function AgentMetricsChart() {
  const [metricas, setMetricas] = useState<MetricaAgente[]>([]);
  const [loading, setLoading] = useState(true);

  const fetchMetrics = async () => {
    try {
      const data = await api.get<{ metricas?: MetricaAgente[] }>("/observabilidad/metricas");
      const formattedData = (data.metricas ?? []).map((m) => ({
        ...m,
        name: m.nombre.replace("agente_", "A"),
      }));
      setMetricas(formattedData);
    } catch (error) {
      console.error("Error fetching metrics:", error);
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    fetchMetrics();
    const interval = setInterval(fetchMetrics, 30000); // 30s polling
    return () => clearInterval(interval);
  }, []);

  return (
    <Card className="col-span-full xl:col-span-1 shadow-sm">
      <CardHeader>
        <CardTitle>Carga de Trabajo (24h)</CardTitle>
        <CardDescription>
          Eventos procesados por cada agente en las últimas 24 horas.
        </CardDescription>
      </CardHeader>
      <CardContent>
        {loading && metricas.length === 0 ? (
          <div className="h-[300px] flex items-center justify-center text-slate-500 animate-pulse">
            Cargando métricas...
          </div>
        ) : (
          <div className="h-[300px] w-full mt-4">
            <ResponsiveContainer width="100%" height="100%">
              <BarChart data={metricas}>
                <XAxis 
                  dataKey="name" 
                  stroke="#888888" 
                  fontSize={12} 
                  tickLine={false} 
                  axisLine={false} 
                />
                <YAxis
                  stroke="#888888"
                  fontSize={12}
                  tickLine={false}
                  axisLine={false}
                  tickFormatter={(value) => `${value}`}
                />
                <Tooltip 
                  cursor={{fill: "rgba(0,0,0,0.05)"}}
                  contentStyle={{ borderRadius: '8px', border: 'none', boxShadow: '0 4px 6px -1px rgb(0 0 0 / 0.1)' }}
                />
                <Bar 
                  dataKey="eventos_24h" 
                  fill="currentColor" 
                  radius={[4, 4, 0, 0]} 
                  className="fill-indigo-500" 
                />
              </BarChart>
            </ResponsiveContainer>
          </div>
        )}
      </CardContent>
    </Card>
  );
}
