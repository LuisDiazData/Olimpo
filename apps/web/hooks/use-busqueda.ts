"use client"

import { useState, useEffect, useCallback, useRef } from "react"

export interface TramiteSearchItem {
  type: "tramite"
  id: string
  folio: string
  titulo: string
  estado: string
  agente_nombre: string | null
  ramo: string | null
}

export interface AgenteSearchItem {
  type: "agente"
  id: string
  nombre: string
  cua: string | null
}

export type SearchItem = TramiteSearchItem | AgenteSearchItem

interface SearchResults {
  tramites: TramiteSearchItem[]
  agentes: AgenteSearchItem[]
  isLoading: boolean
  error: string | null
}

export function useBusqueda() {
  const [query, setQuery] = useState("")
  const [results, setResults] = useState<SearchResults>({
    tramites: [],
    agentes: [],
    isLoading: false,
    error: null,
  })
  const abortRef = useRef<AbortController | null>(null)

  const search = useCallback(async (q: string) => {
    if (!q.trim()) {
      setResults({ tramites: [], agentes: [], isLoading: false, error: null })
      return
    }

    if (abortRef.current) {
      abortRef.current.abort()
    }
    const controller = new AbortController()
    abortRef.current = controller

    setResults((prev) => ({ ...prev, isLoading: true, error: null }))

    try {
      const [tramitesRes, agentesRes] = await Promise.all([
        fetch(`/api/buscar?q=${encodeURIComponent(q)}&tipo=tramite`, {
          signal: controller.signal,
        }),
        fetch(`/api/buscar?q=${encodeURIComponent(q)}&tipo=agente`, {
          signal: controller.signal,
        }),
      ])

      const [tramites, agentes] = await Promise.all([tramitesRes.json(), agentesRes.json()])

      setResults({
        tramites: (tramites as TramiteSearchItem[]) || [],
        agentes: (agentes as AgenteSearchItem[]) || [],
        isLoading: false,
        error: null,
      })
    } catch (err: unknown) {
      if ((err as Error).name === "AbortError") return
      setResults((prev) => ({
        ...prev,
        isLoading: false,
        error: "Error al buscar. Intenta de nuevo.",
      }))
    }
  }, [])

  useEffect(() => {
    const timer = setTimeout(() => search(query), 250)
    return () => clearTimeout(timer)
  }, [query, search])

  return { query, setQuery, results }
}
