import { createServerClient, type CookieOptions } from "@supabase/ssr"
import { NextRequest, NextResponse } from "next/server"

export async function POST(request: NextRequest) {
  const { email, password } = await request.json()

  if (!email || !password) {
    return NextResponse.json(
      { message: "Email y contraseña son requeridos." },
      { status: 400 }
    )
  }

  const pendingCookies: { name: string; value: string; options: CookieOptions }[] = []

  const supabase = createServerClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    {
      cookies: {
        getAll: () => request.cookies.getAll(),
        setAll: (cookies: { name: string; value: string; options: CookieOptions }[]) =>
          pendingCookies.push(...cookies),
      },
    }
  )

  const { data, error } = await supabase.auth.signInWithPassword({ email, password })

  let response: NextResponse

  if (error) {
    const isBanned =
      error.message.includes("banned") ||
      error.message.includes("blocked") ||
      error.message.includes("disabled")

    response = NextResponse.json(
      { message: error.message, banned: isBanned },
      { status: 401 }
    )
  } else if (!data.session) {
    response = NextResponse.json(
      { message: "No se pudo iniciar sesión. Intenta de nuevo." },
      { status: 401 }
    )
  } else {
    response = NextResponse.json({
      ok: true,
      user: {
        id: data.user.id,
        email: data.user.email,
        role: data.user.app_metadata?.rol,
      },
    })
  }

  pendingCookies.forEach(({ name, value, options }) =>
    response.cookies.set(name, value, options)
  )

  return response
}
