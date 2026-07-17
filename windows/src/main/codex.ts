import { spawn, type ChildProcessWithoutNullStreams } from 'node:child_process'
import { createHash } from 'node:crypto'
import { createReadStream } from 'node:fs'
import { access, readdir, stat } from 'node:fs/promises'
import { constants as fsConstants } from 'node:fs'
import { join, resolve } from 'node:path'
import { z } from 'zod'
import type { CodexDiagnostic, CodexExecutableIdentity, ProviderSnapshot, ServiceConfig, TokenUsage } from '../shared/contracts'

export const CODEX_ARGUMENTS = ['app-server', '--stdio', '--disable', 'plugins', '--disable', 'apps', '-c', 'analytics.enabled=false'] as const
export const CODEX_OUTBOUND_METHODS = ['initialize', 'initialized', 'account/rateLimits/read'] as const
export const CODEX_RESPONSE_ID = 1
export const CODEX_MAX_LINE_BYTES = 1_048_576
export const CODEX_MAX_OUTPUT_BYTES = 2_097_152
export const CODEX_TIMEOUT_MS = 30_000
export const CODEX_CACHE_MS = 60_000

// Exact leaf signer subject (RFC 2253, as returned by PowerShell X509Certificate2.Subject)
// verified on the official OpenAI.Codex MSIX (codex-cli 0.144.5) on 2026-07-16.
// Keep exact matching and Authenticode Status=Valid; never use substring/wildcard matching.
export const APPROVED_CODEX_SIGNER_SUBJECTS = new Set<string>([
  'CN="OpenAI OpCo, LLC", O="OpenAI OpCo, LLC", L=San Francisco, S=California, C=US'
])

const strictInteger = z.union([z.number(), z.string()]).transform((value, context) => {
  if (typeof value === 'string' && !/^-?\d+$/.test(value)) {
    context.addIssue({ code: z.ZodIssueCode.custom, message: 'Expected a base-10 integer string' })
    return z.NEVER
  }
  const number = typeof value === 'number' ? value : Number(value)
  if (!Number.isSafeInteger(number)) {
    context.addIssue({ code: z.ZodIssueCode.custom, message: 'Expected a safe integer' })
    return z.NEVER
  }
  return number
})

const windowSchema = z.object({
  usedPercent: strictInteger,
  windowDurationMins: strictInteger.optional().nullable(),
  resetsAt: strictInteger.optional().nullable()
}).passthrough()

const limitSchema = z.object({
  limitId: z.string().optional().nullable(),
  limitName: z.string().optional().nullable(),
  primary: windowSchema.optional().nullable(),
  secondary: windowSchema.optional().nullable(),
  planType: z.string().optional().nullable(),
  rateLimitReachedType: z.string().optional().nullable()
}).passthrough()

export const rateLimitsResponseSchema = z.object({
  rateLimits: limitSchema.optional().nullable(),
  rateLimitsByLimitId: z.record(limitSchema).optional().nullable()
}).passthrough()
export type CodexRateLimitsResponse = z.infer<typeof rateLimitsResponseSchema>

const rpcResponseSchema = z.object({
  id: z.literal(CODEX_RESPONSE_ID),
  result: rateLimitsResponseSchema.optional(),
  error: z.unknown().optional()
}).passthrough()

export function codexRequestData(version: string): string {
  return [
    { method: CODEX_OUTBOUND_METHODS[0], id: 0, params: { clientInfo: { name: 'token_health', version } } },
    { method: CODEX_OUTBOUND_METHODS[1] },
    { method: CODEX_OUTBOUND_METHODS[2], id: CODEX_RESPONSE_ID }
  ].map((message) => JSON.stringify(message)).join('\n') + '\n'
}

interface LimitWindow { usedPercent: number; windowDurationMins?: number | null; resetsAt?: number | null }
type LimitSnapshot = z.infer<typeof limitSchema>

