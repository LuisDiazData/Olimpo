"use client"

import { useState, useEffect, useRef, useCallback, useMemo } from "react"
import { Search, FileText, Users, MessageSquarePlus, X, Loader2 } from "lucide-react"
import { clsx } from "clsx"
import { useBusqueda, type SearchItem } from "@/hooks/use-busqueda"
import { QuickCommunicationForm } from "@/components/comunicacion/quick-communication-form"

const ESTADO_LABEL: Record<string, string> = {
  recibido:                    "Recibido",
  en_revision:                 "En revisión",
  pendiente_documentos_agente: "Docs. pendientes",
  turnado_a_gnp:               "Turnado a GNP",
  activado_gnp:                "Activado GNP",
  complemento_en_revision:     "Complemento",
  escalado:                    "Escalado",
  completado:                  "Completado",
  rechazado_gnp:               "Rechazado GNP",
  cancelado:                   "Cancelado",
}

const ESTADO_CHIP: Record<string, string> = {
  recibido:                    "bg-slate-100 text-slate-600",
  en_revision:                 "bg-blue-100 text-blue-700",
  pendiente_documentos_agente: "bg-amber-100 text-amber-700",
  turnado_a_gnp:               "bg-violet-100 text-violet-700",
  activado_gnp:                "bg-orange-100 text-orange-700",
  complemento_en_revision:     "bg-sky-100 text-sky-700",
  escalado:                    "bg-pink-100 text-pink-700",
  completado:                  "bg-green-100 text-green-700",
  rechazado_gnp:               "bg-red-100 text-red-700",
  cancelado:                   "bg-slate-100 text-slate-500",
}

interface CommandPaletteProps {
  open: boolean
  onOpenChange: (open: boolean) => void
}

