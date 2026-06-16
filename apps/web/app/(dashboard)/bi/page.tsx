"use client";

import { useEffect, useState } from "react";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Bar, BarChart, ResponsiveContainer, XAxis, YAxis, Tooltip } from "recharts";
import { DollarSign, Percent, TrendingUp } from "lucide-react";
import { api } from "@/lib/api";

interface TotalMoneda {
  moneda: string;
  prima_neta_total: number;
  comision_total: number;
  cantidad_polizas: number;
}
interface TopItem {
  nombre: string;
  total_prima: number;
}
interface BIData {
  totales_por_moneda: TotalMoneda[];
  top_agentes: TopItem[];
  top_analistas: TopItem[];
}

export default function BIDashboardPage() {
  const [data, setData] = useState<BIData>({
    totales_por_moneda: [],
    top_agentes: [],
    top_analistas: []
  });
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    async function fetchData() {
      try {
        setData(await api.get<BIData>("/bi/resumen"));
      } catch (err) {
        console.error(err);
      } finally {
        setLoading(false);
      }
    }
    fetchData();
  }, []);

  if (loading) return <div className="p-8">Cargando métricas...</div>;

  // Tomamos solo MXN para el sumario rápido
  const mxnData = data.totales_por_moneda?.find(m => m.moneda === "MXN") || {
    prima_neta_total: 0,
    comision_total: 0,
    cantidad_polizas: 0
  };

  return (
    <div className="flex-1 space-y-4 p-8 pt-6">
      <div className="flex items-center justify-between space-y-2">
        <h2 className="text-3xl font-bold tracking-tight">BI Comercial</h2>
      </div>

      <div className="grid gap-4 md:grid-cols-2 lg:grid-cols-4">
        <Card>
          <CardHeader className="flex flex-row items-center justify-between space-y-0 pb-2">
            <CardTitle className="text-sm font-medium">Prima Emitida (MXN)</CardTitle>
            <DollarSign className="h-4 w-4 text-muted-foreground" />
          </CardHeader>
          <CardContent>
            <div className="text-2xl font-bold">
              ${Number(mxnData.prima_neta_total).toLocaleString()}
            </div>
            <p className="text-xs text-muted-foreground">
              Mes actual
            </p>
          </CardContent>
        </Card>
        
        <Card>
          <CardHeader className="flex flex-row items-center justify-between space-y-0 pb-2">
            <CardTitle className="text-sm font-medium">Comisiones (MXN)</CardTitle>
            <Percent className="h-4 w-4 text-muted-foreground" />
          </CardHeader>
          <CardContent>
            <div className="text-2xl font-bold">
              ${Number(mxnData.comision_total).toLocaleString()}
            </div>
            <p className="text-xs text-muted-foreground">
              Estimado mes actual
            </p>
          </CardContent>
        </Card>

        <Card>
          <CardHeader className="flex flex-row items-center justify-between space-y-0 pb-2">
            <CardTitle className="text-sm font-medium">Pólizas Cerradas</CardTitle>
            <TrendingUp className="h-4 w-4 text-muted-foreground" />
          </CardHeader>
          <CardContent>
            <div className="text-2xl font-bold">
              {mxnData.cantidad_polizas}
            </div>
            <p className="text-xs text-muted-foreground">
              Pólizas activas (MXN)
            </p>
          </CardContent>
        </Card>
      </div>

      <div className="grid gap-4 md:grid-cols-2 lg:grid-cols-7">
        <Card className="col-span-4">
          <CardHeader>
            <CardTitle>Top Agentes por Prima (MXN)</CardTitle>
          </CardHeader>
          <CardContent className="pl-2">
            <ResponsiveContainer width="100%" height={350}>
              <BarChart data={data.top_agentes}>
                <XAxis dataKey="nombre" stroke="#888888" fontSize={12} tickLine={false} axisLine={false} />
                <YAxis stroke="#888888" fontSize={12} tickLine={false} axisLine={false} tickFormatter={(value) => `$${value}`} />
                <Tooltip cursor={{fill: 'transparent'}} />
                <Bar dataKey="total_prima" fill="currentColor" radius={[4, 4, 0, 0]} className="fill-primary" />
              </BarChart>
            </ResponsiveContainer>
          </CardContent>
        </Card>

        <Card className="col-span-3">
          <CardHeader>
            <CardTitle>Top Analistas por Prima</CardTitle>
          </CardHeader>
          <CardContent>
            <ResponsiveContainer width="100%" height={350}>
              <BarChart data={data.top_analistas} layout="vertical">
                <XAxis type="number" stroke="#888888" fontSize={12} tickLine={false} axisLine={false} tickFormatter={(value) => `$${value}`}/>
                <YAxis dataKey="nombre" type="category" stroke="#888888" fontSize={12} tickLine={false} axisLine={false} width={100} />
                <Tooltip cursor={{fill: 'transparent'}} />
                <Bar dataKey="total_prima" fill="currentColor" radius={[0, 4, 4, 0]} className="fill-secondary" />
              </BarChart>
            </ResponsiveContainer>
          </CardContent>
        </Card>
      </div>
    </div>
  );
}