function durationDescriptor(minutes: number | null | undefined, fallback: TokenUsage['window'], fallbackLabel: string): { window: TokenUsage['window']; label?: string } {
  if (minutes === 300) return { window: 'fiveHours' }
  if (minutes === 10_080) return { window: 'week' }
  if (!minutes || minutes <= 0) return { window: fallback, label: fallbackLabel }
  if (minutes % 10_080 === 0) return { window: fallback, label: `${minutes / 10_080}w` }
  if (minutes % 1_440 === 0) return { window: fallback, label: `${minutes / 1_440}d` }
  if (minutes % 60 === 0) return { window: fallback, label: `${minutes / 60}h` }
  return { window: fallback, label: `${minutes}m` }
}

function mapWindow(value: LimitWindow, fallback: TokenUsage['window'], fallbackLabel: string, prefix?: string): TokenUsage {
  const descriptor = durationDescriptor(value.windowDurationMins, fallback, fallbackLabel)
  const baseLabel = descriptor.label
  const label = prefix ? `${prefix} · ${baseLabel ?? (descriptor.window === 'fiveHours' ? '5h' : 'Week')}` : baseLabel
  const reset = value.resetsAt && value.resetsAt > 0 ? new Date(value.resetsAt * 1000).toISOString() : undefined
  return {
    window: descriptor.window,
    ...(label ? { label } : {}),
    used: Math.min(Math.max(value.usedPercent, 0), 100),
    limit: 100,
    ...(reset ? { resetAt: reset } : {}),
    unit: '%'
  }
}

function mapSnapshot(snapshot: LimitSnapshot, prefix?: string): TokenUsage[] {
  return [
    ...(snapshot.primary ? [mapWindow(snapshot.primary, 'fiveHours', 'Primary', prefix)] : []),
    ...(snapshot.secondary ? [mapWindow(snapshot.secondary, 'week', 'Secondary', prefix)] : [])
  ]
}

function planDisplayName(raw: string | null | undefined): string | undefined {
  if (!raw || raw === 'unknown') return undefined
  if (raw === 'prolite') return 'Pro Lite'
  if (raw === 'self_serve_business_usage_based') return 'Business'
  if (raw === 'enterprise_cbp_usage_based') return 'Enterprise'
  return raw.split('_').map((word) => word.charAt(0).toUpperCase() + word.slice(1)).join(' ')
}

export function mapCodexRateLimits(response: CodexRateLimitsResponse): { planName?: string; usages: TokenUsage[]; statusMessage: string } {
  const buckets = response.rateLimitsByLimitId ?? {}
  let mainId: string | undefined
  let main: LimitSnapshot | undefined
  let mainPrefix: string | undefined
  if (buckets.codex) {
    mainId = 'codex'; main = buckets.codex
  } else if (response.rateLimits) {
    mainId = response.rateLimits.limitId ?? undefined; main = response.rateLimits
  } else {
    const first = Object.entries(buckets).sort(([left], [right]) => left.localeCompare(right))[0]
    if (first) {
      mainId = first[0]; main = first[1]; mainPrefix = first[1].limitName?.trim() || first[0]
    }
  }
  if (!main) return { usages: [], statusMessage: 'Codex quota unavailable' }
  const usages = mapSnapshot(main, mainPrefix)
  for (const [id, bucket] of Object.entries(buckets).sort(([left], [right]) => left.localeCompare(right))) {
    if (id === mainId) continue
    usages.push(...mapSnapshot(bucket, bucket.limitName?.trim() || id))
  }
  const planName = planDisplayName(main.planType)
  return {
    ...(planName ? { planName } : {}), usages,
    statusMessage: main.rateLimitReachedType ? 'Codex quota reached' : 'Read-only Codex quota'
  }
}

export interface SpawnedProcess {
  stdout: NodeJS.ReadableStream
  stdin: NodeJS.WritableStream
  pid?: number
  once(event: 'error' | 'exit', listener: (...args: unknown[]) => void): this
  kill(signal?: NodeJS.Signals): boolean
}
export type SpawnProcess = (executable: string, args: readonly string[]) => SpawnedProcess
export type TerminateProcess = (child: SpawnedProcess) => Promise<void>

