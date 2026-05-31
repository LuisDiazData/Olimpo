import type { Metadata } from "next"
import "./globals.css"
import { QueryProvider } from "@/components/providers/query-provider"
import { CommandPaletteProvider } from "@/components/providers/command-palette-provider"
import { UserProvider } from "@/components/providers/user-provider"
import { CommandPaletteWrapper } from "@/components/command-palette-wrapper"
import { getSupabaseServer } from "@/lib/supabase/server"

export const metadata: Metadata = {
  title: "Olimpo CRM",
  description: "CRM con IA para promotórias de seguros",
  icons: {
    icon: "/favicon.ico",
  },
}

export default async function RootLayout({
  children,
}: {
  children: React.ReactNode
}) {
  // Leer la sesión server-side (sólo decodifica la cookie, sin llamada a red).
  // Esto alimenta el UserProvider con datos iniciales para que el nav del director
  // renderice con los ítems correctos desde el primer paint, sin flicker de carga.
  let initialUser: { id: string; email: string } | null = null
  let initialPerfil: { id: string; email: string; nombre: string; rol: string; ramo: string | null } | null = null

  try {
    const supabase = await getSupabaseServer()
    const { data: { session } } = await supabase.auth.getSession()
    if (session?.user) {
      const u = session.user
      initialUser = { id: u.id, email: u.email ?? "" }
      initialPerfil = {
        id: u.id,
        email: u.email ?? "",
        // El nombre real se carga en background por UserProvider vía /api/auth/me.
        // Usamos email como placeholder para que no quede vacío.
        nombre: u.email?.split("@")[0] ?? "Usuario",
        rol: (u.app_metadata?.rol as string) ?? "analista",
        ramo: (u.app_metadata?.ramo as string | null) ?? null,
      }
    }
  } catch {
    // Sin sesión o error — UserProvider arranca sin datos y los carga normalmente
  }

  return (
    <html lang="es">
      <body className="min-h-screen bg-slate-50 antialiased">
        <UserProvider initialUser={initialUser} initialPerfil={initialPerfil}>
          <QueryProvider>
            <CommandPaletteProvider>
              {children}
              <CommandPaletteWrapper />
            </CommandPaletteProvider>
          </QueryProvider>
        </UserProvider>
      </body>
    </html>
  )
}