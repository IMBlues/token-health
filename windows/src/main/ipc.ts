import { dialog, ipcMain, type IpcMainInvokeEvent } from 'electron'
import {
  allowedIPCChannels, emptyInputSchema, ipcChannels, providerIdInputSchema, setStartWithWindowsInputSchema, upsertProviderInputSchema
} from '../shared/contracts'
import type { AppController } from './appController'

interface IPCRegistrar {
  handle(channel: string, listener: (event: IpcMainInvokeEvent, input?: unknown) => unknown): void
  removeHandler(channel: string): void
}

export function assertTrustedSender(event: IpcMainInvokeEvent, developmentOrigin?: string): void {
  if (!event.senderFrame || event.senderFrame !== event.sender.mainFrame) throw new Error('Untrusted IPC sender')
  const url = new URL(event.senderFrame.url)
  if (developmentOrigin && url.origin === developmentOrigin) return
  if (url.protocol !== 'file:' || url.host !== '' || !url.pathname.endsWith('/renderer/index.html')) throw new Error('Untrusted IPC sender')
}

export function registerIPC(
  controller: AppController,
  showSettings: () => void,
  options: { ipc?: IPCRegistrar; developmentOrigin?: string; selectExecutable?: () => Promise<string | undefined> } = {}
): () => void {
  const registrar = options.ipc ?? ipcMain
  const selectExecutable = options.selectExecutable ?? (async () => {
    const selection = await dialog.showOpenDialog({
      title: 'Select official Codex executable',
      properties: ['openFile'],
      filters: [{ name: 'Codex executable', extensions: ['exe'] }]
    })
    return selection.canceled || selection.filePaths.length !== 1 ? undefined : selection.filePaths[0]
  })
  const handle = <T>(channel: string, handler: (event: IpcMainInvokeEvent, input: unknown) => Promise<T> | T): void => {
    registrar.handle(channel, async (event, input = {}) => {
      assertTrustedSender(event, options.developmentOrigin)
      return handler(event, input)
    })
  }

  handle(ipcChannels.getState, (_event, input) => {
    emptyInputSchema.parse(input)
    return controller.state()
  })
  handle(ipcChannels.refresh, async (_event, input) => {
    emptyInputSchema.parse(input)
    return controller.refresh()
  })
  handle(ipcChannels.upsertProvider, async (_event, input) => controller.upsert(upsertProviderInputSchema.parse(input)))
  handle(ipcChannels.deleteProvider, async (_event, input) => controller.delete(providerIdInputSchema.parse(input).id))
  handle(ipcChannels.selectCodexExecutable, async (_event, input) => {
    emptyInputSchema.parse(input)
    const path = await selectExecutable()
    return path ? controller.selectCodexExecutable(path) : controller.state()
  })
  handle(ipcChannels.setStartWithWindows, (_event, input) => controller.setStartWithWindows(setStartWithWindowsInputSchema.parse(input).enabled))
  handle(ipcChannels.showSettings, (_event, input) => {
    emptyInputSchema.parse(input)
    showSettings()
  })

  return () => allowedIPCChannels.forEach((channel) => registrar.removeHandler(channel))
}