export class CodexProcessManager {
  private readonly active = new Set<SpawnedProcess>()
  private closed = false

  canStart(): boolean { return !this.closed }
  add(child: SpawnedProcess): boolean {
    if (this.closed) return false
    this.active.add(child)
    return true
  }
  delete(child: SpawnedProcess): void { this.active.delete(child) }
  size(): number { return this.active.size }

  async cancelAll(terminate: TerminateProcess = terminateProcessTree): Promise<void> {
    this.closed = true
    await Promise.all([...this.active].map(async (child) => {
      await terminate(child)
      this.active.delete(child)
    }))
  }
}

export async function terminateProcessTree(child: SpawnedProcess): Promise<void> {
  if (!child.pid) return
  if (process.platform === 'win32') {
    const taskkill = join(process.env.SystemRoot ?? 'C:\\Windows', 'System32', 'taskkill.exe')
    await new Promise<void>((done) => {
      const killer = spawn(taskkill, ['/PID', String(child.pid), '/T', '/F'], { shell: false, windowsHide: true, stdio: 'ignore' })
      killer.once('exit', () => done())
      killer.once('error', () => done())
    })
  } else {
    child.kill('SIGTERM')
    await new Promise<void>((done) => setTimeout(done, 100))
    child.kill('SIGKILL')
  }
}

export async function runCodexRPC(executable: string, options: {
  timeoutMs?: number
  version?: string
  spawnProcess?: SpawnProcess
  terminateProcess?: TerminateProcess
  processManager?: CodexProcessManager
} = {}): Promise<CodexRateLimitsResponse> {
  const spawnProcess = options.spawnProcess ?? ((file, args) => spawn(file, [...args], {
    shell: false, windowsHide: true, stdio: ['pipe', 'pipe', 'ignore'], cwd: process.env.USERPROFILE ?? process.cwd()
  }) as unknown as ChildProcessWithoutNullStreams)
  const child = spawnProcess(executable, CODEX_ARGUMENTS)
  if (options.processManager && !options.processManager.add(child)) {
    await (options.terminateProcess ?? terminateProcessTree)(child)
    throw new Error('Codex quota reader is shutting down')
  }
  return new Promise((resolvePromise, rejectPromise) => {
    let buffer = Buffer.alloc(0)
    let total = 0
    let settled = false
    const timer = setTimeout(() => void finish(new Error('Codex quota request timed out')), options.timeoutMs ?? CODEX_TIMEOUT_MS)
    async function finish(error?: Error, value?: CodexRateLimitsResponse): Promise<void> {
      if (settled) return
      settled = true
      clearTimeout(timer)
      try {
        await (options.terminateProcess ?? terminateProcessTree)(child)
      } catch {
        if (!error) error = new Error('Codex quota reader could not be terminated safely')
      } finally {
        options.processManager?.delete(child)
      }
      if (error) rejectPromise(error)
      else resolvePromise(value as CodexRateLimitsResponse)
    }
    child.once('error', () => void finish(new Error('Codex quota reader could not start')))
    child.once('exit', () => void finish(new Error('Codex quota reader exited before responding')))
    child.stdout.on('data', (chunk: Buffer) => {
      total += chunk.byteLength
      buffer = Buffer.concat([buffer, chunk])
      if (total > CODEX_MAX_OUTPUT_BYTES || buffer.byteLength > CODEX_MAX_LINE_BYTES) {
        void finish(new Error('Codex quota response exceeded the safety limit'))
        return
      }
      let newline: number
      while ((newline = buffer.indexOf(0x0a)) >= 0) {
        const line = buffer.subarray(0, newline)
        buffer = buffer.subarray(newline + 1)
        if (line.byteLength > CODEX_MAX_LINE_BYTES) {
          void finish(new Error('Codex quota response exceeded the safety limit'))
          return
        }
        try {
          const envelope = JSON.parse(line.toString('utf8')) as { id?: unknown }
          if (envelope.id !== CODEX_RESPONSE_ID) continue
          const parsed = rpcResponseSchema.parse(envelope)
          if (parsed.error || !parsed.result) throw new Error('Codex rejected the quota request')
          void finish(undefined, parsed.result)
        } catch (error) {
          void finish(error instanceof Error ? error : new Error('Codex returned an unsupported quota response'))
        }
      }
    })
    child.stdin.on?.('error', () => void finish(new Error('Codex quota reader could not accept the request')))
    child.stdin.write(codexRequestData(options.version ?? '0.1.0'), (error) => {
      if (error) void finish(new Error('Codex quota reader could not accept the request'))
    })
  })
}

