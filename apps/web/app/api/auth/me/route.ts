import { createServerClient, type CookieOptions } from "@supabase/ssr"
import { NextRequest, NextResponse } from "next/server"

export async function GET(request: NextRequest) {
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

  // getSession() es local (sólo lee la cookie), nos da el user ID sin llamada a red.
  // Con ese ID lanzamos getUser() (verificación con Supabase) y la query DB en paralelo.
  const { data: { session } } = await supabase.auth.getSession()
  if (!session?.user) {
    return NextResponse.json({ message: "No autenticado" }, { status: 401 })
  }

  const userId = session.user.id
  const [{ data: { user } }, { data: perfil }] = await Promise.all([
    supabase.auth.getUser(),
    supabase
      .from("usuario")
      .select("id, email, nombre, rol, ramo")
      .eq("id", userId)
      .single(),
  ])

  if (!user) {
    return NextResponse.json({ message: "No autenticado" }, { status: 401 })
  }

  const response = NextResponse.json({
    user: {
      id: user.id,
      email: user.email,
      rol: user.app_metadata?.rol,
    },
    perfil: perfil ?? { id: user.id, email: user.email, nombre: user.email?.split("@")[0] ?? "Usuario", rol: user.app_metadata?.rol ?? "analista", ramo: user.app_metadata?.ramo ?? null },
  })

  pendingCookies.forEach(({ name, value, options }) =>
    response.cookies.set(name, value, options)
  )

  return response
}
