import { z } from 'zod'

export const providerKindSchema = z.enum(['genericHTTP', 'codex'])
export type ProviderKind = z.infer<typeof providerKindSchema>

export const usageWindowSchema = z.enum(['fiveHours', 'week', 'tokenQuota'])
export type UsageWindow = z.infer<typeof usageWindowSchema>

export const serviceConfigSchema = z.object({
  id: z.string().uuid(),
  displayName: z.string().trim().min(1).max(80),
  providerKind: providerKindSchema,
  apiEndpoint: z.string().trim().max(2048).default(''),
  isEnabled: z.boolean().default(true)
}).strict().superRefine((value, context) => {
  if (value.providerKind === 'genericHTTP') {
    try {
      const endpoint = new URL(value.apiEndpoint)
      if (!['http:', 'https:'].includes(endpoint.protocol) || !endpoint.hostname || endpoint.username || endpoint.password) throw new Error()
    } catch {
      context.addIssue({ code: z.ZodIssueCode.custom, path: ['apiEndpoint'], message: 'Generic endpoint must be an HTTP(S) URL without embedded credentials' })
    }
  }
  if (value.providerKind === 'codex' && value.apiEndpoint !== '') {
    context.addIssue({ code: z.ZodIssueCode.custom, path: ['apiEndpoint'], message: 'Codex does not use an endpoint' })
  }
})
export type ServiceConfig = z.infer<typeof serviceConfigSchema>

export const tokenUsageSchema = z.object({
  window: usageWindowSchema,
  label: z.string().max(120).optional(),
  used: z.number().int().safe(),
  limit: z.number().int().safe().optional(),
  resetAt: z.string().datetime().optional(),
  unit: z.string().max(20).optional()
}).strict()
export type TokenUsage = z.infer<typeof tokenUsageSchema>

export const snapshotStateSchema = z.enum(['ready', 'needsConfiguration', 'unavailable'])
export const providerSnapshotSchema = z.object({
  id: z.string().uuid(),
  serviceName: z.string(),
  providerTitle: z.string(),
  planName: z.string().optional(),
  usages: z.array(tokenUsageSchema),
  state: snapshotStateSchema,
  statusMessage: z.string(),
  updatedAt: z.string().datetime()
}).strict()
export type ProviderSnapshot = z.infer<typeof providerSnapshotSchema>

export const codexExecutableIdentitySchema = z.object({
  sha256: z.string().regex(/^[a-f0-9]{64}$/),
  size: z.number().int().nonnegative().safe(),
  mtimeMs: z.number().nonnegative().safe(),
  ctimeMs: z.number().nonnegative().safe()
}).strict()
export type CodexExecutableIdentity = z.infer<typeof codexExecutableIdentitySchema>

export const codexDiagnosticSchema = z.object({
  path: z.string().optional(),
  source: z.enum(['automatic', 'manual']).optional(),
  status: z.enum(['not-found', 'unsupported-platform', 'invalid-signature', 'unapproved-signer', 'trusted', 'changed', 'error']),
  signerSubject: z.string().optional(),
  signerThumbprint: z.string().optional(),
  signatureStatus: z.string().optional(),
  identity: codexExecutableIdentitySchema.optional(),
  message: z.string()
}).strict()
export type CodexDiagnostic = z.infer<typeof codexDiagnosticSchema>

export const appStateSchema = z.object({
  version: z.literal(1),
  configs: z.array(serviceConfigSchema),
  snapshots: z.array(providerSnapshotSchema),
  refreshing: z.boolean(),
  startWithWindows: z.boolean(),
  vaultAvailable: z.boolean(),
  codexDiagnostic: codexDiagnosticSchema.optional()
}).strict()
export type AppState = z.infer<typeof appStateSchema>

export const bearerTokenActionSchema = z.enum(['keep', 'replace', 'clear'])
export type BearerTokenAction = z.infer<typeof bearerTokenActionSchema>

export const upsertProviderInputSchema = z.object({
  config: serviceConfigSchema,
  bearerTokenAction: bearerTokenActionSchema,
  bearerToken: z.string().max(16_384).optional()
}).strict().superRefine((value, context) => {
  if (value.config.providerKind !== 'genericHTTP' && (value.bearerTokenAction !== 'clear' || value.bearerToken !== undefined)) {
    context.addIssue({ code: z.ZodIssueCode.custom, path: ['bearerTokenAction'], message: 'Codex cannot retain or set a bearer token' })
  }
  if (value.bearerTokenAction === 'replace' && !value.bearerToken?.trim()) {
    context.addIssue({ code: z.ZodIssueCode.custom, path: ['bearerToken'], message: 'Replacing a bearer token requires a non-empty token' })
  }
  if (value.bearerTokenAction !== 'replace' && value.bearerToken !== undefined) {
    context.addIssue({ code: z.ZodIssueCode.custom, path: ['bearerToken'], message: 'A bearer token is only accepted with replace' })
  }
})
export type UpsertProviderInput = z.infer<typeof upsertProviderInputSchema>

export const providerIdInputSchema = z.object({ id: z.string().uuid() }).strict()
export const setStartWithWindowsInputSchema = z.object({ enabled: z.boolean() }).strict()
export const emptyInputSchema = z.object({}).strict()

export const ipcChannels = {
  getState: 'app:get-state',
  refresh: 'app:refresh',
  upsertProvider: 'providers:upsert',
  deleteProvider: 'providers:delete',
  selectCodexExecutable: 'codex:select-executable',
  setStartWithWindows: 'app:set-start-with-windows',
  showSettings: 'app:show-settings'
} as const

export const allowedIPCChannels = Object.freeze(Object.values(ipcChannels))

export interface TokenHealthAPI {
  getState(): Promise<AppState>
  refresh(): Promise<AppState>
  upsertProvider(input: UpsertProviderInput): Promise<AppState>
  deleteProvider(input: z.infer<typeof providerIdInputSchema>): Promise<AppState>
  selectCodexExecutable(): Promise<AppState>
  setStartWithWindows(input: z.infer<typeof setStartWithWindowsInputSchema>): Promise<AppState>
  showSettings(): Promise<void>
  subscribe(listener: (state: AppState) => void): () => void
  onShowSettings(listener: () => void): () => void
}
