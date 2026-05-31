import { NextRequest, NextResponse } from "next/server"
import { getSupabaseServer } from "@/lib/supabase/server"

export async function GET(
  req: NextRequest,
  { params }: { params: Promise<{ id: string }> }
) {
  const { id } = await params
  const supabase = await getSupabaseServer()

  const { data, error } = await supabase
    .from("documento")
    .select(`
      id,
      tipo_documento,
      estado_validacion,
      confianza_ocr,
      adjunto:adjunto_id (
        nombre_archivo
      )
    `)
    .eq("tramite_id", id)
    .order("created_at", { ascending: false })

  if (error) return NextResponse.json({ error: error.message }, { status: 500 })

  const formatted = (data ?? []).map((d: Record<string, unknown>) => ({
    id: d.id,
    tipo_documento: d.tipo_documento,
    estado_validacion: d.estado_validacion,
    confianza_ocr: d.confianza_ocr,
    nombre_archivo: (d.adjunto as Record<string, unknown> | null)?.nombre_archivo ?? "Documento sin nombre",
  }))

  return NextResponse.json({ data: formatted })
}