// Official desktop install layout, verified on the OpenAI.Codex MSIX (codex-cli 0.144.5):
//   %LOCALAPPDATA%\OpenAI\Codex\bin\<version-hash>\codex.exe
// Each update creates a new <version-hash> directory, so enumerate them and prefer the newest.
async function enumerateVersionedCodexBin(binRoot: string): Promise<string[]> {
  let entries
  try {
    entries = await readdir(binRoot, { withFileTypes: true })
  } catch {
    return []
  }
  const candidates: { path: string; mtimeMs: number }[] = []
  for (const entry of entries) {
    if (!entry.isDirectory()) continue
    const executable = join(binRoot, entry.name, 'codex.exe')
    try {
      const info = await stat(executable)
      if (info.isFile()) candidates.push({ path: executable, mtimeMs: info.mtimeMs })
    } catch {
      continue
    }
  }
  candidates.sort((left, right) => right.mtimeMs - left.mtimeMs)
  return candidates.map((candidate) => resolve(candidate.path))
}

export async function codexCandidatePaths(environment: NodeJS.ProcessEnv = process.env): Promise<string[]> {
  const candidates: string[] = []
  const local = environment.LOCALAPPDATA
  if (local) {
    candidates.push(...await enumerateVersionedCodexBin(join(local, 'OpenAI', 'Codex', 'bin')))
  }
  return candidates
}

// The executable path is passed via the TOKEN_HEALTH_CODEXE environment variable rather than
// as a -Command argument, because argument binding into $args is unreliable on Windows
// PowerShell 5.1. stderr is captured by captureProcess so the real failure is surfaced.
export const AUTHENTICODE_SCRIPT = [
  '[Console]::OutputEncoding = [System.Text.Encoding]::UTF8',
  "$ErrorActionPreference='Stop'",
  'try {',
  '  $signature = Get-AuthenticodeSignature -LiteralPath $env:TOKEN_HEALTH_CODEXE',
  '  $cert = $signature.SignerCertificate',
  '  $result = [pscustomobject]@{ Status = $signature.Status.ToString(); SignerSubject = $null; SignerThumbprint = $null; SignerIssuer = $null }',
  '  if ($cert) { $result.SignerSubject = $cert.Subject; $result.SignerThumbprint = $cert.Thumbprint; $result.SignerIssuer = $cert.Issuer }',
  '  $result | ConvertTo-Json -Compress',
  '} catch {',
  '  Write-Error $_',
  '  exit 1',
  '}'
].join(';')

function hashFile(path: string): Promise<string> {
  return new Promise((resolvePromise, rejectPromise) => {
    const hash = createHash('sha256')
    const stream = createReadStream(path)
    stream.on('error', rejectPromise)
    stream.on('data', (chunk) => hash.update(chunk))
    stream.on('end', () => resolvePromise(hash.digest('hex')))
  })
}

export async function codexExecutableIdentity(path: string): Promise<CodexExecutableIdentity> {
  const before = await stat(path)
  if (!before.isFile()) throw new Error('Codex executable is not a regular file')
  const sha256 = await hashFile(path)
  const after = await stat(path)
  if (before.size !== after.size || before.mtimeMs !== after.mtimeMs || before.ctimeMs !== after.ctimeMs) {
    throw new Error('Codex executable changed while it was being verified')
  }
  return { sha256, size: after.size, mtimeMs: after.mtimeMs, ctimeMs: after.ctimeMs }
}

