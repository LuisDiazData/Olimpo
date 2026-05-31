"use client"

import { createContext, useContext, useState, useEffect } from "react"
import type { User } from "@supabase/supabase-js"

interface Usuario {
  id: string
  email: string
  nombre: string
  rol: string
  ramo: string | null
}

interface UserContextValue {
  user: User | null
  perfil: Usuario | null
  isLoading: boolean
}

interface UserProviderProps {
  children: React.ReactNode
  initialUser?: { id: string; email: string } | null
  initialPerfil?: Usuario | null
}

const UserContext = createContext<UserContextValue>({
  user: null,
  perfil: null,
  isLoading: true,
})

export function UserProvider({ children, initialUser, initialPerfil }: UserProviderProps) {
  const [user, setUser] = useState<User | null>(initialUser as User | null ?? null)
  const [perfil, setPerfil] = useState<Usuario | null>(initialPerfil ?? null)
  // Si ya tenemos datos del server, no mostramos spinner inicial
  const [isLoading, setIsLoading] = useState(!initialPerfil)

  useEffect(() => {
    // Sólo hace la llamada si no tenemos nombre real (initialPerfil viene con nombre placeholder)
    // o si no hay initialPerfil en absoluto. Carga en background sin afectar isLoading.
    async function refresh() {
      try {
        const res = await fetch("/api/auth/me")
        if (res.ok) {
          const data = await res.json()
          setUser(data.user)
          setPerfil(data.perfil)
        }
      } catch {
        // ignorar si falla el refresh
      } finally {
        setIsLoading(false)
      }
    }
    refresh()
  }, [])

  return (
    <UserContext.Provider value={{ user, perfil, isLoading }}>
      {children}
    </UserContext.Provider>
  )
}

export function useUser() {
  return useContext(UserContext)
}
