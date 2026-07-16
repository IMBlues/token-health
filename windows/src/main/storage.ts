import { mkdir, readFile, rename, rm, writeFile } from 'node:fs/promises'
import { dirname, join } from 'node:path'
import { z } from 'zod'
import { serviceConfigSchema, type BearerTokenAction, type ServiceConfig } from '../shared/contracts'

const configFileSchema = z.object({
  version: z.literal(1),
  configs: z.array(serviceConfigSchema),
  codexExecutable: z.string().optional()
}).strict()

const vaultFileSchema = z.object({
  version: z.literal(1),
  secrets: z.record(z.string().uuid(), z.string())
}).strict()

export interface EncryptionProvider {
  isAvailable(): boolean
  encrypt(value: string): Buffer
  decrypt(value: Buffer): string
}

type ConfigFile = z.infer<typeof configFileSchema>
type VaultFile = z.infer<typeof vaultFileSchema>

export interface StorageFileOperations {
  mkdir: typeof mkdir
  readFile: typeof readFile
  rename: typeof rename
  rm: typeof rm
  writeFile: typeof writeFile
}

const defaultOperations: StorageFileOperations = { mkdir, readFile, rename, rm, writeFile }

function isMissing(error: unknown): boolean {
  return (error as NodeJS.ErrnoException).code === 'ENOENT'
}

async function atomicJSONWrite(
  path: string,
  value: unknown,
  operations: StorageFileOperations,
  platform: NodeJS.Platform
): Promise<void> {
  await operations.mkdir(dirname(path), { recursive: true })
  const nonce = `${process.pid}.${Date.now()}.${Math.random().toString(16).slice(2)}`
  const temporary = `${path}.${nonce}.tmp`
  const backup = `${path}.${nonce}.bak`
  await operations.writeFile(temporary, `${JSON.stringify(value, null, 2)}\n`, { encoding: 'utf8', mode: 0o600 })
  let backupCreated = false
  let preserveBackup = false
  try {
    try {
      await operations.rename(temporary, path)
      return
    } catch (error) {
      if (platform !== 'win32') throw error
    }

    try {
      await operations.rename(path, backup)
      backupCreated = true
    } catch (error) {
      if (!isMissing(error)) throw error
    }

    try {
      await operations.rename(temporary, path)
    } catch (error) {
      if (backupCreated) {
        try {
          await operations.rename(backup, path)
          backupCreated = false
        } catch (restoreError) {
          preserveBackup = true
          throw new Error(`Atomic write failed and backup restoration failed; recovery copy remains at ${backup}`, { cause: new AggregateError([error, restoreError]) })
        }
      }
      throw error
    }

    if (backupCreated) {
      await operations.rm(backup, { force: true })
      backupCreated = false
    }
  } finally {
    await operations.rm(temporary, { force: true })
    if (backupCreated && !preserveBackup) await operations.rm(backup, { force: true })
  }
}

async function loadJSON<T>(
  path: string,
  schema: { parse(input: unknown): T },
  fallback: T,
  operations: StorageFileOperations
): Promise<T> {
  try {
    return schema.parse(JSON.parse(await operations.readFile(path, 'utf8')))
  } catch (error) {
    if (isMissing(error)) return fallback
    throw new Error(`Invalid persisted data: ${path}`, { cause: error })
  }
}

export class ConfigStore {
  readonly configPath: string
  readonly vaultPath: string

  constructor(
    userDataPath: string,
    private readonly encryption: EncryptionProvider,
    private readonly operations: StorageFileOperations = defaultOperations,
    private readonly platform: NodeJS.Platform = process.platform
  ) {
    this.configPath = join(userDataPath, 'config.v1.json')
    this.vaultPath = join(userDataPath, 'secrets.v1.vault.json')
  }

  vaultAvailable(): boolean {
    return this.encryption.isAvailable()
  }

