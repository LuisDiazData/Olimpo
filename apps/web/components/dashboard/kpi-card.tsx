import { TrendingUp, TrendingDown, Minus, FileText, ShieldCheck, AlertTriangle, CheckCircle2, Clock, RotateCcw, Mail, Inbox, ArrowUpRight, AlertCircle, TrendingDown as TrendingDownIcon, type LucideIcon } from "lucide-react"
import { cn } from "@/lib/utils"

const iconMap: Record<string, LucideIcon> = {
  FileText,
  ShieldCheck,
  AlertTriangle,
  CheckCircle2,
  Clock,
  RotateCcw,
  Mail,
  Inbox,
  ArrowUpRight,
  AlertCircle,
  TrendingUp,
  TrendingDownIcon,
}

interface KpiCardProps {
  label: string
  value: string | number
  icon: LucideIcon | string
  description?: string
  delta?: number
  accent?: "blue" | "green" | "red" | "amber" | "violet" | "neutral"
  invertDelta?: boolean
  subvalue?: string
}

const accentStyles = {
  blue:    "bg-blue-50 text-blue-700",
  green:   "bg-emerald-50 text-emerald-700",
  red:     "bg-red-50 text-red-700",
  amber:   "bg-amber-50 text-amber-700",
  violet:  "bg-violet-50 text-violet-700",
  neutral: "bg-slate-100 text-slate-500",
}

export function KpiCard({
  label,
  value,
  icon,
  description,
  delta,
  accent = "blue",
  invertDelta = false,
  subvalue,
}: KpiCardProps) {
  const IconComponent = typeof icon === "string" ? iconMap[icon] : icon
  const hasDelta = delta !== undefined && delta !== null
  const isPositive = hasDelta && (invertDelta ? delta <= 0 : delta >= 0)
  const isNeutral = hasDelta && delta === 0

  return (
    <div className="rounded-xl border bg-white p-5 shadow-sm">
      <div className="flex items-start justify-between gap-3">
        <div className="min-w-0 flex-1">
          <p className="text-sm font-medium text-slate-500 truncate">{label}</p>
          <p className="mt-1 text-3xl font-bold tracking-tight text-slate-900">{value}</p>
          {description && (
            <p className="mt-1 text-xs text-muted-foreground">{description}</p>
          )}
          {subvalue && (
            <p className="mt-1 text-xs text-slate-400">{subvalue}</p>
          )}
          {hasDelta && !isNeutral && (
            <p
              className={cn(
                "mt-1.5 flex items-center gap-1 text-xs font-medium",
                isPositive ? "text-emerald-600" : "text-red-500"
              )}
            >
              {isPositive ? (
                <TrendingUp className="h-3 w-3" />
              ) : (
                <TrendingDown className="h-3 w-3" />
              )}
              {delta > 0 ? "+" : ""}
              {delta} vs mes anterior
            </p>
          )}
          {hasDelta && isNeutral && (
            <p className="mt-1.5 flex items-center gap-1 text-xs font-medium text-slate-400">
              <Minus className="h-3 w-3" />
              Sin cambio vs mes anterior
            </p>
          )}
        </div>
        <div className={cn("flex h-10 w-10 shrink-0 items-center justify-center rounded-lg", accentStyles[accent])}>
          <IconComponent className="h-5 w-5" />
        </div>
      </div>
    </div>
  )
}
