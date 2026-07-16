import { useEffect, useMemo, useState } from 'react'
import type { AppState, BearerTokenAction, ProviderKind, ServiceConfig, TokenUsage } from '../shared/contracts'
import { amountText, exactAmountText, resetText, usageRatio, usageTitle, usageTone } from '../shared/formatter'

const emptyState: AppState = { version: 1, configs: [], snapshots: [], refreshing: false, startWithWindows: false, vaultAvailable: false }

type Page = 'status' | 'settings'

function errorMessage(reason: unknown, fallback: string): string {
  return reason instanceof Error ? reason.message : fallback
}

function UsageMetric({ usage }: { usage: TokenUsage }): React.JSX.Element {
  const ratio = usageRatio(usage)
  return <div className="metric">
    <div className="metric-heading"><strong>{usageTitle(usage)}</strong><span title={exactAmountText(usage)}>{amountText(usage)}</span></div>
    {ratio !== undefined && <progress className={usageTone(usage)} aria-label={`${usageTitle(usage)} ${Math.round(ratio * 100)} percent`} value={ratio} max={1} />}
    {usage.window === 'tokenQuota' && <small>{exactAmountText(usage)}</small>}
    {usage.resetAt && <small>{resetText(usage.resetAt)}</small>}
  </div>
}

function StatusPage({ state, onSettings, onRefresh, error }: { state: AppState; onSettings: () => void; onRefresh: () => void; error: string }): React.JSX.Element {
  const snapshots = useMemo(() => new Map(state.snapshots.map((snapshot) => [snapshot.id, snapshot])), [state.snapshots])
  const enabled = state.configs.filter((config) => config.isEnabled)
  const readyEnabled = enabled.filter((config) => snapshots.get(config.id)?.state === 'ready').length
  return <>
    <header><div><h1>Token Health</h1><p>{state.refreshing ? 'Refreshing' : `${readyEnabled}/${enabled.length} updated`}</p></div>
      <div className="actions"><button onClick={onRefresh} disabled={state.refreshing}>Refresh</button><button onClick={onSettings}>Settings</button></div></header>
    {error && <div className="error" role="alert">{error}</div>}
    {!enabled.length && <section className="empty"><h2>No providers configured</h2><p>Add Generic HTTP or Codex in Settings.</p><button onClick={onSettings}>Add Provider</button></section>}
    <main>{enabled.map((config) => {
      const snapshot = snapshots.get(config.id)
      return <article className="card" key={config.id}>
        <div className="card-title"><div><h2>{config.displayName}</h2><p>{snapshot?.providerTitle ?? (config.providerKind === 'codex' ? 'Codex' : 'Generic HTTP')}{snapshot?.planName ? ` · ${snapshot.planName}` : ''}</p></div><span className={`status ${snapshot?.state ?? 'pending'}`}>{snapshot?.state === 'ready' ? 'OK' : snapshot?.state === 'needsConfiguration' ? 'Config' : snapshot ? 'Unavailable' : 'Pending'}</span></div>
        {snapshot?.state === 'ready' ? <>{snapshot.statusMessage.toLowerCase().includes('insecure http') && <div className="warning ready-warning">{snapshot.statusMessage}</div>}{snapshot.usages.map((usage) => <UsageMetric usage={usage} key={`${usage.window}:${usage.label ?? ''}`} />)}</> : <p className="message">{snapshot?.statusMessage ?? 'Waiting for refresh'}</p>}
      </article>
    })}</main>
  </>
}

interface Draft { id: string; displayName: string; providerKind: ProviderKind; apiEndpoint: string; isEnabled: boolean; bearerToken: string; bearerTokenAction: BearerTokenAction }
function newDraft(kind: ProviderKind): Draft {
  return { id: crypto.randomUUID(), displayName: kind === 'codex' ? 'Codex' : 'Generic HTTP', providerKind: kind, apiEndpoint: '', isEnabled: true, bearerToken: '', bearerTokenAction: kind === 'codex' ? 'clear' : 'clear' }
}