  async loadConfigFile(): Promise<ConfigFile> {
    return loadJSON(this.configPath, configFileSchema, { version: 1, configs: [] }, this.operations)
  }

  private async loadVaultFile(): Promise<VaultFile> {
    return loadJSON(this.vaultPath, vaultFileSchema, { version: 1, secrets: {} }, this.operations)
  }

  private async writeConfig(file: ConfigFile): Promise<void> {
    await atomicJSONWrite(this.configPath, configFileSchema.parse(file), this.operations, this.platform)
  }

  private async writeVault(file: VaultFile): Promise<void> {
    await atomicJSONWrite(this.vaultPath, vaultFileSchema.parse(file), this.operations, this.platform)
  }

  async saveConfigs(configs: ServiceConfig[]): Promise<void> {
    const previous = await this.loadConfigFile()
    await this.writeConfig({ ...previous, configs })
  }

  async codexExecutable(): Promise<string | undefined> {
    return (await this.loadConfigFile()).codexExecutable
  }

  async saveCodexExecutable(path: string | undefined): Promise<void> {
    const previous = await this.loadConfigFile()
    await this.writeConfig({ ...previous, codexExecutable: path })
  }

  async loadBearerToken(id: string): Promise<string> {
    const vault = await this.loadVaultFile()
    const encrypted = vault.secrets[id]
    // Public Generic HTTP endpoints remain usable when DPAPI is unavailable.
    if (!encrypted) return ''
    if (!this.encryption.isAvailable()) throw new Error('Windows credential encryption is unavailable for the stored bearer token')
    try {
      return this.encryption.decrypt(Buffer.from(encrypted, 'base64'))
    } catch (error) {
      throw new Error('Stored bearer token could not be decrypted', { cause: error })
    }
  }

  async upsertProvider(config: ServiceConfig, action: BearerTokenAction, token?: string): Promise<void> {
    const previousConfig = await this.loadConfigFile()
    const previousVault = await this.loadVaultFile()
    const nextConfigs = [...previousConfig.configs]
    const index = nextConfigs.findIndex((item) => item.id === config.id)
    if (index >= 0) nextConfigs[index] = config
    else nextConfigs.push(config)

    const nextVault: VaultFile = { version: 1, secrets: { ...previousVault.secrets } }
    let vaultChanged = false
    if (action === 'replace') {
      if (!this.encryption.isAvailable()) throw new Error('Windows credential encryption is unavailable; token was not saved')
      nextVault.secrets[config.id] = this.encryption.encrypt(token?.trim() ?? '').toString('base64')
      vaultChanged = true
    } else if (action === 'clear' && nextVault.secrets[config.id]) {
      delete nextVault.secrets[config.id]
      vaultChanged = true
    }

    if (vaultChanged) await this.writeVault(nextVault)
    try {
      await this.writeConfig({ ...previousConfig, configs: nextConfigs })
    } catch (error) {
      if (vaultChanged) {
        try {
          await this.writeVault(previousVault)
        } catch (rollbackError) {
          throw new Error('Provider save failed and credential rollback failed', { cause: rollbackError })
        }
      }
      throw error
    }
  }

  async deleteProvider(id: string): Promise<void> {
    const previousConfig = await this.loadConfigFile()
    const previousVault = await this.loadVaultFile()
    const nextConfig = { ...previousConfig, configs: previousConfig.configs.filter((config) => config.id !== id) }
    const nextVault: VaultFile = { version: 1, secrets: { ...previousVault.secrets } }
    const vaultChanged = Boolean(nextVault.secrets[id])
    delete nextVault.secrets[id]

    if (vaultChanged) await this.writeVault(nextVault)
    try {
      await this.writeConfig(nextConfig)
    } catch (error) {
      if (vaultChanged) {
        try {
          await this.writeVault(previousVault)
        } catch (rollbackError) {
          throw new Error('Provider deletion failed and credential rollback failed', { cause: rollbackError })
        }
      }
      throw error
    }
  }
}
