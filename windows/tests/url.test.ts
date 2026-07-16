import { describe, expect, it } from 'vitest'
import { isInsecureEndpoint, validateEndpoint } from '../src/main/genericHttp'

describe('Generic HTTP URL policy', () => {
  it('allows HTTPS, HTTP, localhost, and private hosts', () => {
    expect(validateEndpoint('https://example.test/usage').hostname).toBe('example.test')
    expect(validateEndpoint('http://localhost:8080/usage').hostname).toBe('localhost')
    expect(validateEndpoint('http://192.168.1.8/usage').hostname).toBe('192.168.1.8')
    expect(isInsecureEndpoint('http://10.0.0.2/usage')).toBe(true)
  })

  it('rejects non-HTTP protocols and credentials', () => {
    expect(() => validateEndpoint('file:///etc/passwd')).toThrow('HTTP or HTTPS')
    expect(() => validateEndpoint('https://user:password@example.test')).toThrow('credentials')
    expect(() => validateEndpoint('not a url')).toThrow('Invalid')
  })
})
