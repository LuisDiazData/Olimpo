"use client";

import { useState } from "react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { api } from "@/lib/api";

interface NuevaCampanaDialogProps {
  onCreated?: () => void;
}

export function NuevaCampanaDialog({ onCreated }: NuevaCampanaDialogProps) {
  const [open, setOpen] = useState(false);
  const [formData, setFormData] = useState({
    titulo: "",
    asunto: "",
    ramo_objetivo: "todos",
    cuerpo_html: "Hola {nombre},\n\n"
  });
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setLoading(true);
    setError(null);
    try {
      const payload = {
        ...formData,
        ramo_objetivo: formData.ramo_objetivo === "todos" ? null : formData.ramo_objetivo
      };
      await api.post("/campanas", payload);
      setOpen(false);
      setFormData({ titulo: "", asunto: "", ramo_objetivo: "todos", cuerpo_html: "Hola {nombre},\n\n" });
      if (onCreated) onCreated();
    } catch (err) {
      setError(err instanceof Error ? err.message : "No se pudo crear la campaña");
    } finally {
      setLoading(false);
    }
  };

  return (
    <>
      <Button onClick={() => setOpen(true)}>Crear Campaña</Button>
      {open && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 p-4">
          <div className="w-full max-w-2xl rounded-lg bg-white p-6 shadow-xl">
            <div className="mb-4 flex items-center justify-between">
              <h3 className="text-lg font-semibold">Nueva Campaña de Correo</h3>
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
              <div className="grid grid-cols-2 gap-4">
                <div className="space-y-2">
                  <Label htmlFor="titulo">Nombre Interno</Label>
                  <Input
                    id="titulo"
                    value={formData.titulo}
                    onChange={e => setFormData(p => ({ ...p, titulo: e.target.value }))}
                    required
                    placeholder="Ej. Promo Autos Enero"
                  />
                </div>
                <div className="space-y-2">
                  <Label htmlFor="ramo">Ramo Objetivo</Label>
                  <select
                    id="ramo"
                    value={formData.ramo_objetivo}
                    onChange={e => setFormData(p => ({ ...p, ramo_objetivo: e.target.value }))}
                    className="flex h-10 w-full rounded-md border border-slate-200 bg-white px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-slate-400"
                  >
                    <option value="todos">Todos los agentes</option>
                    <option value="autos">Autos</option>
                    <option value="gmm">Gastos Médicos Mayores</option>
                    <option value="vida">Vida</option>
                    <option value="pyme">PyME</option>
                  </select>
                </div>
              </div>

              <div className="space-y-2">
                <Label htmlFor="asunto">Asunto del Correo</Label>
                <Input
                  id="asunto"
                  value={formData.asunto}
                  onChange={e => setFormData(p => ({ ...p, asunto: e.target.value }))}
                  required
                />
              </div>

              <div className="space-y-2">
                <Label htmlFor="cuerpo">Cuerpo del Correo (HTML soportado)</Label>
                <textarea
                  id="cuerpo"
                  rows={8}
                  value={formData.cuerpo_html}
                  onChange={e => setFormData(p => ({ ...p, cuerpo_html: e.target.value }))}
                  required
                  className="flex w-full rounded-md border border-slate-200 bg-white px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-slate-400"
                />
                <p className="text-xs text-muted-foreground">Tip: Usa <code>{`{nombre}`}</code> para personalizar el correo con el nombre del agente.</p>
              </div>

              {error && <p className="text-sm text-red-600">{error}</p>}

              <div className="flex justify-end pt-4">
                <Button type="submit" disabled={loading}>
                  {loading ? "Guardando..." : "Guardar Borrador"}
                </Button>
              </div>
            </form>
          </div>
        </div>
      )}
    </>
  );
}
