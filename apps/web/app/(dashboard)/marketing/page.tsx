"use client";

import { useEffect, useState } from "react";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { NuevaCampanaDialog } from "@/components/modals/nueva-campana-dialog";
import { api } from "@/lib/api";

interface Campana {
  id: string;
  titulo: string;
  asunto: string;
  estado: string;
  created_at: string;
}

export default function MarketingPage() {
  const [campanas, setCampanas] = useState<Campana[]>([]);
  const [loading, setLoading] = useState(true);

  const fetchCampanas = async () => {
    try {
      setLoading(true);
      setCampanas(await api.get<Campana[]>("/campanas"));
    } catch (error) {
      console.error(error);
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    fetchCampanas();
  }, []);

  const enviarCampana = async (id: string) => {
    try {
      await api.post(`/campanas/${id}/enviar`);
      fetchCampanas();
    } catch (e) {
      console.error(e);
    }
  };

  return (
    <div className="flex-1 space-y-4 p-8 pt-6">
      <div className="flex items-center justify-between space-y-2">
        <h2 className="text-3xl font-bold tracking-tight">Marketing & Comunicados</h2>
        <div className="flex items-center space-x-2">
          <NuevaCampanaDialog onCreated={fetchCampanas} />
        </div>
      </div>

      <Card>
        <CardHeader>
          <CardTitle>Historial de Campañas</CardTitle>
        </CardHeader>
        <CardContent>
          <table className="w-full text-sm">
            <thead>
              <tr className="border-b text-left text-muted-foreground">
                <th className="py-2 font-medium">Título</th>
                <th className="py-2 font-medium">Asunto</th>
                <th className="py-2 font-medium">Estado</th>
                <th className="py-2 font-medium">Creación</th>
                <th className="py-2 text-right font-medium">Acciones</th>
              </tr>
            </thead>
            <tbody>
              {loading ? (
                <tr><td colSpan={5} className="py-3">Cargando...</td></tr>
              ) : campanas.length === 0 ? (
                <tr><td colSpan={5} className="py-3">No hay campañas registradas.</td></tr>
              ) : (
                campanas.map(c => (
                  <tr key={c.id} className="border-b last:border-0">
                    <td className="py-2 font-medium">{c.titulo}</td>
                    <td className="py-2">{c.asunto}</td>
                    <td className="py-2">
                      <span className={`px-2 py-1 rounded-full text-xs font-semibold ${
                        c.estado === 'completada' ? 'bg-green-100 text-green-800' :
                        c.estado === 'enviando' ? 'bg-yellow-100 text-yellow-800' :
                        'bg-gray-100 text-gray-800'
                      }`}>
                        {(c.estado || "").toUpperCase()}
                      </span>
                    </td>
                    <td className="py-2">{new Date(c.created_at).toLocaleDateString()}</td>
                    <td className="py-2 text-right">
                      {c.estado === "borrador" && (
                        <Button size="sm" onClick={() => enviarCampana(c.id)}>Enviar Ahora</Button>
                      )}
                      {c.estado === "completada" && (
                        <Button size="sm" variant="outline" disabled>Enviado</Button>
                      )}
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
