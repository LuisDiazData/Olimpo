import { NextRequest, NextResponse } from "next/server"
import { getSupabaseServer } from "@/lib/supabase/server"

export async function GET(req: NextRequest) {
  const tramiteId = req.nextUrl.searchParams.get("tramite_id")
  const agenteId = req.nextUrl.searchParams.get("agente_id")

  if (!tramiteId && !agenteId) {
    return NextResponse.json({ error: "Se requiere tramite_id o agente_id" }, { status: 400 })
  }

  const supabase = await getSupabaseServer()

  let query = supabase
    .from("comunicacion")
    .select(`
      id, medio, nota, comunicacion_entrante, requiere_seguimiento,
      created_at, updated_at,
      tramite_id, agente_id,
      usuario:usuario_id ( nombre )
    `)
    .eq("eliminado", false)
    .order("created_at", { ascending: false })

  if (tramiteId) query = query.eq("tramite_id", tramiteId)
  if (agenteId) query = query.eq("agente_id", agenteId)

  const { data, error } = await query

  if (error) return NextResponse.json({ error: error.message }, { status: 500 })

  const formatted = (data ?? []).map((row: Record<string, unknown>) => {
    const usuario = row.usuario as Record<string, string> | null
    return {
      ...row,
      usuario: undefined,
      usuario_nombre: usuario?.nombre ?? null,
    }
  })

  return NextResponse.json({ data: formatted })
}

export async function POST(req: NextRequest) {
  const API_URL = process.env.NEXT_PUBLIC_API_URL ?? "http://localhost:8000"
  const body = await req.text()
  const res = await fetch(`${API_URL}/comunicaciones`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      cookie: req.headers.get("cookie") ?? "",
    },
    body,
  })
  const text = await res.text()
  return new NextResponse(text, {
    status: res.status,
    headers: { "Content-Type": "application/json" },
  })
}
