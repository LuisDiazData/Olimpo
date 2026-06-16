"use client";

import { useState } from "react";
import {
  DndContext,
  closestCorners,
  KeyboardSensor,
  PointerSensor,
  useSensor,
  useSensors,
  DragOverlay,
  type DragStartEvent,
  type DragOverEvent,
  type DragEndEvent,
} from "@dnd-kit/core";
import { SortableContext, verticalListSortingStrategy } from "@dnd-kit/sortable";
import { ProspectoCard } from "./prospecto-card";
import { Column } from "./column";
import { api } from "@/lib/api";

export interface Prospecto {
  id: string;
  nombre: string;
  email: string;
  telefono?: string | null;
  origen?: string | null;
  estado: string;
}

interface KanbanBoardProps {
  initialProspectos: Prospecto[];
  onProspectoMoved?: () => void;
}

const ESTADOS = [
  { id: "entrevista", title: "Entrevista" },
  { id: "evaluacion_gnp", title: "Evaluación GNP" },
  { id: "examenes_cnsf", title: "Exámenes CNSF" },
  { id: "certificacion_gnp", title: "Certificación GNP" },
  { id: "aprobado", title: "Aprobado" },
  { id: "rechazado", title: "Rechazado" },
];

export function KanbanBoard({ initialProspectos, onProspectoMoved }: KanbanBoardProps) {
  const [prospectos, setProspectos] = useState<Prospecto[]>(initialProspectos);
  const [activeId, setActiveId] = useState<string | null>(null);

  const sensors = useSensors(
    useSensor(PointerSensor),
    useSensor(KeyboardSensor)
  );

  const handleDragStart = (event: DragStartEvent) => {
    setActiveId(String(event.active.id));
  };

  const handleDragOver = (event: DragOverEvent) => {
    const { active, over } = event;
    if (!over) return;

    const activeId = String(active.id);
    const overId = String(over.id);

    // Si estamos moviendo sobre una columna u otra tarjeta
    const activeItem = prospectos.find(p => p.id === activeId);
    if (!activeItem) return;

    const overItem = prospectos.find(p => p.id === overId);
    const isOverColumn = ESTADOS.some(e => e.id === overId);

    const newStatus = isOverColumn ? overId : overItem?.estado;

    if (newStatus && activeItem.estado !== newStatus) {
      setProspectos(prev =>
        prev.map(p => p.id === activeId ? { ...p, estado: newStatus } : p)
      );
    }
  };

  const handleDragEnd = async (event: DragEndEvent) => {
    setActiveId(null);
    const { active, over } = event;
    if (!over) return;

    const activeItem = prospectos.find(p => p.id === String(active.id));
    const overId = String(over.id);
    const isOverColumn = ESTADOS.some(e => e.id === overId);
    const overItem = prospectos.find(p => p.id === overId);

    const newStatus = isOverColumn ? overId : overItem?.estado;

    if (activeItem && newStatus && activeItem.estado !== newStatus) {
      // Snapshot para revertir si el backend rechaza el cambio.
      const snapshot = prospectos;
      setProspectos(prev =>
        prev.map(p => p.id === activeItem.id ? { ...p, estado: newStatus } : p)
      );
      try {
        await api.patch(`/prospectos/${activeItem.id}/estado`, { estado: newStatus });
        if (onProspectoMoved) onProspectoMoved();
      } catch (error) {
        console.error("Error moving prospecto", error);
        setProspectos(snapshot); // revert
      }
    }
  };

  const activeProspecto = prospectos.find(p => p.id === activeId);

  return (
    <div className="flex h-full w-full gap-4 overflow-x-auto pb-4">
      <DndContext 
        sensors={sensors}
        collisionDetection={closestCorners}
        onDragStart={handleDragStart}
        onDragOver={handleDragOver}
        onDragEnd={handleDragEnd}
      >
        {ESTADOS.map(col => {
          const colProspectos = prospectos.filter(p => p.estado === col.id);
          return (
            <Column key={col.id} id={col.id} title={col.title}>
              <SortableContext items={colProspectos.map(p => p.id)} strategy={verticalListSortingStrategy}>
                {colProspectos.map(p => (
                  <ProspectoCard key={p.id} prospecto={p} />
                ))}
              </SortableContext>
            </Column>
          );
        })}
        
        <DragOverlay>
          {activeProspecto ? <ProspectoCard prospecto={activeProspecto} isOverlay /> : null}
        </DragOverlay>
      </DndContext>
    </div>
  );
}
