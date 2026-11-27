import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { cleanup, fireEvent, render, screen } from '@testing-library/react'

// --- Mock the data hooks so the workspace renders without Cognito/DynamoDB ---
const AGENTS = [{ agent_name: 'my-agent', version: '1.0.0', bu: 'team-bu-1' }]

vi.mock('../hooks/useAgents', () => ({
  useAgents: () => ({ data: AGENTS, isLoading: false, error: null }),
}))

vi.mock('../hooks/useBU', () => ({
  useBU: () => ({
    selectedBU: 'team-bu-1',
    availableBUs: ['team-bu-1'],
    setSelectedBU: () => {},
    domain: 'team-team-bu-1',
  }),
}))

import { ObservabilityWorkspace, buildLangfuseEmbedUrl } from './ObservabilityWorkspace'

/** Select the seeded agent so the observability surfaces render (gated on selection). */
function selectAgent() {
  fireEvent.change(screen.getByLabelText('Select an agent'), {
    target: { value: 'my-agent' },
  })
}

describe('ObservabilityWorkspace — embedded Langfuse (task 9.3)', () => {
  beforeEach(() => {
    // Priming opens a top-level popup; stub it so jsdom stays quiet and no window opens.
    vi.spyOn(window, 'open').mockReturnValue(null)
    sessionStorage.clear()
  })

  afterEach(() => {
    cleanup()
    vi.unstubAllEnvs()
    vi.restoreAllMocks()
  })

  it('renders the Langfuse iframe as the primary surface when origin is set and an agent is selected (R7.4, R13.1, R13.4)', () => {
    vi.stubEnv('VITE_LANGFUSE_EMBED_ORIGIN', 'https://langfuse.example.com')

    const { container } = render(<ObservabilityWorkspace />)
    selectAgent()

    const iframe = container.querySelector('iframe[title="Langfuse Trace Explorer"]') as HTMLIFrameElement | null
    expect(iframe).not.toBeNull()
    // Scoped to the caller's BU (R13.1, R14.2) and pointed at the configured origin.
    expect(iframe?.getAttribute('src')).toContain('https://langfuse.example.com')
    expect(iframe?.getAttribute('src')).toContain('bu=team-bu-1')

    // "Primary" surface labeling is present.
    expect(screen.getByText('Primary')).toBeTruthy()
    // No "unavailable" state while the embed is configured.
    expect(screen.queryByText('Langfuse unavailable')).toBeNull()
  })

  it('renders the "Langfuse unavailable" state when the embed origin is missing/empty', () => {
    vi.stubEnv('VITE_LANGFUSE_EMBED_ORIGIN', '')

    const { container } = render(<ObservabilityWorkspace />)
    selectAgent()

    expect(screen.getByText('Langfuse unavailable')).toBeTruthy()
    expect(container.querySelector('iframe[title="Langfuse Trace Explorer"]')).toBeNull()
  })
})

describe('buildLangfuseEmbedUrl', () => {
  it('returns null for an empty/whitespace origin (disables the embed)', () => {
    expect(buildLangfuseEmbedUrl('', 'team-bu-1')).toBeNull()
    expect(buildLangfuseEmbedUrl('   ', 'team-bu-1')).toBeNull()
  })

  it('returns null for a malformed origin', () => {
    expect(buildLangfuseEmbedUrl('not a url', 'team-bu-1')).toBeNull()
  })

  it('scopes the URL to the BU when one is provided', () => {
    const url = buildLangfuseEmbedUrl('https://langfuse.example.com', 'team-bu-2')
    expect(url).toContain('https://langfuse.example.com')
    expect(url).toContain('bu=team-bu-2')
  })

  it('omits the bu param when no BU is selected', () => {
    const url = buildLangfuseEmbedUrl('https://langfuse.example.com', '')
    expect(url).not.toBeNull()
    expect(url).not.toContain('bu=')
  })
})
