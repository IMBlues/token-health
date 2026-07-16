import { describe, expect, it, vi } from 'vitest'

vi.mock('electron', () => ({
  dialog: { showOpenDialog: vi.fn() },
  ipcMain: { handle: vi.fn(), removeHandler: vi.fn() }
}))

import { allowedIPCChannels, ipcChannels } from '../src/shared/contracts'
import { assertTrustedSender, registerIPC } from '../src/main/ipc'
import type { AppController } from '../src/main/appController'
import type { IpcMainInvokeEvent } from 'electron'

function event(url: string, subframe = false): IpcMainInvokeEvent {
  const mainFrame = { url }
  const senderFrame = subframe ? { url } : mainFrame
  return { senderFrame, sender: { mainFrame } } as unknown as IpcMainInvokeEvent
}

describe('IPC capability boundary', () => {
  it('exposes only narrow application operations', () => {
    expect(allowedIPCChannels).toEqual(Object.values(ipcChannels))
    expect(allowedIPCChannels).toEqual([
      'app:get-state', 'app:refresh', 'providers:upsert', 'providers:delete',
      'codex:select-executable', 'app:set-start-with-windows', 'app:show-settings'
    ])
    expect(allowedIPCChannels.join(' ')).not.toMatch(/fetch|command|shell|read-file|execute/)
  })

  it('validates production, development and subframe senders', () => {
    expect(() => assertTrustedSender(event('file:///C:/app/out/renderer/index.html'))).not.toThrow()
    expect(() => assertTrustedSender(event('https://localhost:5173/page'), 'https://localhost:5173')).not.toThrow()
    expect(() => assertTrustedSender(event('https://evil.test/renderer/index.html'), 'https://localhost:5173')).toThrow('Untrusted')
    expect(() => assertTrustedSender(event('file:///C:/app/out/renderer/index.html', true))).toThrow('Untrusted')
  })

  it('registers real handlers that enforce sender and input schemas', async () => {
    const handlers = new Map<string, (event: IpcMainInvokeEvent, input?: unknown) => unknown>()
    const ipc = {
      handle: vi.fn((channel: string, handler: (event: IpcMainInvokeEvent, input?: unknown) => unknown) => handlers.set(channel, handler)),
      removeHandler: vi.fn((channel: string) => handlers.delete(channel))
    }
    const state = { version: 1, configs: [], snapshots: [], refreshing: false, startWithWindows: false, vaultAvailable: false }
    const controller = {
      state: vi.fn(() => state), refresh: vi.fn(async () => state), upsert: vi.fn(async () => state),
      delete: vi.fn(async () => state), selectCodexExecutable: vi.fn(async () => state), setStartWithWindows: vi.fn(() => state)
    } as unknown as AppController
    const remove = registerIPC(controller, vi.fn(), { ipc, selectExecutable: async () => undefined })
    expect([...handlers.keys()]).toEqual(allowedIPCChannels)
    await expect(handlers.get(ipcChannels.getState)?.(event('https://evil.test'), {})).rejects.toThrow('Untrusted')
    await expect(handlers.get(ipcChannels.deleteProvider)?.(event('file:///app/renderer/index.html'), { id: 'bad' })).rejects.toThrow()
    expect(await handlers.get(ipcChannels.getState)?.(event('file:///app/renderer/index.html'), {})).toEqual(state)
    remove()
    expect(ipc.removeHandler).toHaveBeenCalledTimes(allowedIPCChannels.length)
  })
})
