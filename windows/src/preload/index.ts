import { contextBridge, ipcRenderer } from 'electron'
import { appStateSchema, ipcChannels, providerIdInputSchema, setStartWithWindowsInputSchema, upsertProviderInputSchema, type TokenHealthAPI } from '../shared/contracts'

const api: TokenHealthAPI = {
  getState: async () => appStateSchema.parse(await ipcRenderer.invoke(ipcChannels.getState, {})),
  refresh: async () => appStateSchema.parse(await ipcRenderer.invoke(ipcChannels.refresh, {})),
  upsertProvider: async (input) => appStateSchema.parse(await ipcRenderer.invoke(ipcChannels.upsertProvider, upsertProviderInputSchema.parse(input))),
  deleteProvider: async (input) => appStateSchema.parse(await ipcRenderer.invoke(ipcChannels.deleteProvider, providerIdInputSchema.parse(input))),
  selectCodexExecutable: async () => appStateSchema.parse(await ipcRenderer.invoke(ipcChannels.selectCodexExecutable, {})),
  setStartWithWindows: async (input) => appStateSchema.parse(await ipcRenderer.invoke(ipcChannels.setStartWithWindows, setStartWithWindowsInputSchema.parse(input))),
  showSettings: async () => { await ipcRenderer.invoke(ipcChannels.showSettings, {}) },
  subscribe: (listener) => {
    const handler = (_event: Electron.IpcRendererEvent, value: unknown): void => listener(appStateSchema.parse(value))
    ipcRenderer.on('state:changed', handler)
    return () => ipcRenderer.removeListener('state:changed', handler)
  },
  onShowSettings: (listener) => {
    const handler = (): void => listener()
    ipcRenderer.on('navigate:settings', handler)
    return () => ipcRenderer.removeListener('navigate:settings', handler)
  }
}

contextBridge.exposeInMainWorld('tokenHealth', Object.freeze(api))
