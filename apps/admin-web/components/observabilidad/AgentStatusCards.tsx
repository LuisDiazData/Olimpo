"use client";

import { useEffect, useState } from "react";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Activity, Bot, CheckCircle2, Clock, Zap } from "lucide-react";
import { Badge } from "@/components/ui/badge";
import { api } from "@/lib/api-client";

interface AgentStatus {
  nombre: string;
  estado: string;
  tramites_activos: number;
}

export function AgentStatusCards() {
  const [agentes, setAgentes] = useState<AgentStatus[]>([]);
  const [loading, setLoading] = useState(true);

  const fetchStatus = async () => {
    try {
      const data = await api.get<{ agentes?: AgentStatus[] }>("/observabilidad/estado-actual");
      setAgentes(data.agentes || []);
    } catch (error) {
      console.error("Error fetching agent status:", error);
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    fetchStatus();
    const interval = setInterval(fetchStatus, 10000);
    return () => clearInterval(interval);
  }, []);

  const getAgentRole = (nombre: string) => {
    const roles: Record<string, string> = {
      agente_1: "Ingesta y Triage",
      agente_2: "Clasificador Documental",
      agente_3: "Extractor de Datos (OCR)",
      agente_4: "Analista de Validaciones",
      agente_5: "Motor Reglas de Negocio",
      agente_6: "Resolución y Cierre",
    };
    return roles[nombre] || "Agente IA";
  };

  if (loading && agentes.length === 0) {
    return (
      <div className="grid gap-4 md:grid-cols-2 lg:grid-cols-3">
        {[1, 2, 3, 4, 5, 6].map((i) => (
          <Card key={i} className="animate-pulse">
            <CardHeader className="flex flex-row items-center justify-between pb-2">
              <CardTitle className="text-sm font-medium text-slate-300 bg-slate-200 h-4 w-24 rounded"></CardTitle>
            </CardHeader>
            <CardContent>
              <div className="text-2xl font-bold bg-slate-200 h-8 w-16 rounded mt-2"></div>
            </CardContent>
          </Card>
        ))}
      </div>
    );
  }

  return (
    <div className="grid gap-4 md:grid-cols-2 lg:grid-cols-3">
      {agentes.map((agente) => {
        const isProcessing = agente.estado === "procesando";
        return (
          <Card key={agente.nombre} className={`shadow-sm transition-all duration-300 ${isProcessing ? 'border-blue-500/50 shadow-blue-500/10 shadow-lg' : ''}`}>
            <CardHeader className="flex flex-row items-center justify-between space-y-0 pb-2">
              <CardTitle className="text-sm font-medium flex items-center gap-2">
                <Bot className={`h-4 w-4 ${isProcessing ? 'text-blue-500' : 'text-slate-400'}`} />
                {agente.nombre.toUpperCase()}
              </CardTitle>
              {isProcessing ? (
                <Badge variant="default" className="bg-blue-500/10 text-blue-600 hover:bg-blue-500/20 shadow-none border-blue-500/20">
                  <Activity className="w-3 h-3 mr-1 animate-pulse" />
                  Procesando
                </Badge>
              ) : (
                <Badge variant="outline" className="text-slate-500 bg-slate-100">
                  <Clock className="w-3 h-3 mr-1" />
                  Idle
                </Badge>
              )}
            </CardHeader>
            <CardContent>
              <div className="text-2xl font-bold mt-1">
                {agente.tramites_activos} <span className="text-sm font-normal text-slate-500">trámites</span>
              </div>
              <p className="text-xs text-muted-foreground mt-1 flex items-center">
                {getAgentRole(agente.nombre)}
              </p>
            </CardContent>
          </Card>
        );
      })}
    </div>
  );
}