function SettingsPage({ state, onBack, update }: { state: AppState; onBack: () => void; update: (value: AppState) => void }): React.JSX.Element {
  const [selectedId, setSelectedId] = useState<string | undefined>(state.configs[0]?.id)
  const selected = state.configs.find((config) => config.id === selectedId)
  const [draft, setDraft] = useState<Draft>(() => selected ? { ...selected, bearerToken: '', bearerTokenAction: 'keep' } : newDraft('genericHTTP'))
  const [error, setError] = useState('')

  useEffect(() => {
    if (selected) setDraft({ ...selected, bearerToken: '', bearerTokenAction: 'keep' })
  }, [selected])

  const originalOrigin = selected?.providerKind === 'genericHTTP' ? new URL(selected.apiEndpoint).origin : undefined
  let draftOrigin: string | undefined
  try { draftOrigin = draft.providerKind === 'genericHTTP' ? new URL(draft.apiEndpoint).origin : undefined } catch { draftOrigin = undefined }
  const endpointOriginChanged = Boolean(originalOrigin && draftOrigin && originalOrigin !== draftOrigin)

  const save = async (): Promise<void> => {
    setError('')
    try {
      const config: ServiceConfig = {
        id: draft.id, displayName: draft.displayName, providerKind: draft.providerKind,
        apiEndpoint: draft.providerKind === 'genericHTTP' ? draft.apiEndpoint : '', isEnabled: draft.isEnabled
      }
      const action = draft.providerKind === 'genericHTTP' ? draft.bearerTokenAction : 'clear'
      update(await window.tokenHealth.upsertProvider({ config, bearerTokenAction: action, ...(action === 'replace' ? { bearerToken: draft.bearerToken } : {}) }))
      setSelectedId(config.id)
      setDraft({ ...draft, bearerToken: '', bearerTokenAction: draft.providerKind === 'genericHTTP' ? 'keep' : 'clear' })
    } catch (reason) { setError(errorMessage(reason, 'Save failed')) }
  }
  const remove = async (): Promise<void> => {
    if (!selected) return
    setError('')
    try {
      update(await window.tokenHealth.deleteProvider({ id: selected.id }))
      setSelectedId(undefined)
      setDraft(newDraft('genericHTTP'))
    } catch (reason) { setError(errorMessage(reason, 'Delete failed')) }
  }
  const add = (kind: ProviderKind): void => { const next = newDraft(kind); setSelectedId(undefined); setDraft(next); setError('') }
  const setTokenAction = (action: BearerTokenAction): void => setDraft({ ...draft, bearerTokenAction: action, bearerToken: action === 'replace' ? draft.bearerToken : '' })

  return <>
    <header><div><h1>Settings</h1><p>Windows MVP providers and security diagnostics</p></div><button onClick={onBack}>Back</button></header>
    <div className="settings-layout">
      <aside>{state.configs.map((config) => <button className={config.id === selectedId ? 'selected' : ''} onClick={() => { setSelectedId(config.id); setError('') }} key={config.id}>{config.displayName}<small>{config.providerKind === 'codex' ? 'Codex' : 'Generic HTTP'}</small></button>)}
        <button onClick={() => add('genericHTTP')}>+ Generic HTTP</button><button onClick={() => add('codex')} disabled={state.configs.some((item) => item.providerKind === 'codex')}>+ Codex</button></aside>
      <section className="form">
        <label>Name<input value={draft.displayName} maxLength={80} onChange={(event) => setDraft({ ...draft, displayName: event.target.value })} /></label>
        <label>Provider<select value={draft.providerKind} disabled={Boolean(selected)} onChange={(event) => { const providerKind = event.target.value as ProviderKind; setDraft({ ...draft, providerKind, bearerTokenAction: providerKind === 'codex' ? 'clear' : draft.bearerTokenAction }) }}><option value="genericHTTP">Generic HTTP</option><option value="codex">Codex</option></select></label>
        {draft.providerKind === 'genericHTTP' ? <>
          <label>GET endpoint<input type="url" placeholder="https://example.test/usage" value={draft.apiEndpoint} onChange={(event) => setDraft({ ...draft, apiEndpoint: event.target.value })} /></label>
          {/^http:/i.test(draft.apiEndpoint.trim()) && <div className="warning">HTTP sends usage and bearer credentials without transport encryption. Use only on a trusted network.</div>}
          <fieldset><legend>Bearer token</legend>
            {selected && <label className="check"><input type="radio" name="token-action" checked={draft.bearerTokenAction === 'keep'} disabled={endpointOriginChanged} onChange={() => setTokenAction('keep')} />Keep existing token {endpointOriginChanged ? '(not allowed after origin change)' : ''}</label>}
            <label className="check"><input type="radio" name="token-action" checked={draft.bearerTokenAction === 'replace'} disabled={!state.vaultAvailable} onChange={() => setTokenAction('replace')} />Replace with a new token</label>
            <label className="check"><input type="radio" name="token-action" checked={draft.bearerTokenAction === 'clear'} onChange={() => setTokenAction('clear')} />Clear token / use no token</label>
          </fieldset>
          {draft.bearerTokenAction === 'replace' && <label>New bearer token (write-only)<input type="password" autoComplete="new-password" value={draft.bearerToken} disabled={!state.vaultAvailable} onChange={(event) => setDraft({ ...draft, bearerToken: event.target.value })} /></label>}
          {!state.vaultAvailable && <div className="warning">Windows DPAPI encryption is unavailable. Public endpoints without a stored token still work; providers with secrets fail closed.</div>}
        </> : <CodexSettings state={state} update={update} reportError={setError} />}
        <label className="check"><input type="checkbox" checked={draft.isEnabled} onChange={(event) => setDraft({ ...draft, isEnabled: event.target.checked })} />Enabled</label>
        {error && <div className="error" role="alert">{error}</div>}
        <div className="actions"><button className="primary" onClick={() => void save()}>Save</button>{selected && <button className="danger" onClick={() => void remove()}>Delete</button>}</div>
        <hr />
        <label className="check"><input type="checkbox" checked={state.startWithWindows} onChange={(event) => {
          setError('')
          void window.tokenHealth.setStartWithWindows({ enabled: event.target.checked }).then(update).catch((reason) => setError(errorMessage(reason, 'Startup setting failed')))
        }} />Start with Windows</label>
      </section>
    </div>
  </>
}

