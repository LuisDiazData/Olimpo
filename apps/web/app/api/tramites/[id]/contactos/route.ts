import { NextRequest, NextResponse } from "next/server"
import { getSupabaseServer } from "@/lib/supabase/server"

export async function GET(
  req: NextRequest,
  { params }: { params: Promise<{ id: string }> }
) {
  const { id } = await params
  const supabase = await getSupabaseServer()

  const { data: tramite, error: tramiteError } = await supabase
    .from("tramite")
    .select("agente_id, asistente_id, analista_id, gerente_id")
    .eq("id", id)
    .single()

  if (tramiteError || !tramite) return NextResponse.json({ error: tramiteError?.message }, { status: 500 })

  type Contacto = {
    id: string
    nombre: string | null
    email: string | null
    telefono: string | null
    rol: string
  }

  const contactos: Contacto[] = []

  if (tramite.agente_id) {
    const { data: agente } = await supabase
      .from("agente")
      .select("id, nombre, email, telefono")
      .eq("id", tramite.agente_id)
      .single()
    if (agente) {
      contactos.push({
        id: agente.id,
        nombre: agente.nombre,
        email: agente.email ?? null,
        telefono: agente.telefono ?? null,
        rol: "agente",
      })
    }
  }

  if (tramite.asistente_id) {
    const { data: asistente } = await supabase
      .from("asistente")
      .select("id, nombre, email, telefono")
      .eq("id", tramite.asistente_id)
      .single()
    if (asistente) {
      contactos.push({
        id: asistente.id,
        nombre: asistente.nombre,
        email: asistente.email ?? null,
        telefono: asistente.telefono ?? null,
        rol: "asistente",
      })
    }
  }

  if (tramite.analista_id) {
    const { data: analista } = await supabase
      .from("usuario")
      .select("id, nombre, email, telefono")
      .eq("id", tramite.analista_id)
      .single()
    if (analista) {
      contactos.push({
        id: analista.id,
        nombre: analista.nombre,
        email: analista.email ?? null,
        telefono: null,
        rol: "analista",
      })
    }
  }

  if (tramite.gerente_id) {
    const { data: gerente } = await supabase
      .from("usuario")
      .select("id, nombre, email, telefono")
      .eq("id", tramite.gerente_id)
      .single()
    if (gerente) {
      contactos.push({
        id: gerente.id,
        nombre: gerente.nombre,
        email: gerente.email ?? null,
        telefono: null,
        rol: "gerente",
      })
    }
  }

  return NextResponse.json({ data: contactos })
}