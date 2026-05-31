import { createServerClient, type CookieOptions } from "@supabase/ssr"
import { NextRequest, NextResponse } from "next/server"

export async function GET(request: NextRequest) {
  const { searchParams, origin } = new URL(request.url)
  const code = searchParams.get("code")
  const supabaseError = searchParams.get("error")
  const next = searchParams.get("next") ?? "/"

  if (supabaseError) {
    return NextResponse.redirect(new URL("/login?error=enlace_expirado", origin))
  }

  if (!code) {
    return NextResponse.redirect(new URL("/login?error=enlace_invalido", origin))
  }

  const pendingCookies: { name: string; value: string; options: CookieOptions }[] = []

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

  const { error } = await supabase.auth.exchangeCodeForSession(code)

  if (error) {
    return NextResponse.redirect(new URL("/login?error=enlace_expirado", origin))
  }

  const response = NextResponse.redirect(new URL(next, origin))
  pendingCookies.forEach(({ name, value, options }) =>
    response.cookies.set(name, value, options)
  )

  return response
}