function sameIdentity(left: CodexExecutableIdentity, right: CodexExecutableIdentity): boolean {
  return left.sha256 === right.sha256 && left.size === right.size && left.mtimeMs === right.mtimeMs && left.ctimeMs === right.ctimeMs
}

export async function verifyCodexExecutable(path: string, options: {
  platform?: NodeJS.Platform
  signerAllowlist?: ReadonlySet<string>
  runPowerShell?: (executable: string, args: string[], env?: NodeJS.ProcessEnv) => Promise<string>
  identity?: (path: string) => Promise<CodexExecutableIdentity>
} = {}): Promise<CodexDiagnostic> {
  const platform = options.platform ?? process.platform
  if (platform !== 'win32') return { path, status: 'unsupported-platform', message: 'Authenticode verification requires Windows' }
  try {
    await access(path, fsConstants.X_OK)
    const powershell = join(process.env.SystemRoot ?? 'C:\\Windows', 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe')
    const args = ['-NoLogo', '-NoProfile', '-NonInteractive', '-Command', AUTHENTICODE_SCRIPT]
    const env = { ...process.env, TOKEN_HEALTH_CODEXE: path }
    const output = options.runPowerShell ? await options.runPowerShell(powershell, args, env) : await captureProcess(powershell, args, env)
    const result = z.object({
      Status: z.string(),
      SignerSubject: z.string().nullable(),
      SignerThumbprint: z.string().nullable().optional(),
      SignerIssuer: z.string().nullable().optional()
    }).parse(JSON.parse(output))
    const signer = {
      signatureStatus: result.Status,
      signerSubject: result.SignerSubject ?? undefined,
      signerThumbprint: result.SignerThumbprint ?? undefined
    }
    if (result.Status !== 'Valid') return { path, status: 'invalid-signature', ...signer, message: `Authenticode status is ${result.Status}` }
    const approved = options.signerAllowlist ?? APPROVED_CODEX_SIGNER_SUBJECTS
    if (!result.SignerSubject || !approved.has(result.SignerSubject)) {
      return { path, status: 'unapproved-signer', ...signer, message: 'Signature is valid, but signer is not yet approved by Token Health' }
    }
    const identity = await (options.identity ?? codexExecutableIdentity)(path)
    return { path, status: 'trusted', ...signer, identity, message: 'Official signer and executable identity approved' }
  } catch (error) {
    return { path, status: 'error', message: error instanceof Error ? error.message : 'Authenticode verification failed' }
  }
}

function captureProcess(executable: string, args: string[], env?: NodeJS.ProcessEnv): Promise<string> {
  return new Promise((resolvePromise, rejectPromise) => {
    const child = spawn(executable, args, { shell: false, windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'], env })
    const chunks: Buffer[] = []
    const errChunks: Buffer[] = []
    let total = 0
    let exceeded = false
    let settled = false
    const finish = (error?: Error, value?: string): void => {
      if (settled) return
      settled = true
      clearTimeout(timer)
      if (error) rejectPromise(error)
      else resolvePromise(value ?? '')
    }
    const timer = setTimeout(() => {
      child.kill()
      finish(new Error('PowerShell signature check timed out'))
    }, 10_000)
    child.stdout.on('data', (chunk: Buffer) => {
      total += chunk.byteLength
      if (total <= 64 * 1024) chunks.push(chunk)
      else {
        exceeded = true
        child.kill()
      }
    })
    child.stderr.on('data', (chunk: Buffer) => {
      if (Buffer.concat(errChunks).byteLength <= 64 * 1024) errChunks.push(chunk)
    })
    child.once('error', () => finish(new Error('PowerShell could not be started')))
    child.once('exit', (code) => {
      const detail = Buffer.concat(errChunks).toString('utf8').trim()
      if (exceeded) finish(new Error('PowerShell signature output exceeded the safety limit'))
      else if (code === 0) finish(undefined, Buffer.concat(chunks).toString('utf8'))
      else finish(new Error(detail ? `PowerShell signature check failed: ${detail}` : `PowerShell signature check failed (exit code ${code ?? 'unknown'})`))
    })
  })
}

export async function discoverCodex(manualPath?: string): Promise<CodexDiagnostic> {
  const candidates = manualPath ? [manualPath] : await codexCandidatePaths()
  let lastDiagnostic: CodexDiagnostic | undefined
  for (const candidate of candidates) {
    try {
      await access(candidate, fsConstants.X_OK)
    } catch {
      continue
    }
    const diagnostic = await verifyCodexExecutable(candidate)
    diagnostic.source = manualPath ? 'manual' : 'automatic'
    if (diagnostic.status === 'trusted') return diagnostic
    lastDiagnostic = diagnostic
  }
  return lastDiagnostic ?? { status: 'not-found', message: 'No Codex executable was found under %LOCALAPPDATA%\\OpenAI\\Codex\\bin' }
}

export async function reverifyCodexExecutable(diagnostic: CodexDiagnostic): Promise<CodexDiagnostic> {
  if (diagnostic.status !== 'trusted' || !diagnostic.path || !diagnostic.identity) {
    return { ...diagnostic, status: 'changed', message: 'Codex executable has no trusted identity to revalidate' }
  }
  const current = await verifyCodexExecutable(diagnostic.path)
  if (current.status !== 'trusted' || !current.identity) return current
  if (!sameIdentity(diagnostic.identity, current.identity)) {
    return { ...current, status: 'changed', message: 'Codex executable changed after approval; execution was refused' }
  }
  return current
}

interface CacheEntry { at: number; response?: CodexRateLimitsResponse; error?: Error }
const codexCache = new Map<string, CacheEntry>()
export function clearCodexCache(): void { codexCache.clear() }

export async function fetchCodexUsage(
  config: ServiceConfig,
  diagnostic: CodexDiagnostic,
  now = new Date(),
  options: {
    processManager?: CodexProcessManager
    verifyExecutable?: (diagnostic: CodexDiagnostic) => Promise<CodexDiagnostic>
    runRPC?: typeof runCodexRPC
  } = {}
): Promise<ProviderSnapshot> {
  if (diagnostic.status !== 'trusted' || !diagnostic.path) {
    return {
      id: config.id, serviceName: config.displayName, providerTitle: 'Codex', usages: [],
      state: 'needsConfiguration', statusMessage: diagnostic.message, updatedAt: now.toISOString()
    }
  }
  const cached = codexCache.get(diagnostic.path)
  try {
    let response: CodexRateLimitsResponse
    let updatedAt = now
    if (cached && now.getTime() - cached.at < CODEX_CACHE_MS) {
      if (cached.error) throw cached.error
      response = cached.response as CodexRateLimitsResponse
      updatedAt = new Date(cached.at)
    } else {
      try {
        const verified = await (options.verifyExecutable ?? reverifyCodexExecutable)(diagnostic)
        if (verified.status !== 'trusted' || !verified.path) throw new Error(verified.message)
        response = await (options.runRPC ?? runCodexRPC)(verified.path, { processManager: options.processManager })
        codexCache.set(diagnostic.path, { at: now.getTime(), response })
      } catch (error) {
        const failure = error instanceof Error ? error : new Error('Codex quota unavailable')
        codexCache.set(diagnostic.path, { at: now.getTime(), error: failure })
        throw failure
      }
    }
    const mapped = mapCodexRateLimits(response)
    return {
      id: config.id, serviceName: config.displayName, providerTitle: 'Codex',
      ...(mapped.planName ? { planName: mapped.planName } : {}), usages: mapped.usages,
      state: mapped.usages.length ? 'ready' : 'unavailable', statusMessage: mapped.statusMessage,
      updatedAt: updatedAt.toISOString()
    }
  } catch (error) {
    return {
      id: config.id, serviceName: config.displayName, providerTitle: 'Codex', usages: [], state: 'unavailable',
      statusMessage: error instanceof Error ? error.message : 'Codex quota unavailable', updatedAt: now.toISOString()
    }
  }
}
