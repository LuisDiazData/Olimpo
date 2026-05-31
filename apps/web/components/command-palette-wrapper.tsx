"use client"

import { useCommandPalette } from "./providers/command-palette-provider"
import { CommandPalette } from "./command-palette"

export function CommandPaletteWrapper() {
  const { open, setOpen } = useCommandPalette()
  return <CommandPalette open={open} onOpenChange={setOpen} />
}
