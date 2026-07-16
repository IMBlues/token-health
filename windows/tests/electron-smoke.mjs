import { spawn } from 'node:child_process'
import { resolve } from 'node:path'

const root = resolve(import.meta.dirname, '..')
const electron = resolve(root, 'node_modules', '.bin', process.platform === 'win32' ? 'electron.cmd' : 'electron')
const child = spawn(electron, ['.'], {
  cwd: root,
  shell: process.platform === 'win32',
  windowsHide: true,
  stdio: ['ignore', 'pipe', 'pipe'],
  env: { ...process.env, TOKEN_HEALTH_SMOKE_TEST: '1', TOKEN_HEALTH_ALLOW_NON_WINDOWS: '1' }
})
let output = ''
child.stdout.on('data', (chunk) => { output += chunk.toString() })
child.stderr.on('data', (chunk) => { output += chunk.toString() })
const timer = setTimeout(() => {
  child.kill('SIGKILL')
}, 20_000)
const code = await new Promise((resolvePromise, rejectPromise) => {
  child.once('error', rejectPromise)
  child.once('exit', resolvePromise)
})
clearTimeout(timer)
if (code !== 0) throw new Error(`Electron smoke exited with ${String(code)}\n${output}`)
if (/Unable to load preload|preload.*error|SyntaxError|ERR_/i.test(output)) throw new Error(`Electron preload smoke failed\n${output}`)
console.log('Electron smoke passed')
