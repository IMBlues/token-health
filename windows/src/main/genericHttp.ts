import type { ProviderSnapshot, ServiceConfig } from '../shared/contracts'
import { parseUsageJSON } from './usageParser'

export const GENERIC_TIMEOUT_MS = 20_000
export const GENERIC_MAX_RESPONSE_BYTES = 2 * 1024 * 1024
export const GENERIC_MAX_REDIRECTS = 5

export class GenericHTTPError extends Error {}

export function validateEndpoint(value: string): URL {
  let url: URL
  try {
    url = new URL(value)
  } catch {
    throw new GenericHTTPError('Invalid endpoint URL')
  }
  if (!['http:', 'https:'].includes(url.protocol)) throw new GenericHTTPError('Endpoint must use HTTP or HTTPS')
  if (url.username || url.password) throw new GenericHTTPError('URL credentials are not allowed')
  if (!url.hostname) throw new GenericHTTPError('Endpoint host is missing')
  return url
}

export function isInsecureEndpoint(value: string): boolean {
  return validateEndpoint(value).protocol === 'http:'
}

export interface HTTPResponse {
  status: number
  headers: { get(name: string): string | null }
  body: ReadableStream<Uint8Array> | null
}

export type FetchLike = (url: URL, init: {
  method: 'GET'
  headers: Record<string, string>
  redirect: 'manual'
  signal: AbortSignal
}) => Promise<HTTPResponse>

async function readLimitedBody(body: ReadableStream<Uint8Array> | null, limit: number): Promise<string> {
  if (!body) return ''
  const reader = body.getReader()
  const chunks: Uint8Array[] = []
  let total = 0
  while (true) {
    const { done, value } = await reader.read()
    if (done) break
    total += value.byteLength
    if (total > limit) {
      await reader.cancel()
      throw new GenericHTTPError('Response exceeded the 2 MiB safety limit')
    }
    chunks.push(value)
  }
  const combined = new Uint8Array(total)
  let offset = 0
  for (const chunk of chunks) {
    combined.set(chunk, offset)
    offset += chunk.byteLength
  }
  return new TextDecoder('utf-8', { fatal: true }).decode(combined)
}

function redirectURL(location: string | null, current: URL): URL {
  if (!location) throw new GenericHTTPError('Redirect response is missing Location')
  return validateEndpoint(new URL(location, current).toString())
}

export async function fetchGenericUsage(
  config: ServiceConfig,
  bearerToken: string,
  options: { fetchImpl?: FetchLike; now?: Date } = {}
): Promise<ProviderSnapshot> {
  const fetchImpl: FetchLike = options.fetchImpl ?? ((url, init) => globalThis.fetch(url, init) as Promise<HTTPResponse>)
  const controller = new AbortController()
  const timer = setTimeout(() => controller.abort(), GENERIC_TIMEOUT_MS)
  let current = validateEndpoint(config.apiEndpoint)
  const authorizationOrigin = current.origin
  const visited = new Set<string>()
  try {
    for (let redirects = 0; redirects <= GENERIC_MAX_REDIRECTS; redirects += 1) {
      if (visited.has(current.href)) throw new GenericHTTPError('Redirect loop detected')
      visited.add(current.href)
      const authorization = bearerToken.trim()
      const response = await fetchImpl(current, {
        method: 'GET',
        headers: {
          Accept: 'application/json',
          ...(authorization && current.origin === authorizationOrigin ? { Authorization: `Bearer ${authorization}` } : {})
        },
        redirect: 'manual', signal: controller.signal
      })
      if ([301, 302, 303, 307, 308].includes(response.status)) {
        if (redirects === GENERIC_MAX_REDIRECTS) throw new GenericHTTPError('Too many redirects')
        current = redirectURL(response.headers.get('location'), current)
        continue
      }
      if (response.status < 200 || response.status >= 300) throw new GenericHTTPError(`HTTP ${response.status}`)
      const contentLengthHeader = response.headers.get('content-length')
      if (contentLengthHeader !== null && !/^\d+$/.test(contentLengthHeader.trim())) {
        throw new GenericHTTPError('Response has an invalid Content-Length')
      }
      const contentLength = contentLengthHeader === null ? 0 : Number(contentLengthHeader)
      if (!Number.isSafeInteger(contentLength)) throw new GenericHTTPError('Response has an invalid Content-Length')
      if (contentLength > GENERIC_MAX_RESPONSE_BYTES) {
        throw new GenericHTTPError('Response exceeded the 2 MiB safety limit')
      }
      const payload = parseUsageJSON(await readLimitedBody(response.body, GENERIC_MAX_RESPONSE_BYTES))
      return {
        id: config.id,
        serviceName: config.displayName,
        providerTitle: 'Generic HTTP',
        ...(payload.planName ? { planName: payload.planName } : {}),
        usages: payload.usages,
        state: 'ready',
        statusMessage: current.protocol === 'http:' ? 'Updated over insecure HTTP' : 'Updated',
        updatedAt: (options.now ?? new Date()).toISOString()
      }
    }
    throw new GenericHTTPError('Too many redirects')
  } catch (error) {
    const message = controller.signal.aborted ? 'Request timed out' : error instanceof Error ? error.message : 'Generic HTTP unavailable'
    return unavailable(config, message, options.now)
  } finally {
    clearTimeout(timer)
  }
}

export function unavailable(config: ServiceConfig, message: string, now = new Date()): ProviderSnapshot {
  return {
    id: config.id,
    serviceName: config.displayName,
    providerTitle: config.providerKind === 'codex' ? 'Codex' : 'Generic HTTP',
    usages: [],
    state: 'unavailable',
    statusMessage: message,
    updatedAt: now.toISOString()
  }
}
