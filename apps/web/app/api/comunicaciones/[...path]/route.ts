import { NextRequest, NextResponse } from "next/server"

const API_URL = process.env.NEXT_PUBLIC_API_URL ?? "http://localhost:8000"

async function proxy(request: NextRequest, { params }: { params: Promise<{ path: string[] }> }) {
  const { path } = await params
  const apiPath = path.join("/")
  const url = new URL(request.url)

  const upstreamRes = await fetch(`${API_URL}/api/v1/${apiPath}${url.search}`, {
    method: request.method,
    headers: {
      "Content-Type": "application/json",
      cookie: request.headers.get("cookie") ?? "",
    },
    body: request.method !== "GET" && request.method !== "HEAD" ? await request.text() : undefined,
    credentials: "include",
  })

  const body = await upstreamRes.text()
  return new NextResponse(body, {
    status: upstreamRes.status,
    headers: { "Content-Type": "application/json" },
  })
}

export const GET = proxy
export const POST = proxy
export const PATCH = proxy
export const DELETE = proxy
