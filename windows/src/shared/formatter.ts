import type { TokenUsage } from './contracts'

const titles: Record<TokenUsage['window'], string> = {
  fiveHours: '5h',
  week: 'Week',
  tokenQuota: 'Usage'
}

export function usageTitle(usage: TokenUsage): string {
  return usage.label?.trim() || titles[usage.window]
}

export function usageRatio(usage: TokenUsage): number | undefined {
  if (usage.limit === undefined || usage.limit <= 0) return undefined
  return Math.min(Math.max(usage.used / usage.limit, 0), 1)
}

function trimmedDecimal(value: number): string {
  return value.toFixed(2).replace(/\.00$/, '').replace(/(\.\d)0$/, '$1')
}

export function formatAmount(value: number): string {
  const magnitude = Math.abs(value)
  if (magnitude >= 1_000_000_000) return `${trimmedDecimal(value / 1_000_000_000)}B`
  if (magnitude >= 1_000_000) return `${trimmedDecimal(value / 1_000_000)}M`
  if (magnitude >= 1_000) return `${trimmedDecimal(value / 1_000)}K`
  return formatExactAmount(value)
}

export function formatExactAmount(value: number): string {
  return new Intl.NumberFormat('en-US', { maximumFractionDigits: 0 }).format(value)
}

function withUnit(value: string, unit?: string): string {
  return unit ? `${value} ${unit}` : value
}

export function amountText(usage: TokenUsage): string {
  if (usage.window === 'tokenQuota') {
    const ratio = usageRatio(usage)
    return ratio === undefined ? withUnit(formatAmount(usage.used), usage.unit) : `${trimmedDecimal(ratio * 100)}%`
  }
  if (usage.unit === '%') return `${usage.used}%`
  const amount = usage.limit === undefined
    ? formatAmount(usage.used)
    : `${formatAmount(usage.used)} / ${formatAmount(usage.limit)}`
  return withUnit(amount, usage.unit)
}

export function exactAmountText(usage: TokenUsage): string {
  if (usage.unit === '%') return `${usage.used}%`
  const amount = usage.limit === undefined
    ? formatExactAmount(usage.used)
    : `${formatExactAmount(usage.used)} / ${formatExactAmount(usage.limit)}`
  return withUnit(amount, usage.unit)
}

export function usageTone(usage: TokenUsage): 'green' | 'orange' | 'red' | 'accent' {
  const ratio = usageRatio(usage)
  if (ratio === undefined) return 'accent'
  if (ratio >= 0.9) return 'red'
  if (ratio >= 0.7) return 'orange'
  return 'green'
}

export function resetText(resetAt: string | undefined, now = new Date()): string {
  if (!resetAt) return 'Reset time unavailable'
  const reset = new Date(resetAt)
  const seconds = Math.ceil((reset.getTime() - now.getTime()) / 1000)
  const absolute = new Intl.DateTimeFormat(undefined, {
    month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit'
  }).format(reset)
  if (seconds <= 0) return `Reset due · ${absolute}`
  const minutes = Math.floor(seconds / 60)
  let duration: string
  if (seconds < 60) duration = `${seconds}s`
  else if (minutes < 60) duration = `${minutes}m`
  else if (minutes < 1_440) {
    const hours = Math.floor(minutes / 60)
    const remaining = minutes % 60
    duration = remaining ? `${hours}h ${remaining}m` : `${hours}h`
  } else {
    const days = Math.floor(minutes / 1_440)
    const hours = Math.floor((minutes % 1_440) / 60)
    duration = hours ? `${days}d ${hours}h` : `${days}d`
  }
  return `Resets in ${duration} · ${absolute}`
}
