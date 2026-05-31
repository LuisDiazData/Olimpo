import { cookies } from "next/headers"
import { NextRequest, NextResponse } from "next/server"

const ADMIN_API_URL = process.env.ADMIN_API_URL ?? "http://localhost:8001"

export async function POST(request: NextRequest) {
  const { api_key } = await request.json()

  if (!api_key) {
    return NextResponse.json({ error: "API key requerida" }, { status: 400 })
  }

  // Valida la key contra la variable de entorno — no consulta la DB
  // (el Supabase del admin podría estar caído, pero el admin sigue pudiendo hacer login)
  const check = await fetch(`${ADMIN_API_URL}/api/v1/auth/verify`, {
    method: "POST",
    headers: { "X-Admin-API-Key": api_key },
  }).catch(() => null)

  if (!check || check.status === 401 || check.status === 403) {
    return NextResponse.json({ error: "API key inválida" }, { status: 401 })
  }

  const cookieStore = await cookies()
  cookieStore.set("admin_session", api_key, {
    httpOnly: true,
    sameSite: "strict",
    secure: process.env.NODE_ENV === "production",
    maxAge: 60 * 60 * 24 * 30, // 30 días
    path: "/",
  })

  return NextResponse.json({ ok: true })
}
