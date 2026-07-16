import type { TokenUsage } from '../shared/contracts'

export class UsageParseError extends Error {}

type JSONObject = Record<string, unknown>

function isObject(value: unknown): value is JSONObject {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function safeInteger(value: unknown): number | undefined {
  if (typeof value === 'number') return Number.isSafeInteger(value) ? value : undefined
  if (typeof value !== 'string' || !/^-?\d+$/.test(value)) return undefined
  const number = Number(value)
  return Number.isSafeInteger(number) ? number : undefined
}

function firstInt(object: JSONObject, keys: string[]): number | undefined {
  for (const key of keys) {
    const value = safeInteger(object[key])
    if (value !== undefined) return value
  }
  return undefined
}

function firstString(object: JSONObject, keys: string[]): string | undefined {
  for (const key of keys) {
    const value = object[key]
    if (typeof value === 'string' && value.trim()) return value.trim()
  }
  return undefined
}

function firstBoolean(object: JSONObject, keys: string[]): boolean | undefined {
  for (const key of keys) {
    const value = object[key]
    if (typeof value === 'boolean') return value
    if (typeof value === 'string') {
      if (['true', '1'].includes(value.toLowerCase())) return true
      if (['false', '0'].includes(value.toLowerCase())) return false
    }
  }
  return undefined
}

function valueAt(root: JSONObject, path: string[]): unknown {
  return path.reduce<unknown>((value, key) => isObject(value) ? value[key] : undefined, root)
}

function firstIntAt(root: JSONObject, paths: string[][]): number | undefined {
  for (const path of paths) {
    const value = safeInteger(valueAt(root, path))
    if (value !== undefined) return value
  }
  return undefined
}

function firstStringAt(root: JSONObject, paths: string[][]): string | undefined {
  for (const path of paths) {
    const value = valueAt(root, path)
    if (typeof value === 'string') return value
  }
  return undefined
}

function isoDateValue(value: unknown): string | undefined {
  if (typeof value !== 'string' || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?(?:Z|[+-]\d{2}:\d{2})$/.test(value)) return undefined
  const parsed = new Date(value)
  return Number.isNaN(parsed.getTime()) ? undefined : parsed.toISOString()
}

function quotaDateValue(value: unknown): string | undefined {
  let date: Date | undefined
  if (typeof value === 'number' && Number.isSafeInteger(value) && value > 0) {
    date = new Date(value * 1000)
  } else if (typeof value === 'string' && /^\d+$/.test(value) && Number.isSafeInteger(Number(value)) && Number(value) > 0) {
    date = new Date(Number(value) * 1000)
  } else {
    const iso = isoDateValue(value)
    if (iso) date = new Date(iso)
  }
  return date && !Number.isNaN(date.getTime()) ? date.toISOString() : undefined
}

function safeSum(lhs: number, rhs: number | undefined): number | undefined {
  if (rhs === undefined) return undefined
  const sum = lhs + rhs
  return Number.isSafeInteger(sum) ? sum : undefined
}

function directWindow(root: JSONObject, window: 'fiveHours' | 'week'): TokenUsage | undefined {
  const key = window === 'fiveHours' ? 'fiveHours' : 'week'
  const snake = window === 'fiveHours' ? 'five_hours' : 'week'
  const short = window === 'fiveHours' ? '5h' : 'weekly'
  const parents = [[key], [snake], [short], ['usage', key], ['usage', snake], ['usage', short]]
  const used = firstIntAt(root, [
    ...parents.map((path) => [...path, 'used']),
    [`${key}Used`], [`${snake}_used`], [`${short}_used`]
  ])
  if (used === undefined) return undefined
  const limit = firstIntAt(root, [
    ...parents.map((path) => [...path, 'limit']),
    [`${key}Limit`], [`${snake}_limit`], [`${short}_limit`]
  ])
  const resetAt = firstStringAt(root, [
    ...parents.flatMap((path) => [[...path, 'resetAt'], [...path, 'reset_at']])
  ])
  const normalizedResetAt = isoDateValue(resetAt)
  return { window, used, ...(limit === undefined ? {} : { limit }), ...(normalizedResetAt ? { resetAt: normalizedResetAt } : {}) }
}

function totalTokenQuota(root: JSONObject): TokenUsage | undefined {
  const payloads = [isObject(root.data) ? root.data : undefined, root].filter((value): value is JSONObject => Boolean(value))
  for (const payload of payloads) {
    const used = firstInt(payload, ['total_used', 'totalUsed', 'used_tokens', 'usedTokens'])
    if (used === undefined) continue
    const granted = firstInt(payload, ['total_granted', 'totalGranted', 'token_limit', 'tokenLimit'])
    const available = firstInt(payload, ['total_available', 'totalAvailable', 'available_tokens', 'availableTokens'])
    const unlimited = firstBoolean(payload, ['unlimited_quota', 'unlimitedQuota']) ?? false
    const limit = unlimited ? undefined : (granted ?? safeSum(used, available))
    const resetAt = quotaDateValue(payload.expires_at ?? payload.expiresAt)
    return {
      window: 'tokenQuota', label: 'Usage', used,
      ...(limit === undefined ? {} : { limit }),
      ...(resetAt ? { resetAt } : {}), unit: 'tokens'
    }
  }
  return undefined
}

function windowFromPath(path: string[]): 'fiveHours' | 'week' | undefined {
  const joined = path.join('_').toLowerCase()
  if (['fivehour', 'five_hour', '5h', '5_hour', 'rolling5'].some((token) => joined.includes(token))) return 'fiveHours'
  if (['weekly', 'week', '7d', 'seven_day'].some((token) => joined.includes(token))) return 'week'
  return undefined
}

function inferredWindows(root: JSONObject): TokenUsage[] {
  const found = new Map<'fiveHours' | 'week', TokenUsage>()
  const scan = (value: unknown, path: string[]): void => {
    if (Array.isArray(value)) {
      value.forEach((child) => scan(child, path))
      return
    }
    if (!isObject(value)) return
    const window = windowFromPath(path)
    if (window) {
      const used = firstInt(value, ['used', 'usage', 'tokens', 'total_tokens', 'totalTokens', 'used_tokens', 'usedTokens', 'consumed', 'consumed_tokens', 'consumedTokens'])
        ?? summedInt(value, ['input_tokens', 'inputTokens', 'output_tokens', 'outputTokens', 'cache_creation_input_tokens', 'cacheReadInputTokens', 'cache_read_input_tokens'])
      if (used !== undefined) {
        const limit = firstInt(value, ['limit', 'quota', 'total', 'max', 'token_limit', 'tokenLimit'])
        const resetAt = isoDateValue(firstString(value, ['resetAt', 'reset_at', 'resetTime', 'reset_time', 'expiresAt', 'expires_at']))
        found.set(window, { window, used, ...(limit === undefined ? {} : { limit }), ...(resetAt ? { resetAt } : {}) })
      }
    }
    Object.entries(value).forEach(([key, child]) => scan(child, [...path, key]))
  }
  scan(root, [])
  return (['fiveHours', 'week'] as const).flatMap((window) => found.get(window) ?? [])
}

function summedInt(object: JSONObject, keys: string[]): number | undefined {
  const values = keys.map((key) => safeInteger(object[key])).filter((value): value is number => value !== undefined)
  if (!values.length) return undefined
  const sum = values.reduce((total, value) => total + value, 0)
  return Number.isSafeInteger(sum) ? sum : undefined
}

function planName(root: JSONObject): string | undefined {
  for (const payload of [isObject(root.data) ? root.data : undefined, root]) {
    if (!payload) continue
    const name = firstString(payload, ['name', 'plan_name', 'planName', 'display_name', 'displayName'])
    if (name) return name
  }
  return undefined
}

export interface UsagePayload { usages: TokenUsage[]; planName?: string }

export function parseUsageJSON(text: string): UsagePayload {
  let parsed: unknown
  try {
    parsed = JSON.parse(text)
  } catch {
    throw new UsageParseError('Response is not valid JSON')
  }
  if (!isObject(parsed)) throw new UsageParseError('Expected a JSON object')

  const usages = (['fiveHours', 'week'] as const).flatMap((window) => directWindow(parsed, window) ?? [])
  const total = totalTokenQuota(parsed)
  if (total) usages.push(total)
  const finalUsages = usages.length ? usages : inferredWindows(parsed)
  if (!finalUsages.length) throw new UsageParseError('No supported usage fields found')
  return { usages: finalUsages, ...(planName(parsed) ? { planName: planName(parsed) } : {}) }
}
