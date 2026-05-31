import { cn } from "@/lib/utils"

type BadgeVariant =
  | "slate"
  | "blue"
  | "sky"
  | "amber"
  | "emerald"
  | "green"
  | "violet"
  | "purple"
  | "red"
  | "rose"
  | "teal"
  | "orange"

const styles: Record<BadgeVariant, string> = {
  slate:   "bg-slate-100   text-slate-600",
  blue:    "bg-blue-100    text-blue-700",
  sky:     "bg-sky-100     text-sky-700",
  amber:   "bg-amber-100   text-amber-700",
  emerald: "bg-emerald-100 text-emerald-700",
  green:   "bg-green-100   text-green-700",
  violet:  "bg-violet-100  text-violet-700",
  purple:  "bg-purple-100  text-purple-700",
  red:     "bg-red-100     text-red-700",
  rose:    "bg-rose-100    text-rose-700",
  teal:    "bg-teal-100    text-teal-700",
  orange:  "bg-orange-100  text-orange-700",
}

interface BadgeProps {
  children: React.ReactNode
  variant?: BadgeVariant
  className?: string
}

export function Badge({ children, variant = "slate", className }: BadgeProps) {
  return (
    <span
      className={cn(
        "inline-flex items-center rounded-full px-2 py-0.5 text-xs font-medium whitespace-nowrap",
        styles[variant],
        className
      )}
    >
      {children}
    </span>
  )
}
