"use client";

import { useEffect, useState } from "react";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import { Terminal } from "lucide-react";
import { api } from "@/lib/api-client";

interface EventoFeed {
  id: string;
  tramite_id: string;
  tipo_evento: string;
  agente_ia_nombre: string;
  descripcion: string;
  created_at: string;
  datos?: any;
}

export function LiveFeed() {
  const [eventos, setEventos] = useState<EventoFeed[]>([]);
  const [loading, setLoading] = useState(true);

  const fetchFeed = async () => {
    try {
      const data = await api.get<{ eventos?: EventoFeed[] }>("/observabilidad/feed");
      setEventos(data.eventos || []);
    } catch (error) {
      console.error("Error fetching feed:", error);
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    fetchFeed();
    const interval = setInterval(fetchFeed, 10000); // Polling cada 10s
    return () => clearInterval(interval);
  }, []);

  const getColorForAgent = (agent: string) => {
    const colors: Record<string, string> = {
      agente_1: "bg-blue-500/10 text-blue-500 border-blue-500/20",
      agente_2: "bg-purple-500/10 text-purple-500 border-purple-500/20",
      agente_3: "bg-pink-500/10 text-pink-500 border-pink-500/20",
      agente_4: "bg-green-500/10 text-green-500 border-green-500/20",
      agente_5: "bg-orange-500/10 text-orange-500 border-orange-500/20",
      agente_6: "bg-red-500/10 text-red-500 border-red-500/20",
    };
    return colors[agent] || "bg-gray-500/10 text-gray-500 border-gray-500/20";
  };

  return (
    <Card className="col-span-full xl:col-span-2 shadow-sm">
      <CardHeader className="border-b bg-muted/20 pb-4">
        <CardTitle className="flex items-center gap-2 text-lg font-medium">
          <Terminal className="h-5 w-5 text-muted-foreground" />
          Terminal en Vivo
          <div className="ml-2 flex h-2 w-2 rounded-full bg-green-500 animate-pulse" />
        </CardTitle>
      </CardHeader>
      <CardContent className="p-0">
        <div className="h-[400px] overflow-y-auto bg-slate-950 font-mono text-sm p-4 space-y-3">
          {loading && eventos.length === 0 ? (
            <div className="text-slate-500 animate-pulse">Conectando con agentes...</div>
          ) : eventos.length === 0 ? (
            <div className="text-slate-500">Esperando actividad de los agentes...</div>
          ) : (
            eventos.map((evt) => (
              <div key={evt.id} className="flex flex-col gap-1 border-b border-slate-800/50 pb-2 last:border-0 last:pb-0">
                <div className="flex items-center gap-2">
                  <span className="text-slate-500 text-xs">
                    [{new Date(evt.created_at).toLocaleTimeString()}]
                  </span>
                  <Badge variant="outline" className={`font-mono text-xs ${getColorForAgent(evt.agente_ia_nombre)}`}>
                    {evt.agente_ia_nombre.toUpperCase()}
                  </Badge>
                  <span className="text-slate-400 text-xs truncate max-w-[200px]">
                    {evt.tramite_id.split("-")[0]}...
                  </span>
                </div>
                <div className="text-slate-300 pl-4 border-l-2 border-slate-800 ml-1">
                  {evt.descripcion}
                </div>
              </div>
            ))
          )}
        </div>
      </CardContent>
    </Card>
  );
}
