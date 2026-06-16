"use client";

import { useState, useEffect } from "react";
import { KanbanBoard } from "@/components/kanban/kanban-board";
import { CrearProspectoDialog } from "@/components/modals/crear-prospecto-dialog";
import { api } from "@/lib/api";
import type { Prospecto } from "@/components/kanban/kanban-board";

export default function ReclutamientoPage() {
  const [prospectos, setProspectos] = useState<Prospecto[]>([]);
  const [loading, setLoading] = useState(true);

  const fetchProspectos = async () => {
    try {
      setLoading(true);
      setProspectos(await api.get<Prospecto[]>("/prospectos"));
    } catch (error) {
      console.error("Error fetching prospectos", error);
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    fetchProspectos();
  }, []);

  return (
    <div className="flex-1 space-y-4 p-8 pt-6">
      <div className="flex items-center justify-between space-y-2">
        <h2 className="text-3xl font-bold tracking-tight">CRM Reclutamiento</h2>
        <div className="flex items-center space-x-2">
          <CrearProspectoDialog onCreated={fetchProspectos} />
        </div>
      </div>
      {loading ? (
        <div>Cargando tablero...</div>
      ) : (
        <KanbanBoard initialProspectos={prospectos} onProspectoMoved={fetchProspectos} />
      )}
    </div>
  );
}
