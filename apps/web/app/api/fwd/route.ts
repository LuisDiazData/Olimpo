import { createServerClient, type CookieOptions } from "@supabase/ssr"
import { NextRequest, NextResponse } from "next/server"

const API_URL = process.env.NEXT_PUBLIC_API_URL ?? "http://localhost:8000"

export async function POST(request: NextRequest) {
  const body = await request.json().catch(() => ({}))
  const path: string = body.path ?? ""
  const method: string = body._method ?? "POST"
  const data = body._body
  const pendingCookies: { name: string; value: string; options: CookieOptions }[] = []

  // Preferir el token que viene directamente del cliente (más confiable).
  // El browser Supabase client maneja el refresh automáticamente.
  const clientAuth = request.headers.get("authorization") ?? ""
  let token = clientAuth.startsWith("Bearer ") ? clientAuth.slice(7) : ""

  // Fallback: leer sesión desde cookies server-side
  if (!token) {
    const supabase = createServerClient(
      process.env.NEXT_PUBLIC_SUPABASE_URL!,
      process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
      {
        cookies: {
          getAll: () => request.cookies.getAll(),
          setAll: (cookies: { name: string; value: string; options: CookieOptions }[]) => pendingCookies.push(...cookies),
        },
      }
    )
    const { data: { session } } = await supabase.auth.getSession()
    token = session?.access_token ?? ""
  }

  let upstreamPath: string
  if (path === "health") {
    upstreamPath = "/health"
  } else if (path.startsWith("/")) {
    upstreamPath = `/api/v1${path}`
  } else {
    upstreamPath = `/api/v1/${path}`
  }
  const url = `${API_URL}${upstreamPath}`

  const response = await fetch(url, {
    method,
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${token}`,
    },
    body: method !== "GET" ? JSON.stringify(data) : undefined,
  })

  const respBody = await response.json().catch(() => null)
  let result = NextResponse.json(respBody ?? { detail: "No content" }, { status: response.status })

  pendingCookies.forEach(({ name, value, options }) =>
    result.cookies.set(name, value, options)
  )

  return result
}