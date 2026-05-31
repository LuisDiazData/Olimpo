"use client"

import { createContext, useContext, useState, useCallback, useEffect } from "react"

interface CommandPaletteContextValue {
  open: boolean
  setOpen: (open: boolean) => void
  togglePalette: () => void
}

const CommandPaletteContext = createContext<CommandPaletteContextValue>({
  open: false,
  setOpen: () => {},
  togglePalette: () => {},
})

export function CommandPaletteProvider({ children }: { children: React.ReactNode }) {
  const [open, setOpen] = useState(false)

  const togglePalette = useCallback(() => setOpen((o) => !o), [])

  useEffect(() => {
    const handler = (e: KeyboardEvent) => {
      if ((e.metaKey || e.ctrlKey) && e.key === "k") {
        e.preventDefault()
        togglePalette()
      }
    }
    document.addEventListener("keydown", handler)
    return () => document.removeEventListener("keydown", handler)
  }, [togglePalette])

  return (
    <CommandPaletteContext.Provider value={{ open, setOpen, togglePalette }}>
      {children}
    </CommandPaletteContext.Provider>
  )
}

export const useCommandPalette = () => useContext(CommandPaletteContext)
