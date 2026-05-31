import { NextRequest, NextResponse } from "next/server"
import { getSupabaseServer } from "@/lib/supabase/server"

export async function GET(
  req: NextRequest,
  { params }: { params: Promise<{ id: string }> }
) {
  const { id } = await params
  const supabase = await getSupabaseServer()

  const { data, error } = await supabase
    .from("correo")
    .select(`
      id,
      tipo,
      de_email,
      de_nombre,
      asunto,
      fecha_correo,
      estado
    `)
    .in(
      "id",
      (
        await supabase
          .from("correo_tramite")
          .select("correo_id")
          .eq("tramite_id", id)
      ).data?.map((r: { correo_id: string }) => r.correo_id) ?? []
    )
    .order("fecha_correo", { ascending: false })

  if (error) return NextResponse.json({ error: error.message }, { status: 500 })
  return NextResponse.json({ data })
}