"use client";

import { useSortable } from "@dnd-kit/sortable";
import { CSS } from "@dnd-kit/utilities";
import { UserCircle, Mail, Phone } from "lucide-react";
import type { Prospecto } from "./kanban-board";

interface ProspectoCardProps {
  prospecto: Prospecto;
  isOverlay?: boolean;
}

export function ProspectoCard({ prospecto, isOverlay = false }: ProspectoCardProps) {
  const {
    setNodeRef,
    attributes,
    listeners,
    transform,
    transition,
    isDragging,
  } = useSortable({
    id: prospecto.id,
    data: {
      type: "Prospecto",
      prospecto,
    },
  });

  const style = {
    transition,
    transform: CSS.Transform.toString(transform),
  };

  if (isDragging && !isOverlay) {
    return (
      <div 
        ref={setNodeRef}
        style={style}
        className="flex min-h-[100px] flex-col rounded-lg border-2 border-dashed border-primary bg-primary/10 p-4 opacity-50"
      />
    );
  }

  return (
    <div
      ref={setNodeRef}
      style={style}
      {...attributes}
      {...listeners}
      className={`flex cursor-grab flex-col gap-3 rounded-lg border bg-card p-4 text-card-foreground shadow-sm active:cursor-grabbing ${
        isOverlay ? "rotate-2 scale-105 shadow-xl ring-2 ring-primary" : ""
      }`}
    >
      <div className="flex items-start justify-between">
        <div className="flex items-center gap-2">
          <UserCircle className="h-5 w-5 text-muted-foreground" />
          <span className="font-semibold">{prospecto.nombre}</span>
        </div>
      </div>
      
      <div className="flex flex-col gap-1 text-xs text-muted-foreground">
        <div className="flex items-center gap-2">
          <Mail className="h-3 w-3" />
          <span className="truncate">{prospecto.email}</span>
        </div>
        {prospecto.telefono && (
          <div className="flex items-center gap-2">
            <Phone className="h-3 w-3" />
            <span>{prospecto.telefono}</span>
          </div>
        )}
      </div>
      
      {prospecto.origen && (
        <div className="mt-2 flex">
          <span className="inline-flex items-center rounded-full bg-secondary px-2.5 py-0.5 text-xs font-semibold text-secondary-foreground">
            {prospecto.origen}
          </span>
        </div>
      )}
    </div>
  );
}