export function CommandPalette({ open, onOpenChange }: CommandPaletteProps) {
  const { query, setQuery, results } = useBusqueda()
  const inputRef = useRef<HTMLInputElement>(null)
  const [selectedIndex, setSelectedIndex] = useState(0)
  const [showCommForm, setShowCommForm] = useState(false)
  const [selectedItem, setSelectedItem] = useState<SearchItem | null>(null)

  const allItems = useMemo<(SearchItem | { type: "action"; id: string; label: string })[]>(
    () => [...results.tramites, ...results.agentes],
    [results.tramites, results.agentes]
  )

  const hasResults = allItems.length > 0
  const showEmpty = query.trim().length > 0 && !results.isLoading && !hasResults

  useEffect(() => {
    setSelectedIndex(0)
  }, [query, results])

  useEffect(() => {
    if (!open) {
      setQuery("")
      setSelectedIndex(0)
      setShowCommForm(false)
      setSelectedItem(null)
    }
  }, [open, setQuery])

  useEffect(() => {
    if (open) {
      inputRef.current?.focus()
    }
  }, [open])

  const handleOpenComm = useCallback((item: SearchItem) => {
    setSelectedItem(item)
    setShowCommForm(true)
  }, [])

  const handleOpenCommWithoutSearch = useCallback(() => {
    setSelectedItem(null)
    setShowCommForm(true)
    onOpenChange(false)
  }, [onOpenChange])

  const handleKeyDown = useCallback(
    (e: React.KeyboardEvent) => {
      if (e.key === "ArrowDown") {
        e.preventDefault()
        setSelectedIndex((i) => Math.min(i + 1, allItems.length - 1))
      } else if (e.key === "ArrowUp") {
        e.preventDefault()
        setSelectedIndex((i) => Math.max(i - 1, 0))
      } else if (e.key === "Enter") {
        e.preventDefault()
        const item = allItems[selectedIndex]
        if (item) {
          if (item.type === "tramite" || item.type === "agente") {
            handleOpenComm(item)
          }
        }
      } else if (e.key === "Escape") {
        onOpenChange(false)
      }
    },
    [allItems, selectedIndex, handleOpenComm, onOpenChange]
  )

  if (!open) return null

  const tramite = selectedItem?.type === "tramite" ? selectedItem : null
  const agente = selectedItem?.type === "agente" ? selectedItem : null

  return (
    <>
      {/* Backdrop */}
      <div
        className="fixed inset-0 z-50 bg-black/50 backdrop-blur-sm"
        onClick={() => onOpenChange(false)}
      />

      {/* Palette */}
      <div
        className="fixed left-1/2 top-[15vh] z-50 w-full max-w-lg -translate-x-1/2 rounded-xl border bg-white shadow-2xl"
        role="dialog"
        aria-modal="true"
        aria-label="Búsqueda de trámites y agentes"
      >
        {/* Search input */}
        <div className="flex items-center gap-3 border-b px-4 py-3">
          <Search className="h-4 w-4 shrink-0 text-slate-400" />
          <input
            ref={inputRef}
            type="text"
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            onKeyDown={handleKeyDown}
            placeholder="Buscar trámites, agentes..."
            className="flex-1 text-sm text-slate-900 placeholder:text-slate-400 focus:outline-none bg-transparent"
          />
          {results.isLoading && <Loader2 className="h-4 w-4 animate-spin text-slate-400" />}
          {query && !results.isLoading && (
            <button onClick={() => setQuery("")} className="text-slate-400 hover:text-slate-600">
              <X className="h-4 w-4" />
            </button>
          )}
          <kbd className="hidden sm:inline-flex h-5 items-center gap-1 rounded border border-slate-200 bg-slate-50 px-1.5 text-xs text-slate-400 font-mono">
            ESC
          </kbd>
        </div>

        {/* Results */}
        <div className="max-h-80 overflow-y-auto py-2">
          {/* Quick action — agregar sin buscar */}
          <button
            onClick={handleOpenCommWithoutSearch}
            className="flex w-full items-center gap-3 px-4 py-2.5 text-sm text-slate-600 hover:bg-slate-50 transition-colors"
          >
            <MessageSquarePlus className="h-4 w-4 text-slate-400" />
            <span>Agregar comunicación rápida</span>
            <span className="ml-auto text-xs text-muted-foreground">sin buscar trámite</span>
          </button>

          {hasResults && (
            <div className="px-4 py-1.5">
              <p className="text-xs font-medium text-muted-foreground uppercase tracking-wide">
                Resultados
              </p>
            </div>
          )}

          {results.tramites.map((item, i) => {
            const globalIndex = i
            return (
              <button
                key={item.id}
                onClick={() => handleOpenComm(item)}
                className={clsx(
                  "flex w-full items-center gap-3 px-4 py-2.5 text-sm transition-colors",
                  globalIndex === selectedIndex
                    ? "bg-slate-100 text-slate-900"
                    : "text-slate-700 hover:bg-slate-50"
                )}
              >
                <FileText className="h-4 w-4 shrink-0 text-blue-500" />
                <div className="flex-1 min-w-0 text-left">
                  <p className="font-medium truncate">{item.folio}</p>
                  <p className="text-xs text-muted-foreground truncate">
                    {item.titulo}
                    {item.agente_nombre && ` · ${item.agente_nombre}`}
                  </p>
                </div>
                <span className={clsx(
                    "shrink-0 text-xs px-1.5 py-0.5 rounded font-medium",
                    ESTADO_CHIP[item.estado] ?? "bg-slate-100 text-slate-600"
                  )}
                >
                  {ESTADO_LABEL[item.estado] ?? item.estado}
                </span>
              </button>
            )
          })}

          {results.agentes.map((item, i) => {
            const globalIndex = results.tramites.length + i
            return (
              <button
                key={item.id}
                onClick={() => handleOpenComm(item)}
                className={clsx(
                  "flex w-full items-center gap-3 px-4 py-2.5 text-sm transition-colors",
                  globalIndex === selectedIndex
                    ? "bg-slate-100 text-slate-900"
                    : "text-slate-700 hover:bg-slate-50"
                )}
              >
                <Users className="h-4 w-4 shrink-0 text-purple-500" />
                <div className="flex-1 min-w-0 text-left">
                  <p className="font-medium truncate">{item.nombre}</p>
                  {item.cua && (
                    <p className="text-xs text-muted-foreground">CUA {item.cua}</p>
                  )}
                </div>
              </button>
            )
          })}

          {showEmpty && (
            <div className="flex flex-col items-center gap-2 py-8 text-center">
              <Search className="h-8 w-8 text-slate-300" />
              <p className="text-sm text-slate-500">Sin resultados para &ldquo;{query}&rdquo;</p>
              <button
                onClick={handleOpenCommWithoutSearch}
                className="text-sm text-slate-600 underline hover:text-slate-900"
              >
                Agregar comunicación rápida de todos modos
              </button>
            </div>
          )}

          {!query && (
            <div className="px-4 py-4 text-center">
              <p className="text-xs text-muted-foreground">
                Escribe para buscar trámites o agentes
              </p>
            </div>
          )}
        </div>

        {/* Footer */}
        <div className="flex items-center justify-between border-t px-4 py-2 text-xs text-muted-foreground">
          <div className="flex items-center gap-3">
            <span className="flex items-center gap-1">
              <kbd className="rounded border border-slate-200 bg-slate-50 px-1.5 font-mono">↑↓</kbd>
              navegar
            </span>
            <span className="flex items-center gap-1">
              <kbd className="rounded border border-slate-200 bg-slate-50 px-1.5 font-mono">↵</kbd>
              seleccionar
            </span>
          </div>
          <div className="flex items-center gap-1">
            <kbd className="rounded border border-slate-200 bg-slate-50 px-1.5 font-mono">⌘K</kbd>
            <span>para abrir</span>
          </div>
        </div>
      </div>

      {/* Quick Communication Form */}
      <QuickCommunicationForm
        open={showCommForm}
        onClose={() => {
          setShowCommForm(false)
          setSelectedItem(null)
          onOpenChange(false)
        }}
        tramite={tramite}
        agente={agente}
      />
    </>
  )
}
