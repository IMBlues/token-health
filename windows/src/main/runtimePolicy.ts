export function isHiddenLaunch(argv: readonly string[] = process.argv): boolean {
  return argv.includes('--hidden')
}

export function allowedRendererOrigin(rendererURL: string | undefined, packaged: boolean): string | undefined {
  if (packaged || !rendererURL) return undefined
  try { return new URL(rendererURL).origin } catch { return undefined }
}

export function shouldAllowRendererRequest(url: string, developmentOrigin?: string): boolean {
  if (!developmentOrigin) return false
  try { return new URL(url).origin === developmentOrigin } catch { return false }
}
