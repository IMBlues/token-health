import { describe, expect, it } from 'vitest'
import { serviceConfigSchema, upsertProviderInputSchema } from '../src/shared/contracts'

const id = '20ef7cc1-7b98-4780-b3a5-4fd82456ae77'

describe('IPC schemas', () => {
  it('accepts only supported providers and strict keys', () => {
    expect(serviceConfigSchema.parse({ id, displayName: 'Local', providerKind: 'genericHTTP', apiEndpoint: 'http://localhost', isEnabled: true }).providerKind).toBe('genericHTTP')
    expect(() => serviceConfigSchema.parse({ id, displayName: 'Bad', providerKind: 'genericHTTP', apiEndpoint: 'file:///tmp/usage', isEnabled: true })).toThrow()
    expect(() => serviceConfigSchema.parse({ id, displayName: 'Bad', providerKind: 'genericHTTP', apiEndpoint: 'https://user:pass@example.test', isEnabled: true })).toThrow()
    expect(() => serviceConfigSchema.parse({ id, displayName: 'Bad', providerKind: 'shell', apiEndpoint: '', isEnabled: true })).toThrow()
    expect(() => serviceConfigSchema.parse({ id, displayName: 'Bad', providerKind: 'codex', apiEndpoint: 'https://x', isEnabled: true })).toThrow()
    expect(() => serviceConfigSchema.parse({ id, displayName: 'Bad', providerKind: 'codex', apiEndpoint: '', isEnabled: true, command: 'cmd.exe' })).toThrow()
  })

  it('bounds bearer input, requires explicit action, and rejects extra capabilities', () => {
    const config = { id, displayName: 'Generic', providerKind: 'genericHTTP' as const, apiEndpoint: 'https://x.test', isEnabled: true }
    expect(upsertProviderInputSchema.parse({ config, bearerTokenAction: 'replace', bearerToken: 'secret' }).bearerToken).toBe('secret')
    expect(upsertProviderInputSchema.parse({ config, bearerTokenAction: 'clear' }).bearerTokenAction).toBe('clear')
    expect(() => upsertProviderInputSchema.parse({ config })).toThrow()
    expect(() => upsertProviderInputSchema.parse({ config, bearerTokenAction: 'keep', bearerToken: 'secret' })).toThrow()
    expect(() => upsertProviderInputSchema.parse({ config, bearerTokenAction: 'replace', bearerToken: '' })).toThrow()
    expect(() => upsertProviderInputSchema.parse({ config, bearerTokenAction: 'clear', fetch: 'https://evil.test' })).toThrow()
    expect(() => upsertProviderInputSchema.parse({ config, bearerTokenAction: 'replace', bearerToken: 'x'.repeat(16_385) })).toThrow()
  })
})
