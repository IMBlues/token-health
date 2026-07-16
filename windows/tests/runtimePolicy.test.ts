import { describe, expect, it } from 'vitest'
import { allowedRendererOrigin, isHiddenLaunch, shouldAllowRendererRequest } from '../src/main/runtimePolicy'

describe('Electron runtime policy', () => {
  it('uses the fixed hidden launch argument', () => {
    expect(isHiddenLaunch(['Token Health.exe', '--hidden'])).toBe(true)
    expect(isHiddenLaunch(['Token Health.exe'])).toBe(false)
  })

  it('allows only the exact development renderer origin and blocks production network', () => {
    const origin = allowedRendererOrigin('http://127.0.0.1:5173/path', false)
    expect(origin).toBe('http://127.0.0.1:5173')
    expect(shouldAllowRendererRequest('http://127.0.0.1:5173/@vite/client', origin)).toBe(true)
    expect(shouldAllowRendererRequest('http://localhost:5173/@vite/client', origin)).toBe(false)
    expect(shouldAllowRendererRequest('https://127.0.0.1:5173/', origin)).toBe(false)
    expect(allowedRendererOrigin('http://127.0.0.1:5173', true)).toBeUndefined()
    expect(shouldAllowRendererRequest('https://example.test', undefined)).toBe(false)
  })
})
