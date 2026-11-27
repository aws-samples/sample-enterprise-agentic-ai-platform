import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { cleanup, fireEvent, render, screen } from '@testing-library/react'
import { OBSERVABILITY_PERSONAS } from '../auth/usePermissions'

/**
 * Task 13.2 — component tests for the integrated ObservabilityWorkspace.
 *
 * Asserts the single-workspace guarantees finalized in task 13.1 (core):
 *   - the BU-scoped selector limits agents to the caller's selected BU (R4.2),
 *   - the embedded Langfuse iframe src carries EXACTLY the selected BU (R13.4),
 *   - switching BU updates BOTH the agent list and the embed (R4.2, R10.2),
 *   - an agent from another BU is never selectable/embedded (R4.2),
 *   - scoping is enforced identically for EVERY authorized persona (R10.2).
 *
 * Requirements: 4.2, 10.2.
 */

// --- Mutable test state consumed by the hook mocks below (read at render time) ---
let currentBU = 'team-bu-1'
let currentGroups: string[] = ['Developer', 'bu:team-bu-1']

// Agents spanning two business units — the fixture that lets us prove tenant scoping.
const AGENTS = [
  { agent_name: 'bu1-alpha', version: '1.0.0', bu: 'team-bu-1' },
  { agent_name: 'bu1-beta', version: '2.1.0', bu: 'team-bu-1' },
  { agent_name: 'bu2-gamma', version: '3.0.0', bu: 'team-bu-2' },
]

vi.mock('../hooks/useAgents', () => ({
  useAgents: () => ({ data: AGENTS, isLoading: false, error: null }),
}))

vi.mock('../hooks/useBU', () => ({
  useBU: () => ({
    selectedBU: currentBU,
    availableBUs: ['team-bu-1', 'team-bu-2'],
    setSelectedBU: (bu: string) => {
      currentBU = bu
    },
    domain: `team-${currentBU}`,
  }),
}))

// Drive persona gating through the REAL persona logic so "for every persona" is
// exercised against production semantics rather than a hand-rolled stub.
vi.mock('../auth/usePermissions', async (importActual) => {
  const actual = await importActual<typeof import('../auth/usePermissions')>()
  return {
    ...actual,
    usePermissions: () => ({
      canAccess: (ws: string) =>
        ws === 'observability' ? actual.hasObservabilityAccess(currentGroups) : true,
      allScopes: actual.WORKSPACE_SCOPES,
    }),
  }
})

import { ObservabilityWorkspace } from './ObservabilityWorkspace'

function agentSelect(): HTMLSelectElement {
  return screen.getByLabelText('Select an agent') as HTMLSelectElement
}

function selectAgent(name: string) {
  fireEvent.change(agentSelect(), { target: { value: name } })
}

function langfuseIframe(container: HTMLElement): HTMLIFrameElement | null {
  return container.querySelector('iframe[title="Langfuse Trace Explorer"]')
}

describe('ObservabilityWorkspace — integrated BU scoping (task 13.2)', () => {
  beforeEach(() => {
    vi.stubEnv('VITE_LANGFUSE_EMBED_ORIGIN', 'https://langfuse.example.com')
    vi.spyOn(window, 'open').mockReturnValue(null)
    sessionStorage.clear()
    currentBU = 'team-bu-1'
    currentGroups = ['Developer', 'bu:team-bu-1']
  })

  afterEach(() => {
    cleanup()
    vi.unstubAllEnvs()
    vi.restoreAllMocks()
  })

  // R4.2 + R10.2: identical scoping for every authorized persona.
  it.each(OBSERVABILITY_PERSONAS)(
    'limits the selector to the caller BU and scopes the embed for persona %s (R4.2, R10.2)',
    (persona) => {
      currentBU = 'team-bu-1'
      currentGroups = [persona, 'bu:team-bu-1']

      const { container } = render(<ObservabilityWorkspace />)

      // Selector lists only team-bu-1 agents; the other BU's agent is absent.
      expect(screen.queryByRole('option', { name: /bu1-alpha/ })).not.toBeNull()
      expect(screen.queryByRole('option', { name: /bu1-beta/ })).not.toBeNull()
      expect(screen.queryByRole('option', { name: /bu2-gamma/ })).toBeNull()

      // Embed src carries EXACTLY the selected BU, never the other tenant's BU.
      selectAgent('bu1-alpha')
      const src = langfuseIframe(container)?.getAttribute('src') ?? ''
      expect(src).toContain('bu=team-bu-1')
      expect(src).not.toContain('team-bu-2')
    }
  )

  // R4.2: an agent from another BU is never selectable (never reaches the embed).
  it('never exposes a cross-BU agent as a selectable option', () => {
    currentBU = 'team-bu-1'
    render(<ObservabilityWorkspace />)

    const values = Array.from(agentSelect().options).map((o) => o.value)
    expect(values).toContain('bu1-alpha')
    expect(values).toContain('bu1-beta')
    expect(values).not.toContain('bu2-gamma')
  })

  // R4.2 + R10.2: switching BU updates BOTH the agent list and the embed together.
  it('updates the agent list and the embed src when the BU changes', () => {
    // Start in team-bu-2: only its agent is selectable and drives the embed.
    currentBU = 'team-bu-2'
    currentGroups = ['Platform_Operator', 'bu:team-bu-2']
    const { container, rerender } = render(<ObservabilityWorkspace />)

    expect(screen.queryByRole('option', { name: /bu2-gamma/ })).not.toBeNull()
    expect(screen.queryByRole('option', { name: /bu1-alpha/ })).toBeNull()

    selectAgent('bu2-gamma')
    expect(langfuseIframe(container)?.getAttribute('src')).toContain('bu=team-bu-2')

    // Switch to team-bu-1 and re-render the SAME workspace instance.
    currentBU = 'team-bu-1'
    rerender(<ObservabilityWorkspace />)

    // Agent list now reflects team-bu-1 only.
    const values = Array.from(agentSelect().options).map((o) => o.value)
    expect(values).toContain('bu1-alpha')
    expect(values).not.toContain('bu2-gamma')

    // The stale team-bu-2 selection is cleared, so no cross-BU agent stays embedded.
    expect(langfuseIframe(container)).toBeNull()

    // Selecting a team-bu-1 agent re-embeds, now scoped to team-bu-1.
    selectAgent('bu1-alpha')
    const src = langfuseIframe(container)?.getAttribute('src') ?? ''
    expect(src).toContain('bu=team-bu-1')
    expect(src).not.toContain('team-bu-2')
  })

  // R10.3: a caller without an authorized persona never reaches the surfaces,
  // even by addressing the route directly (the in-component gate closes the gap).
  it('withholds the workspace surfaces from a caller lacking an authorized persona', () => {
    currentGroups = ['SomeOtherGroup', 'bu:team-bu-1']
    const { container } = render(<ObservabilityWorkspace />)

    expect(screen.getByLabelText('Observability access denied')).toBeTruthy()
    expect(screen.queryByLabelText('Select an agent')).toBeNull()
    expect(langfuseIframe(container)).toBeNull()
  })
})
