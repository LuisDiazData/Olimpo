import { getSupabaseBrowserClient } from "./supabase"

const API_URL = process.env.NEXT_PUBLIC_API_URL ?? "http://localhost:8000"

export class ApiError extends Error {
  constructor(
    public status: number,
    public errorCode: string | undefined,
    message: string
  ) {
    super(message)
    this.name = "ApiError"
  }
}

async function getAccessToken(): Promise<string> {
  try {
    const supabase = getSupabaseBrowserClient()
    const { data: { session } } = await supabase.auth.getSession()
    return session?.access_token ?? ""
  } catch {
    return ""
  }
}

async function proxyRequest<T>(
  subPath: string,
  options: { method: string; body?: unknown }
): Promise<T> {
  const token = await getAccessToken()
  const res = await fetch("/api/fwd", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      ...(token ? { "Authorization": `Bearer ${token}` } : {}),
    },
    body: JSON.stringify({ path: subPath, _method: options.method, _body: options.body }),
  })

  if (!res.ok) {
    let message = "Error"
    try {
      const body = await res.json()
      if (typeof body?.detail === "string") {
        message = body.detail
      } else if (Array.isArray(body?.detail)) {
        message = body.detail.map((e: { msg?: string }) => e.msg || JSON.stringify(e)).join("; ")
      } else if (typeof body?.detail === "object") {
        message = JSON.stringify(body.detail)
      }
    } catch { /* ignore */ }
    throw new ApiError(res.status, undefined, message)
  }

  if (res.status === 204) return undefined as T
  return res.json()
}

export const api = {
  get: <T>(path: string) => proxyRequest<T>(path, { method: "GET" }),
  post: <T>(path: string, body?: unknown) => proxyRequest<T>(path, { method: "POST", body }),
  patch: <T>(path: string, body?: unknown) => proxyRequest<T>(path, { method: "PATCH", body }),
  delete: <T>(path: string) => proxyRequest<T>(path, { method: "DELETE" }),
}