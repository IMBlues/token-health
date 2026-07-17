import { spawn } from 'node:child_process'
import { EventEmitter } from 'node:events'
import { mkdtemp, mkdir, rm, utimes, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import {
  APPROVED_CODEX_SIGNER_SUBJECTS, AUTHENTICODE_SCRIPT, CODEX_ARGUMENTS, CODEX_OUTBOUND_METHODS, CodexProcessManager,
  clearCodexCache, codexCandidatePaths, codexRequestData, fetchCodexUsage, mapCodexRateLimits, rateLimitsResponseSchema,
  reverifyCodexExecutable, runCodexRPC, verifyCodexExecutable, type SpawnedProcess
} from '../src/main/codex'
import type { CodexDiagnostic, CodexExecutableIdentity } from '../src/shared/contracts'

const fixture = resolve(process.cwd(), 'tests/fixtures/fake-codex.mjs')
const identity: CodexExecutableIdentity = { sha256: 'a'.repeat(64), size: 10, mtimeMs: 1, ctimeMs: 2 }
const config = { id: '20ef7cc1-7b98-4780-b3a5-4fd82456ae77', displayName: 'Codex', providerKind: 'codex' as const, apiEndpoint: '', isEnabled: true }

function fakeProcess(): SpawnedProcess {
  const fake = new EventEmitter() as unknown as SpawnedProcess
  fake.stdout = new EventEmitter() as NodeJS.ReadableStream
  fake.stdin = { write: () => true, on: () => undefined } as unknown as NodeJS.WritableStream
  fake.pid = 123
  fake.kill = vi.fn(() => true)
  return fake
}

beforeEach(() => clearCodexCache())

describe('Codex RPC and mapper', () => {
  it('uses only the read-only RPC allowlist and fixed args', () => {
    const messages = codexRequestData('test').trim().split('\n').map((line) => JSON.parse(line) as Record<string, unknown>)
    expect(messages.map((message) => message.method)).toEqual(CODEX_OUTBOUND_METHODS)
    expect(CODEX_ARGUMENTS).toEqual(['app-server', '--stdio', '--disable', 'plugins', '--disable', 'apps', '-c', 'analytics.enabled=false'])
    expect(messages.map((message) => Object.keys(message).sort())).toEqual([['id', 'method', 'params'], ['method'], ['id', 'method']])
    expect(codexRequestData('test')).not.toMatch(/login|logout|thread\/|fs\/|config\/|plugin\//)
  })

  it('uses a Node fake process, ignores notifications and filters response id', async () => {
    const response = await runCodexRPC(process.execPath, {
      timeoutMs: 3_000,
      spawnProcess: (executable) => spawn(executable, [fixture], { shell: false, stdio: ['pipe', 'pipe', 'ignore'] }) as unknown as SpawnedProcess
    })
    expect(response.rateLimits?.primary?.usedPercent).toBe(21)
    expect(response.rateLimits?.planType).toBe('plus')
  })

  it('maps main and named quota buckets and clamps percentages', () => {
    const response = {
      rateLimits: { limitId: 'codex', primary: { usedPercent: 130, windowDurationMins: 300, resetsAt: 1783665814 }, secondary: { usedPercent: -4, windowDurationMins: 10080 }, planType: 'pro' },
      rateLimitsByLimitId: { codex_spark: { limitName: 'Codex Spark', primary: { usedPercent: 7, windowDurationMins: 15 } } }
    }
    const mapped = mapCodexRateLimits(response)
    expect(mapped.planName).toBe('Pro')
    expect(mapped.usages.map((item) => item.used)).toEqual([100, 0, 7])
    expect(mapped.usages[2].label).toBe('Codex Spark · 15m')
  })

  it('accepts strict integer strings and rejects fractional, scientific and unsafe values', () => {
    const response = rateLimitsResponseSchema.parse({ rateLimits: { primary: { usedPercent: '-4' }, secondary: { usedPercent: '12' } } })
    expect(mapCodexRateLimits(response).usages.map((item) => item.used)).toEqual([0, 12])
    for (const usedPercent of [12.5, '12.5', '1e2', '0x10', Number.POSITIVE_INFINITY]) {
      expect(() => rateLimitsResponseSchema.parse({ rateLimits: { primary: { usedPercent } } })).toThrow()
    }
  })

  it('waits for injected termination on response, safety limit and timeout', async () => {
    const responseChild = fakeProcess()
    let release!: () => void
    const terminating = new Promise<void>((resolvePromise) => { release = resolvePromise })
    const responsePending = runCodexRPC('/fake/codex.exe', { spawnProcess: () => responseChild, terminateProcess: vi.fn(() => terminating) })
    ;(responseChild.stdout as EventEmitter).emit('data', Buffer.from('{"id":1,"result":{"rateLimits":null}}\n'))
    let resolved = false
    void responsePending.then(() => { resolved = true })
    await Promise.resolve()
    expect(resolved).toBe(false)
    release()
    await expect(responsePending).resolves.toMatchObject({ rateLimits: null })

    const oversized = fakeProcess()
    const oversizedPending = runCodexRPC('/fake/codex.exe', { spawnProcess: () => oversized, terminateProcess: async () => {} })
    ;(oversized.stdout as EventEmitter).emit('data', Buffer.alloc(1_048_577, 0x61))
    await expect(oversizedPending).rejects.toThrow('safety limit')

    const timedOut = fakeProcess()
    const terminate = vi.fn(async () => {})
    await expect(runCodexRPC('/fake/codex.exe', { timeoutMs: 5, spawnProcess: () => timedOut, terminateProcess: terminate })).rejects.toThrow('timed out')
    expect(terminate).toHaveBeenCalledWith(timedOut)
  })

  it('tracks, cancels, and rejects new active processes after shutdown', async () => {
    const manager = new CodexProcessManager()
    const child = fakeProcess()
    expect(manager.add(child)).toBe(true)
    const terminate = vi.fn(async () => {})
    await manager.cancelAll(terminate)
    expect(terminate).toHaveBeenCalledWith(child)
    expect(manager.size()).toBe(0)
    expect(manager.canStart()).toBe(false)
    const late = fakeProcess()
    await expect(runCodexRPC('/fake/codex.exe', { spawnProcess: () => late, processManager: manager, terminateProcess: terminate })).rejects.toThrow('shutting down')
    expect(terminate).toHaveBeenCalledWith(late)
  })
})

describe('Codex executable discovery', () => {
  it('enumerates versioned bin directories and prefers the newest codex.exe', async () => {
    const root = await mkdtemp(join(tmpdir(), 'token-health-codex-'))
    try {
      const local = join(root, 'LocalAppData')
      const bin = join(local, 'OpenAI', 'Codex', 'bin')
      const older = join(bin, '111aaa')
      const newer = join(bin, '222bbb')
      const withoutExe = join(bin, 'not-a-version')
      await mkdir(older, { recursive: true })
      await mkdir(newer, { recursive: true })
      await mkdir(withoutExe, { recursive: true })
      const olderExe = join(older, 'codex.exe')
      const newerExe = join(newer, 'codex.exe')
      await writeFile(olderExe, 'x')
      await writeFile(newerExe, 'x')
      await writeFile(join(withoutExe, 'codex-command-runner.exe'), 'x')
      await utimes(olderExe, new Date(1_000), new Date(1_000))
      await utimes(newerExe, new Date(2_000), new Date(2_000))

      const candidates = await codexCandidatePaths({ LOCALAPPDATA: local } as NodeJS.ProcessEnv)
      expect(candidates).toEqual([resolve(newerExe), resolve(olderExe)])
    } finally {
      await rm(root, { recursive: true, force: true })
    }
  })

  it('returns no candidates when the official bin directory is absent', async () => {
    const root = await mkdtemp(join(tmpdir(), 'token-health-codex-'))
    try {
      await expect(codexCandidatePaths({ LOCALAPPDATA: join(root, 'LocalAppData') } as NodeJS.ProcessEnv)).resolves.toEqual([])
    } finally {
      await rm(root, { recursive: true, force: true })
    }
  })
})

describe('Codex Authenticode and identity policy', () => {
  it('ships the exact reviewed official signer subject (RFC 2253)', () => {
    expect([...APPROVED_CODEX_SIGNER_SUBJECTS]).toEqual([
      'CN="OpenAI OpCo, LLC", O="OpenAI OpCo, LLC", L=San Francisco, S=California, C=US'
    ])
  })

  it('passes the exe path via environment variable, not fragile -Command args', () => {
    // Windows PowerShell 5.1 binds `-Command <script> <path>` arguments into $args unreliably,
    // so the path is supplied via an environment variable and the script reads it directly.
    expect(AUTHENTICODE_SCRIPT).toContain('$env:TOKEN_HEALTH_CODEXE')
    expect(AUTHENTICODE_SCRIPT).toContain('Get-AuthenticodeSignature')
    expect(AUTHENTICODE_SCRIPT).toContain('ConvertTo-Json')
    expect(AUTHENTICODE_SCRIPT).not.toContain('$args')
  })

  it('diagnoses an unapproved signer and binds trusted verification to identity', async () => {
    const subject = 'CN=OpenAI Test Signer, O=OpenAI'
    const runPowerShell = async () => JSON.stringify({ Status: 'Valid', SignerSubject: subject })
    const unapproved = await verifyCodexExecutable(process.execPath, { platform: 'win32', runPowerShell })
    expect(unapproved).toMatchObject({ status: 'unapproved-signer', signerSubject: subject })
    const trusted = await verifyCodexExecutable(process.execPath, {
      platform: 'win32', runPowerShell, signerAllowlist: new Set([subject]), identity: async () => identity
    })
    expect(trusted).toMatchObject({ status: 'trusted', identity })
  })

  it('refuses a changed executable during the immediate pre-spawn recheck', async () => {
    const diagnostic: CodexDiagnostic = { path: process.execPath, status: 'trusted', signatureStatus: 'Valid', signerSubject: [...APPROVED_CODEX_SIGNER_SUBJECTS][0], identity, message: 'trusted' }
    const result = await reverifyCodexExecutable(diagnostic)
    // Non-Windows test hosts cannot re-run Authenticode and must fail closed.
    expect(result.status).not.toBe('trusted')

    const runRPC = vi.fn(async () => ({ rateLimits: null }))
    const snapshot = await fetchCodexUsage(config, diagnostic, new Date(1_000), {
      verifyExecutable: async () => ({ ...diagnostic, status: 'changed', message: 'changed after approval' }),
      runRPC
    })
    expect(snapshot.statusMessage).toContain('changed after approval')
    expect(runRPC).not.toHaveBeenCalled()
  })

  it('caches both successful and failed queries for one minute', async () => {
    const diagnostic: CodexDiagnostic = { path: 'C:\\codex.exe', status: 'trusted', identity, message: 'trusted' }
    const runRPC = vi.fn(async () => ({ rateLimits: { primary: { usedPercent: 1 } } }))
    const verifyExecutable = async () => diagnostic
    await fetchCodexUsage(config, diagnostic, new Date(1_000), { verifyExecutable, runRPC })
    await fetchCodexUsage(config, diagnostic, new Date(2_000), { verifyExecutable, runRPC })
    expect(runRPC).toHaveBeenCalledTimes(1)

    clearCodexCache()
    const failing = vi.fn(async () => { throw new Error('failure') })
    await fetchCodexUsage(config, diagnostic, new Date(1_000), { verifyExecutable, runRPC: failing })
    const cached = await fetchCodexUsage(config, diagnostic, new Date(2_000), { verifyExecutable, runRPC: failing })
    expect(cached.statusMessage).toBe('failure')
    expect(failing).toHaveBeenCalledTimes(1)
  })
})
