"use client"

import { createContext, useContext, useState, useEffect, useCallback } from "react"
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
  refreshPerfil: () => Promise<void>
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
  refreshPerfil: async () => {},
})

export function UserProvider({ children, initialUser, initialPerfil }: UserProviderProps) {
  const [user, setUser] = useState<User | null>(initialUser as User | null ?? null)
  const [perfil, setPerfil] = useState<Usuario | null>(initialPerfil ?? null)
  const [isLoading, setIsLoading] = useState(!initialPerfil)

  const refreshPerfil = useCallback(async () => {
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
  }, [])

  useEffect(() => {
    refreshPerfil()
  }, [refreshPerfil])

  return (
    <UserContext.Provider value={{ user, perfil, isLoading, refreshPerfil }}>
      {children}
    </UserContext.Provider>
  )
}

export function useUser() {
  return useContext(UserContext)
}