function CodexSettings({ state, update, reportError }: { state: AppState; update: (value: AppState) => void; reportError: (message: string) => void }): React.JSX.Element {
  const diagnostic = state.codexDiagnostic
  return <div className="diagnostic">
    <h3>Codex executable trust</h3>
    <p>{diagnostic?.message ?? 'Not checked'}</p>
    {diagnostic?.path && <code>{diagnostic.path}</code>}
    {diagnostic?.signatureStatus && <p>Authenticode: {diagnostic.signatureStatus}</p>}
    {diagnostic?.signerSubject && <><p>Signer subject (copy this for policy review):</p><code>{diagnostic.signerSubject}</code></>}
    <button onClick={() => {
      reportError('')
      void window.tokenHealth.selectCodexExecutable().then(update).catch((reason) => reportError(errorMessage(reason, 'Codex selection failed')))
    }}>Select official codex.exe</button>
    <small>Fail closed: a Valid Authenticode signature, exact approved OpenAI signer, and unchanged SHA-256/stat identity are required. PATH is never searched.</small>
  </div>
}

export function App(): React.JSX.Element {
  const [state, setState] = useState<AppState>(emptyState)
  const [page, setPage] = useState<Page>('status')
  const [error, setError] = useState('')
  useEffect(() => {
    void window.tokenHealth.getState().then(setState).catch((reason) => setError(errorMessage(reason, 'Application startup failed')))
    const unsubscribeState = window.tokenHealth.subscribe(setState)
    const unsubscribeSettings = window.tokenHealth.onShowSettings(() => setPage('settings'))
    return () => { unsubscribeState(); unsubscribeSettings() }
  }, [])
  const refresh = (): void => {
    setError('')
    void window.tokenHealth.refresh().then(setState).catch((reason) => setError(errorMessage(reason, 'Refresh failed')))
  }
  return <div className="shell">{page === 'status'
    ? <StatusPage state={state} error={error} onSettings={() => setPage('settings')} onRefresh={refresh} />
    : <SettingsPage state={state} onBack={() => setPage('status')} update={setState} />}</div>
}
