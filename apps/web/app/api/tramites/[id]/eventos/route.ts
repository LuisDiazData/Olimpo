import { NextRequest, NextResponse } from "next/server"
import { getSupabaseServer } from "@/lib/supabase/server"

export async function GET(
  req: NextRequest,
  { params }: { params: Promise<{ id: string }> }
) {
  const { id } = await params
  const supabase = await getSupabaseServer()

  const { data, error } = await supabase
    .from("tramite_evento")
    .select(`
      id,
      tipo_evento,
      descripcion,
      agente_ia_nombre,
      created_at,
      estado_anterior,
      estado_nuevo,
      usuario:usuario_id ( nombre )
    `)
    .eq("tramite_id", id)
    .order("created_at", { ascending: true })

  if (error) return NextResponse.json({ error: error.message }, { status: 500 })
  return NextResponse.json({ data })
}