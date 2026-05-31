"use client"

// Todos los llamados van al proxy local /api/proxy/* para que la API key
// nunca salga al navegador.

const PROXY = "/api/proxy"

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

async function request<T>(
  path: string,
  init: RequestInit = {}
): Promise<T> {
  const res = await fetch(`${PROXY}${path}`, {
    ...init,
    headers: {
      "Content-Type": "application/json",
      ...init.headers,
    },
  })

  if (res.status === 401 || res.status === 403) {
    window.location.href = "/login"
    throw new ApiError(res.status, "NO_AUTORIZADO", "Sesión expirada")
  }

  if (!res.ok) {
    const body = await res.json().catch(() => ({}))
    const detail = body?.detail ?? {}
    let errorCode: string | undefined
    let message: string
    if (Array.isArray(detail)) {
      // Errores de validación Pydantic: detail es un array
      message = detail.map((e: { msg?: string }) => e.msg ?? "Error de validación").join("; ")
    } else if (typeof detail === "object") {
      errorCode = detail.error_code
      message = detail.mensaje ?? "Error del servidor"
    } else {
      message = String(detail) || "Error del servidor"
    }
    throw new ApiError(res.status, errorCode, message)
  }

  if (res.status === 204) return undefined as T
  return res.json()
}

export const api = {
  get: <T>(path: string) => request<T>(path, { method: "GET" }),
  post: <T>(path: string, body?: unknown) =>
    request<T>(path, { method: "POST", body: body ? JSON.stringify(body) : undefined }),
  put: <T>(path: string, body?: unknown) =>
    request<T>(path, { method: "PUT", body: body ? JSON.stringify(body) : undefined }),
  delete: <T>(path: string) => request<T>(path, { method: "DELETE" }),
}
