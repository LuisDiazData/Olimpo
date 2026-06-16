"use client";

import { useState } from "react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { api } from "@/lib/api";

interface CrearProspectoDialogProps {
  onCreated?: () => void;
}

export function CrearProspectoDialog({ onCreated }: CrearProspectoDialogProps) {
  const [open, setOpen] = useState(false);
  const [formData, setFormData] = useState({
    nombre: "",
    email: "",
    telefono: "",
    origen: ""
  });
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setLoading(true);
    setError(null);
    try {
      await api.post("/prospectos", formData);
      setOpen(false);
      setFormData({ nombre: "", email: "", telefono: "", origen: "" });
      if (onCreated) onCreated();
    } catch (err) {
      setError(err instanceof Error ? err.message : "No se pudo crear el prospecto");
    } finally {
      setLoading(false);
    }
  };

  return (
    <>
      <Button onClick={() => setOpen(true)}>Nuevo Prospecto</Button>
      {open && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 p-4">
          <div className="w-full max-w-md rounded-lg bg-white p-6 shadow-xl">
            <div className="mb-4 flex items-center justify-between">
              <h3 className="text-lg font-semibold">Añadir Prospecto (Lead)</h3>
              <button
                type="button"
                onClick={() => setOpen(false)}
                className="text-slate-400 hover:text-slate-600"
                aria-label="Cerrar"
              >
                ✕
              </button>
            </div>
            <form onSubmit={handleSubmit} className="space-y-4">
              <div className="space-y-2">
                <Label htmlFor="nombre">Nombre Completo</Label>
                <Input
                  id="nombre"
                  value={formData.nombre}
                  onChange={e => setFormData(p => ({ ...p, nombre: e.target.value }))}
                  required
                />
              </div>
              <div className="space-y-2">
                <Label htmlFor="email">Correo Electrónico</Label>
                <Input
                  id="email"
                  type="email"
                  value={formData.email}
                  onChange={e => setFormData(p => ({ ...p, email: e.target.value }))}
                  required
                />
              </div>
              <div className="space-y-2">
                <Label htmlFor="telefono">Teléfono (Opcional)</Label>
                <Input
                  id="telefono"
                  value={formData.telefono}
                  onChange={e => setFormData(p => ({ ...p, telefono: e.target.value }))}
                />
              </div>
              <div className="space-y-2">
                <Label htmlFor="origen">Origen (Ej. LinkedIn, Referido)</Label>
                <Input
                  id="origen"
                  value={formData.origen}
                  onChange={e => setFormData(p => ({ ...p, origen: e.target.value }))}
                />
              </div>
              {error && <p className="text-sm text-red-600">{error}</p>}
              <div className="flex justify-end pt-4">
                <Button type="submit" disabled={loading}>
                  {loading ? "Guardando..." : "Guardar Prospecto"}
                </Button>
              </div>
            </form>
          </div>
        </div>
      )}
    </>
  );
}
