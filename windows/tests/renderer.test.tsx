import { act, cleanup, fireEvent, render, screen } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { AppState, TokenHealthAPI } from '../src/shared/contracts'
import { App } from '../src/renderer/App'

const state: AppState = {
  version: 1,
  configs: [{ id: '20ef7cc1-7b98-4780-b3a5-4fd82456ae77', displayName: 'Local Usage', providerKind: 'genericHTTP', apiEndpoint: 'http://localhost:8080', isEnabled: true }],
  snapshots: [{
    id: '20ef7cc1-7b98-4780-b3a5-4fd82456ae77', serviceName: 'Local Usage', providerTitle: 'Generic HTTP',
    usages: [{ window: 'fiveHours', used: 70, limit: 100, resetAt: '2026-08-01T00:00:00.000Z' }],
    state: 'ready', statusMessage: 'Updated over insecure HTTP after redirect', updatedAt: '2026-07-16T00:00:00.000Z'
  }],
  refreshing: false, startWithWindows: false, vaultAvailable: true
}

afterEach(() => cleanup())

beforeEach(() => {
  const api: TokenHealthAPI = {
    getState: vi.fn(async () => state), refresh: vi.fn(async () => state), upsertProvider: vi.fn(async () => state),
    deleteProvider: vi.fn(async () => state), selectCodexExecutable: vi.fn(async () => state),
    setStartWithWindows: vi.fn(async () => state), showSettings: vi.fn(async () => undefined),
    subscribe: vi.fn(() => () => {}), onShowSettings: vi.fn(() => () => {})
  }
  window.tokenHealth = api
})

describe('renderer key states', () => {
  it('renders final HTTP redirect warning on a ready card and case-insensitive draft warning', async () => {
    render(<App />)
    expect(await screen.findByText('Local Usage')).toBeInTheDocument()
    expect(screen.getByText('70 / 100')).toBeInTheDocument()
    expect(screen.getByText('Updated over insecure HTTP after redirect')).toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: 'Settings' }))
    expect(screen.getByText(/HTTP sends usage/)).toBeInTheDocument()
    const endpoint = screen.getByLabelText('GET endpoint')
    fireEvent.change(endpoint, { target: { value: 'HTTP://localhost:8080/usage' } })
    expect(screen.getByText(/HTTP sends usage/)).toBeInTheDocument()
  })

  it('provides explicit keep, replace, and clear token actions and disables keep on origin change', async () => {
    render(<App />)
    await screen.findByText('Local Usage')
    fireEvent.click(screen.getByRole('button', { name: 'Settings' }))
    const keep = screen.getByRole('radio', { name: /Keep existing token/ })
    expect(keep).toBeChecked()
    fireEvent.change(screen.getByLabelText('GET endpoint'), { target: { value: 'https://other.test/usage' } })
    expect(keep).toBeDisabled()
    fireEvent.click(screen.getByRole('radio', { name: /Clear token/ }))
    fireEvent.click(screen.getByRole('button', { name: 'Save' }))
    await act(async () => {})
    expect(window.tokenHealth.upsertProvider).toHaveBeenCalledWith(expect.objectContaining({ bearerTokenAction: 'clear' }))
  })

  it('renders empty state and counts only enabled ready providers', async () => {
    vi.mocked(window.tokenHealth.getState).mockResolvedValue({ ...state, configs: [], snapshots: [] })
    const first = render(<App />)
    expect(await screen.findByText('No providers configured')).toBeInTheDocument()
    first.unmount()
    vi.mocked(window.tokenHealth.getState).mockResolvedValue({
      ...state,
      configs: [...state.configs, { ...state.configs[0], id: 'a7a1b9cf-2829-4994-aaf4-8c27ed4b2a03', isEnabled: false }],
      snapshots: [...state.snapshots, { ...state.snapshots[0], id: 'a7a1b9cf-2829-4994-aaf4-8c27ed4b2a03' }]
    })
    render(<App />)
    expect(await screen.findByText('1/1 updated')).toBeInTheDocument()
  })

  it('updates from subscription and displays startup/refresh failures', async () => {
    let listener: ((value: AppState) => void) | undefined
    vi.mocked(window.tokenHealth.subscribe).mockImplementation((value) => { listener = value; return () => {} })
    vi.mocked(window.tokenHealth.refresh).mockRejectedValue(new Error('refresh rejected'))
    render(<App />)
    await screen.findByText('Local Usage')
    act(() => listener?.({ ...state, refreshing: true }))
    expect(screen.getByText('Refreshing')).toBeInTheDocument()
    act(() => listener?.(state))
    fireEvent.click(screen.getByRole('button', { name: 'Refresh' }))
    expect(await screen.findByRole('alert')).toHaveTextContent('refresh rejected')
  })
})
