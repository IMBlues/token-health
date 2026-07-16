import { describe, expect, it } from 'vitest'
import { amountText, exactAmountText, formatAmount, resetText, usageTone } from '../src/shared/formatter'

describe('usage formatter', () => {
  it('formats K/M/B and exact numbers', () => {
    expect(formatAmount(999)).toBe('999')
    expect(formatAmount(1_250)).toBe('1.25K')
    expect(formatAmount(2_137_675)).toBe('2.14M')
    expect(formatAmount(3_000_000_000)).toBe('3B')
  })

  it('uses token quota percentage and exact text', () => {
    const usage = { window: 'tokenQuota' as const, used: 2_137_675, limit: 300_803_492, unit: 'tokens' }
    expect(amountText(usage)).toBe('0.71%')
    expect(exactAmountText(usage)).toBe('2,137,675 / 300,803,492 tokens')
    expect(amountText({ ...usage, limit: undefined })).toBe('2.14M tokens')
  })

  it('applies 70/90 thresholds', () => {
    expect(usageTone({ window: 'fiveHours', used: 69, limit: 100 })).toBe('green')
    expect(usageTone({ window: 'fiveHours', used: 70, limit: 100 })).toBe('orange')
    expect(usageTone({ window: 'fiveHours', used: 90, limit: 100 })).toBe('red')
  })

  it('formats reset countdown', () => {
    expect(resetText('2026-01-02T01:30:00.000Z', new Date('2026-01-02T00:00:00.000Z'))).toContain('1h 30m')
  })
})
