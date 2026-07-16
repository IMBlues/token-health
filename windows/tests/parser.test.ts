import { describe, expect, it } from 'vitest'
import { parseUsageJSON, UsageParseError } from '../src/main/usageParser'

describe('UsageJSONParser parity', () => {
  it('parses camel, snake, usage wrappers, flat and nested windows', () => {
    expect(parseUsageJSON(JSON.stringify({ fiveHours: { used: 12, limit: 50 }, week: { used: 30, limit: 100 } })).usages.map((item) => item.used)).toEqual([12, 30])
    expect(parseUsageJSON(JSON.stringify({ usage: { five_hours: { used: '9', limit: '20' }, weekly: { used: 11 } } })).usages.map((item) => item.window)).toEqual(['fiveHours', 'week'])
    expect(parseUsageJSON(JSON.stringify({ fiveHoursUsed: 1, fiveHoursLimit: 2, week_used: 3, week_limit: 4 })).usages.map((item) => item.limit)).toEqual([2, 4])
    expect(parseUsageJSON(JSON.stringify({ envelope: { rolling5Hour: { input_tokens: 5, output_tokens: 7, limit: 50 }, seven_day_window: { consumedTokens: 9 } } })).usages.map((item) => item.used)).toEqual([12, 9])
  })

  it('parses token quota data wrapper and plan name', () => {
    const payload = parseUsageJSON(JSON.stringify({ data: { name: 'Example User', total_available: 80, total_used: 20, unlimited_quota: false } }))
    expect(payload.planName).toBe('Example User')
    expect(payload.usages[0]).toMatchObject({ window: 'tokenQuota', used: 20, limit: 100, unit: 'tokens' })
  })

  it('honors granted and unlimited quota', () => {
    expect(parseUsageJSON(JSON.stringify({ total_used: 20, total_granted: 120 })).usages[0].limit).toBe(120)
    expect(parseUsageJSON(JSON.stringify({ total_used: 20, total_granted: 120, unlimited_quota: true })).usages[0].limit).toBeUndefined()
  })

  it('matches Swift reset parsing for direct ISO windows and token quota seconds', () => {
    const payload = parseUsageJSON(JSON.stringify({
      fiveHours: { used: 1, resetAt: '2026-08-01T00:00:00Z' },
      data: { total_used: 2, expires_at: 1_783_665_814 }
    }))
    expect(payload.usages[0].resetAt).toBe('2026-08-01T00:00:00.000Z')
    expect(payload.usages[1].resetAt).toBe('2026-07-10T06:43:34.000Z')
  })

  it('rejects unsafe, fractional, scientific, hex integers and loose dates', () => {
    for (const used of [Number.MAX_SAFE_INTEGER + 1, 1.2, '1.2', '1e3', '0x10', '+12', ' 12']) {
      expect(() => parseUsageJSON(JSON.stringify({ fiveHours: { used } }))).toThrow(UsageParseError)
    }
    const dates = parseUsageJSON(JSON.stringify({
      fiveHours: { used: 1, resetAt: 'August 1, 2026' },
      data: { total_used: 2, expires_at: '1e3' }
    }))
    expect(dates.usages.every((usage) => usage.resetAt === undefined)).toBe(true)
    expect(() => parseUsageJSON('[]')).toThrow('Expected a JSON object')
    expect(() => parseUsageJSON('{')).toThrow('not valid JSON')
  })
})
