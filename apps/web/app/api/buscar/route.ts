import { NextRequest, NextResponse } from "next/server"

const API_URL = process.env.NEXT_PUBLIC_API_URL ?? "http://localhost:8000"

export async function GET(request: NextRequest) {
  const { searchParams } = new URL(request.url)
  const q = searchParams.get("q") ?? ""
  const tipo = searchParams.get("tipo") ?? "all"

  if (!q.trim()) {
    return NextResponse.json([])
  }

  try {
    let path: string

    if (tipo === "tramite") {
      // Búsqueda de trámites por folio o título
      path = `/tramites?q=${encodeURIComponent(q)}&limit=5`
    } else if (tipo === "agente") {
      // Búsqueda de agentes por nombre o CUA
      path = `/agentes?q=${encodeURIComponent(q)}&limit=5`
    } else {
      // Ambos
      const [tramites, agentes] = await Promise.all([
        fetch(`${API_URL}/api/v1/tramites?q=${encodeURIComponent(q)}&limit=5`),
        fetch(`${API_URL}/api/v1/agentes?q=${encodeURIComponent(q)}&limit=5`),
      ])
      const [t, a] = await Promise.all([tramites.json(), agentes.json()])
      return NextResponse.json({ tramites: t, agentes: a })
    }

    const res = await fetch(`${API_URL}/api/v1${path}`)

    if (!res.ok) {
      return NextResponse.json({ error: "Error upstream" }, { status: 502 })
    }

    const data = await res.json()
    return NextResponse.json(data)
  } catch {
    return NextResponse.json({ error: "Error interno" }, { status: 500 })
  }
}
