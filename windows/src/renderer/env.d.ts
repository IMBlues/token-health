import type { TokenHealthAPI } from '../shared/contracts'

declare global {
  interface Window {
    tokenHealth: TokenHealthAPI
  }
}

export {}
