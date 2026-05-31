import type { Metadata } from "next"
import "./globals.css"
import { QueryProvider } from "@/components/providers/query-provider"

export const metadata: Metadata = {
  title: "Olimpo — Panel Superadmin",
  description: "Gestión de licencias y promotorías",
}

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="es">
      <body>
        <QueryProvider>{children}</QueryProvider>
      </body>
    </html>
  )
}
