import { app, type BrowserWindow } from 'electron'
import type { AppState, CodexDiagnostic, ProviderSnapshot, ServiceConfig, UpsertProviderInput } from '../shared/contracts'
import { appStateSchema, serviceConfigSchema } from '../shared/contracts'
import { discoverCodex, fetchCodexUsage, reverifyCodexExecutable, type CodexProcessManager } from './codex'
import { fetchGenericUsage } from './genericHttp'
import type { ConfigStore } from './storage'

export const REFRESH_INTERVAL_MS = 15 * 60 * 1000

export class AppController {
  private configs: ServiceConfig[] = []
  private snapshots = new Map<string, ProviderSnapshot>()
  private refreshing = false
  private diagnostic: CodexDiagnostic | undefined
  private refreshTimer: NodeJS.Timeout | undefined
  private window: BrowserWindow | undefined
  private disposed = false

  constructor(private readonly store: ConfigStore, private readonly codexProcesses?: CodexProcessManager) {}

  async initialize(): Promise<void> {
    this.configs = (await this.store.loadConfigFile()).configs
    const selected = await this.store.codexExecutable()
    this.diagnostic = await discoverCodex(selected)
    this.scheduleRefresh()
  }

  setWindow(window: BrowserWindow): void {
    this.window = window
  }

  state(): AppState {
    return appStateSchema.parse({
      version: 1,
      configs: this.configs,
      snapshots: [...this.snapshots.values()],
      refreshing: this.refreshing,
      startWithWindows: app.getLoginItemSettings().openAtLogin,
      vaultAvailable: this.store.vaultAvailable(),
      ...(this.diagnostic ? { codexDiagnostic: this.diagnostic } : {})
    })
  }

  private publish(): void {
    if (this.window && !this.window.isDestroyed()) this.window.webContents.send('state:changed', this.state())
  }

  async refresh(): Promise<AppState> {
    if (this.disposed || this.refreshing) return this.state()
    this.refreshing = true
    this.publish()
    try {
      if (this.configs.some((config) => config.providerKind === 'codex' && config.isEnabled)) {
        this.diagnostic = await discoverCodex(await this.store.codexExecutable())
      }
      for (const config of this.configs.filter((item) => item.isEnabled)) {
        let snapshot: ProviderSnapshot
        if (config.providerKind === 'genericHTTP') {
          try {
            const token = await this.store.loadBearerToken(config.id)
            snapshot = await fetchGenericUsage(config, token)
          } catch (error) {
            snapshot = {
              id: config.id, serviceName: config.displayName, providerTitle: 'Generic HTTP', usages: [], state: 'unavailable',
              statusMessage: error instanceof Error ? error.message : 'Credential vault unavailable', updatedAt: new Date().toISOString()
            }
          }
        } else {
          snapshot = await fetchCodexUsage(config, this.diagnostic ?? { status: 'not-found', message: 'Codex executable not found' }, new Date(), {
            processManager: this.codexProcesses,
            verifyExecutable: reverifyCodexExecutable
          })
        }
        this.snapshots.set(config.id, snapshot)
        this.publish()
      }
      return this.state()
    } finally {
      this.refreshing = false
      this.publish()
      this.scheduleRefresh()
    }
  }

  async upsert(input: UpsertProviderInput): Promise<AppState> {
    const config = serviceConfigSchema.parse(input.config)
    if (config.providerKind === 'codex' && this.configs.some((item) => item.providerKind === 'codex' && item.id !== config.id)) {
      throw new Error('Only one Codex provider is supported')
    }
    const previous = this.configs.find((item) => item.id === config.id)
    if (previous?.providerKind === 'genericHTTP' && config.providerKind === 'genericHTTP'
      && new URL(previous.apiEndpoint).origin !== new URL(config.apiEndpoint).origin
      && input.bearerTokenAction === 'keep') {
      throw new Error('Changing endpoint origin requires replacing or clearing the bearer token')
    }
    await this.store.upsertProvider(config, input.bearerTokenAction, input.bearerToken)
    const nextConfigs = [...this.configs]
    const index = nextConfigs.findIndex((item) => item.id === config.id)
    if (index >= 0) nextConfigs[index] = config
    else nextConfigs.push(config)
    this.configs = nextConfigs
    this.publish()
    return this.state()
  }

  async delete(id: string): Promise<AppState> {
    const nextConfigs = this.configs.filter((config) => config.id !== id)
    await this.store.deleteProvider(id)
    this.configs = nextConfigs
    this.snapshots.delete(id)
    this.publish()
    return this.state()
  }

  async selectCodexExecutable(path: string): Promise<AppState> {
    const diagnostic = await discoverCodex(path)
    await this.store.saveCodexExecutable(path)
    this.diagnostic = diagnostic
    this.publish()
    return this.state()
  }

  setStartWithWindows(enabled: boolean): AppState {
    app.setLoginItemSettings({ openAtLogin: enabled, args: ['--hidden'] })
    this.publish()
    return this.state()
  }

  async dispose(): Promise<void> {
    this.disposed = true
    if (this.refreshTimer) clearTimeout(this.refreshTimer)
    await this.codexProcesses?.cancelAll()
  }

  private scheduleRefresh(): void {
    if (this.disposed) return
    if (this.refreshTimer) clearTimeout(this.refreshTimer)
    this.refreshTimer = setTimeout(() => void this.refresh(), REFRESH_INTERVAL_MS)
    this.refreshTimer.unref()
  }
}
