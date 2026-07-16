import { app, BrowserWindow, Menu, nativeImage, safeStorage, session, Tray } from 'electron'
import { join } from 'node:path'
import { AppController } from './appController'
import { CodexProcessManager } from './codex'
import { registerIPC } from './ipc'
import { allowedRendererOrigin, isHiddenLaunch, shouldAllowRendererRequest } from './runtimePolicy'
import { ConfigStore, type EncryptionProvider } from './storage'

let mainWindow: BrowserWindow | undefined
let tray: Tray | undefined
let controller: AppController | undefined
let quitting = false
let removeIPC: (() => void) | undefined
let shutdownPromise: Promise<void> | undefined

const gotLock = app.requestSingleInstanceLock()
if (!gotLock) app.quit()

function showWindow(settings = false): void {
  if (!mainWindow) return
  mainWindow.show()
  mainWindow.focus()
  if (settings) mainWindow.webContents.send('navigate:settings')
}

function toggleWindow(): void {
  if (!mainWindow) return
  if (mainWindow.isVisible()) mainWindow.hide()
  else showWindow()
}

function createWindow(): BrowserWindow {
  const window = new BrowserWindow({
    width: 760,
    height: 700,
    minWidth: 620,
    minHeight: 520,
    show: false,
    autoHideMenuBar: true,
    title: 'Token Health',
    webPreferences: {
      preload: join(__dirname, '../preload/index.cjs'),
      contextIsolation: true,
      nodeIntegration: false,
      nodeIntegrationInWorker: false,
      nodeIntegrationInSubFrames: false,
      sandbox: true,
      webSecurity: true,
      webviewTag: false,
      navigateOnDragDrop: false
    }
  })
  window.webContents.setWindowOpenHandler(() => ({ action: 'deny' }))
  window.webContents.on('will-navigate', (event, url) => {
    const current = window.webContents.getURL()
    if (url !== current) event.preventDefault()
  })
  window.on('close', (event) => {
    if (!quitting) {
      event.preventDefault()
      window.hide()
    }
  })
  if (process.env.ELECTRON_RENDERER_URL) void window.loadURL(process.env.ELECTRON_RENDERER_URL)
  else void window.loadFile(join(__dirname, '../renderer/index.html'))
  return window
}

function createTray(): Tray {
  const iconPath = join(app.getAppPath(), 'build', 'icon.png')
  const image = nativeImage.createFromPath(iconPath).resize({ width: 16, height: 16 })
  const value = new Tray(image)
  value.setToolTip('Token Health')
  value.on('click', toggleWindow)
  const updateMenu = (): void => value.setContextMenu(Menu.buildFromTemplate([
    { label: 'Open', click: () => showWindow() },
    { label: 'Refresh', click: () => void controller?.refresh() },
    { label: 'Settings', click: () => showWindow(true) },
    { type: 'separator' },
    {
      label: 'Start with Windows', type: 'checkbox',
      checked: app.getLoginItemSettings().openAtLogin,
      click: (item) => { controller?.setStartWithWindows(item.checked); updateMenu() }
    },
    { type: 'separator' },
    { label: 'Quit', click: () => { quitting = true; app.quit() } }
  ]))
  value.on('right-click', updateMenu)
  updateMenu()
  return value
}

app.on('second-instance', () => showWindow())
app.on('window-all-closed', () => {})
app.on('before-quit', (event) => {
  quitting = true
  if (shutdownPromise) return
  event.preventDefault()
  shutdownPromise = (async () => {
    removeIPC?.()
    await controller?.dispose()
    tray?.destroy()
    app.exit(0)
  })()
})

if (gotLock) {
  void app.whenReady().then(async () => {
    if (process.platform !== 'win32' && !process.env.TOKEN_HEALTH_ALLOW_NON_WINDOWS) {
      // Development builds remain runnable on macOS, but packaged support is Windows-only.
    }
    session.defaultSession.setPermissionRequestHandler((_webContents, _permission, callback) => callback(false))
    session.defaultSession.setPermissionCheckHandler(() => false)
    const developmentOrigin = allowedRendererOrigin(process.env.ELECTRON_RENDERER_URL, app.isPackaged)
    session.defaultSession.webRequest.onBeforeRequest({ urls: ['*://*/*'] }, (details, callback) => {
      callback({ cancel: !shouldAllowRendererRequest(details.url, developmentOrigin) })
    })

    const encryption: EncryptionProvider = {
      isAvailable: () => process.platform === 'win32' && safeStorage.isEncryptionAvailable(),
      encrypt: (value) => safeStorage.encryptString(value),
      decrypt: (value) => safeStorage.decryptString(value)
    }
    controller = new AppController(new ConfigStore(app.getPath('userData'), encryption), new CodexProcessManager())
    await controller.initialize()
    mainWindow = createWindow()
    controller.setWindow(mainWindow)
    removeIPC = registerIPC(controller, () => showWindow(true), { developmentOrigin })
    tray = createTray()
    mainWindow.once('ready-to-show', () => {
      if (!isHiddenLaunch()) showWindow()
      if (process.env.TOKEN_HEALTH_SMOKE_TEST === '1') {
        setTimeout(() => { quitting = true; app.quit() }, 500)
      } else {
        void controller?.refresh()
      }
    })
  })
}
