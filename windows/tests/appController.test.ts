import { describe, expect, it, vi } from 'vitest'

vi.mock('electron', () => ({
  app: {
    getLoginItemSettings: () => ({ openAtLogin: false }),
    setLoginItemSettings: vi.fn()
  }
}))

import { AppController } from '../src/main/appController'
import type { ConfigStore } from '../src/main/storage'

const id = '20ef7cc1-7b98-4780-b3a5-4fd82456ae77'
const oldConfig = { id, displayName: 'Old', providerKind: 'genericHTTP' as const, apiEndpoint: 'https://old.test/usage', isEnabled: true }

function store(): ConfigStore {
  return {
    loadConfigFile: vi.fn(async () => ({ version: 1 as const, configs: [oldConfig] })),
    codexExecutable: vi.fn(async () => undefined),
    vaultAvailable: vi.fn(() => true),
    upsertProvider: vi.fn(async () => undefined),
    deleteProvider: vi.fn(async () => undefined),
    loadBearerToken: vi.fn(async () => '')
  } as unknown as ConfigStore
}

describe('provider bearer contract', () => {
  it('rejects implicit token retention across endpoint origins', async () => {
    const value = store()
    const controller = new AppController(value)
    await controller.initialize()
    await expect(controller.upsert({ config: { ...oldConfig, apiEndpoint: 'https://new.test/usage' }, bearerTokenAction: 'keep' })).rejects.toThrow('requires replacing or clearing')
    expect(value.upsertProvider).not.toHaveBeenCalled()
  })

  it('allows keep only for the same origin and explicit replace/clear across origins', async () => {
    const value = store()
    const controller = new AppController(value)
    await controller.initialize()
    await controller.upsert({ config: { ...oldConfig, apiEndpoint: 'https://old.test/other' }, bearerTokenAction: 'keep' })
    await controller.upsert({ config: { ...oldConfig, apiEndpoint: 'https://new.test/usage' }, bearerTokenAction: 'replace', bearerToken: 'new-secret' })
    await controller.upsert({ config: { ...oldConfig, apiEndpoint: 'http://elsewhere.test/usage' }, bearerTokenAction: 'clear' })
    expect(value.upsertProvider).toHaveBeenNthCalledWith(1, expect.objectContaining({ apiEndpoint: 'https://old.test/other' }), 'keep', undefined)
    expect(value.upsertProvider).toHaveBeenNthCalledWith(2, expect.objectContaining({ apiEndpoint: 'https://new.test/usage' }), 'replace', 'new-secret')
    expect(value.upsertProvider).toHaveBeenNthCalledWith(3, expect.objectContaining({ apiEndpoint: 'http://elsewhere.test/usage' }), 'clear', undefined)
  })
})
