import { describe, expect, it } from 'vitest'
import { GENERIC_MAX_RESPONSE_BYTES, fetchGenericUsage, type FetchLike } from '../src/main/genericHttp'

const config = { id: '20ef7cc1-7b98-4780-b3a5-4fd82456ae77', displayName: 'Generic', providerKind: 'genericHTTP' as const, apiEndpoint: 'https://first.test/usage', isEnabled: true }
function response(status: number, body: string, headers: Record<string, string> = {}): Awaited<ReturnType<FetchLike>> {
  return { status, headers: { get: (name) => headers[name.toLowerCase()] ?? null }, body: new Response(body).body }
}

describe('Generic HTTP client', () => {
  it('uses GET, JSON accept, bearer and validates redirects', async () => {
    const requests: Array<{ url: string; init: Parameters<FetchLike>[1] }> = []
    const fetchImpl: FetchLike = async (url, init) => {
      requests.push({ url: url.href, init })
      return requests.length === 1 ? response(302, '', { location: 'http://localhost/usage' }) : response(200, '{"fiveHours":{"used":1,"limit":2}}')
    }
    const result = await fetchGenericUsage(config, 'secret', { fetchImpl })
    expect(result.state).toBe('ready')
    expect(result.statusMessage).toContain('insecure HTTP')
    expect(requests[0].init).toMatchObject({ method: 'GET', redirect: 'manual', headers: { Accept: 'application/json', Authorization: 'Bearer secret' } })
    expect(requests[1].url).toBe('http://localhost/usage')
    expect(requests[1].init.headers).not.toHaveProperty('Authorization')
  })

  it('rejects credential-bearing redirects, invalid lengths, non-2xx and oversized bodies', async () => {
    const credentialRedirect: FetchLike = async () => response(302, '', { location: 'https://user:pass@example.test' })
    expect((await fetchGenericUsage(config, '', { fetchImpl: credentialRedirect })).statusMessage).toContain('credentials')
    expect((await fetchGenericUsage(config, '', { fetchImpl: async () => response(500, '{}') })).statusMessage).toBe('HTTP 500')
    expect((await fetchGenericUsage(config, '', { fetchImpl: async () => response(200, '{}', { 'content-length': 'not-a-number' }) })).statusMessage).toContain('invalid Content-Length')
    const oversized = await fetchGenericUsage(config, '', { fetchImpl: async () => response(200, '{}', { 'content-length': String(GENERIC_MAX_RESPONSE_BYTES + 1) }) })
    expect(oversized.statusMessage).toContain('2 MiB')
  })
})
