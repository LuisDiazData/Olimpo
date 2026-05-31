import { cookies } from "next/headers"
import { NextRequest, NextResponse } from "next/server"

const ADMIN_API_URL = process.env.ADMIN_API_URL ?? "http://localhost:8001"

async function handler(request: NextRequest, { params }: { params: Promise<{ path: string[] }> }) {
  const { path } = await params
  const apiPath = path.join("/")
  const url = new URL(request.url)
  const targetUrl = `${ADMIN_API_URL}/api/v1/${apiPath}${url.search}`

  const cookieStore = await cookies()
  const apiKey = cookieStore.get("admin_session")?.value

  if (!apiKey) {
    return NextResponse.json({ detail: "No autorizado" }, { status: 401 })
  }

  const headers: HeadersInit = {
    "X-Admin-API-Key": apiKey,
    "Content-Type": "application/json",
  }

  let body: string | undefined
  if (request.method !== "GET" && request.method !== "HEAD") {
    body = await request.text()
  }

  const upstream = await fetch(targetUrl, {
    method: request.method,
    headers,
    body: body || undefined,
  })

  const responseBody = await upstream.text()

  return new NextResponse(responseBody, {
    status: upstream.status,
    headers: { "Content-Type": upstream.headers.get("Content-Type") ?? "application/json" },
  })
}

export const GET = handler
export const POST = handler
export const PUT = handler
export const PATCH = handler
export const DELETE = handler
