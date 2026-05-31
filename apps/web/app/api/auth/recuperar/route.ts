import { createServerClient, type CookieOptions } from "@supabase/ssr"
import { NextRequest, NextResponse } from "next/server"

export async function POST(request: NextRequest) {
  const { email } = await request.json()

  if (!email || typeof email !== "string") {
    return NextResponse.json({ message: "Email requerido." }, { status: 400 })
  }

  const supabase = createServerClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    {
      cookies: {
        getAll: () => request.cookies.getAll(),
        setAll: (_cookies: { name: string; value: string; options: CookieOptions }[]) => {},
      },
    }
  )

  const siteUrl = process.env.NEXT_PUBLIC_SITE_URL ?? "http://localhost:3000"
  const redirectTo = `${siteUrl}/api/auth/callback?next=/restablecer-contrasena`

  // No revelar si el email existe o no — siempre responder 200
  await supabase.auth.resetPasswordForEmail(email.trim().toLowerCase(), { redirectTo })

  return NextResponse.json({ ok: true })
}
