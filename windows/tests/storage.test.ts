import { mkdtemp, readFile, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { ConfigStore, type EncryptionProvider, type StorageFileOperations } from '../src/main/storage'

const directories: string[] = []
const encryption: EncryptionProvider = {
  isAvailable: () => true,
  encrypt: (value) => Buffer.from(`encrypted:${value}`, 'utf8'),
  decrypt: (value) => value.toString('utf8').replace(/^encrypted:/, '')
}
const id = '20ef7cc1-7b98-4780-b3a5-4fd82456ae77'
const config = { id, displayName: 'Local', providerKind: 'genericHTTP' as const, apiEndpoint: 'http://localhost', isEnabled: true }

async function store(provider = encryption, operations?: StorageFileOperations, platform?: NodeJS.Platform): Promise<ConfigStore> {
  const directory = await mkdtemp(join(tmpdir(), 'token-health-'))
  directories.push(directory)
  return new ConfigStore(directory, provider, operations, platform)
}

afterEach(async () => { await Promise.all(directories.splice(0).map((path) => rm(path, { recursive: true, force: true }))) })

describe('versioned storage and vault', () => {
  it('persists config separately from encrypted secrets and clears explicitly', async () => {
    const value = await store()
    await value.upsertProvider(config, 'replace', 'top-secret')
    expect((await value.loadConfigFile()).configs).toEqual([config])
    expect(await value.loadBearerToken(config.id)).toBe('top-secret')
    expect(await readFile(value.configPath, 'utf8')).not.toContain('top-secret')
    expect(await readFile(value.vaultPath, 'utf8')).not.toContain('top-secret')
    await value.upsertProvider(config, 'clear')
    expect(await value.loadBearerToken(config.id)).toBe('')
  })

  it('allows a public endpoint without DPAPI but fails closed for a stored secret', async () => {
    const unavailable = { isAvailable: () => false, encrypt: () => { throw new Error() }, decrypt: () => { throw new Error() } }
    const publicStore = await store(unavailable)
    expect(await publicStore.loadBearerToken(id)).toBe('')
    await expect(publicStore.upsertProvider(config, 'replace', 'secret')).rejects.toThrow('unavailable')

    const value = await store()
    await value.upsertProvider(config, 'replace', 'secret')
    const unavailableStore = new ConfigStore(join(value.configPath, '..'), unavailable)
    await expect(unavailableStore.loadBearerToken(id)).rejects.toThrow('unavailable')
  })

  it('rolls the vault back when config persistence fails, avoiding orphan secrets', async () => {
    const value = await store()
    await value.upsertProvider(config, 'replace', 'old')
    const base = await import('node:fs/promises')
    let configRenameFailures = 2
    const operations: StorageFileOperations = {
      mkdir: base.mkdir, readFile: base.readFile, rm: base.rm, writeFile: base.writeFile,
      rename: vi.fn(async (from, to) => {
        if (String(to).endsWith('config.v1.json') && String(from).includes('.tmp') && configRenameFailures-- > 0) throw Object.assign(new Error('injected config write failure'), { code: 'EACCES' })
        return base.rename(from, to)
      }) as typeof base.rename
    }
    const failing = new ConfigStore(join(value.configPath, '..'), encryption, operations, 'win32')
    await expect(failing.upsertProvider({ ...config, displayName: 'Changed' }, 'replace', 'new')).rejects.toThrow('injected')
    expect(await value.loadBearerToken(id)).toBe('old')
    expect((await value.loadConfigFile()).configs[0].displayName).toBe('Local')
  })

  it('restores the Windows backup if replacing the destination fails', async () => {
    const value = await store()
    await value.saveConfigs([config])
    const base = await import('node:fs/promises')
    let targetAttempts = 0
    const operations: StorageFileOperations = {
      mkdir: base.mkdir, readFile: base.readFile, rm: base.rm, writeFile: base.writeFile,
      rename: vi.fn(async (from, to) => {
        if (String(to).endsWith('config.v1.json') && String(from).includes('.tmp') && ++targetAttempts <= 2) throw Object.assign(new Error('locked'), { code: 'EACCES' })
        return base.rename(from, to)
      }) as typeof base.rename
    }
    const failing = new ConfigStore(join(value.configPath, '..'), encryption, operations, 'win32')
    await expect(failing.saveConfigs([{ ...config, displayName: 'Lost' }])).rejects.toThrow('locked')
    expect((await value.loadConfigFile()).configs[0].displayName).toBe('Local')
  })
})
