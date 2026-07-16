import { access, readFile } from 'node:fs/promises'
import { constants } from 'node:fs'
import { resolve } from 'node:path'

const root = resolve(import.meta.dirname, '..')
const mainPath = resolve(root, 'out/main/index.js')
const preloadPath = resolve(root, 'out/preload/index.cjs')
const rendererPath = resolve(root, 'out/renderer/index.html')

await Promise.all([mainPath, preloadPath, rendererPath].map((path) => access(path, constants.R_OK)))
const [main, preload] = await Promise.all([readFile(mainPath, 'utf8'), readFile(preloadPath, 'utf8')])
if (!main.includes("../preload/index.cjs")) throw new Error('Main bundle does not reference the CommonJS preload')
if (/\bimport\s*(?:\(|[{*]|[A-Za-z_$])|\bexport\s+(?:default|[{*]|const|let|var|function|class)/m.test(preload)) {
  throw new Error('Preload bundle contains ESM syntax')
}
if (!/require\(["']electron["']\)/.test(preload)) throw new Error('Preload bundle is not CommonJS')
console.log('Build smoke passed: sandbox preload is CommonJS and referenced by main')
