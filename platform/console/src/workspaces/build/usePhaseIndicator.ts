// Phase-indicator state for the Build workspace (Console Studio parity).
//
// Small, composable hook that tracks the agent-design lifecycle phase for the
// active design session and advances it from completed ADE turns.
//
// Responsibilities (Requirement 6):
//   - Expose the five ordered lifecycle phases for rendering (6.1) — the
//     ordered PHASES labels come from ./types.
//   - Advance the highlighted phase when a completed ADE response indicates a
//     later phase (6.2), using the pure `advancePhase` heuristic in ./phase.
//   - Never regress to an earlier phase within a session (6.3): advancement is
//     monotonic and `onAdvance` is only invoked when the phase increases.
//   - Reflect the active session's stored phase when switching sessions (6.4):
//     the current phase is supplied by the caller (the active session's stored
//     `phase`), so selecting a different session naturally re-renders at that
//     session's phase with no extra bookkeeping here.
//
// Intended integration with `useDesignSessions` (task 9.1 / BuildWorkspace):
//
//   const sessions = useDesignSessions()
//   const phaseIndicator = usePhaseIndicator({
//     phase: sessions.activeSession?.phase ?? 0,
//     onAdvance: sessions.setPhase,
//   })
//   // on each completed ADE turn:
//   phaseIndicator.handleAgentMessage(agentText)
//
// `onAdvance` writes back into the active session's stored phase (via
// `useDesignSessions().setPhase`), so advancing persists per-session and the
// monotonic `phase` in the session store is the source of truth (6.3, 6.4).

import { useCallback } from 'react'
import { advancePhase } from './phase'
import { PHASES } from './types'
import type { Phase } from './types'

/** Clamp an arbitrary phase index into the valid range [0, PHASES.length-1]. */
function clampPhase(phase: number): number {
  if (!Number.isFinite(phase) || phase < 0) return 0
  const max = PHASES.length - 1
  return phase > max ? max : Math.floor(phase)
}

export interface UsePhaseIndicatorOptions {
  /**
   * The phase currently reached in the active session (its stored,
   * monotonic `phase`). Supplying this from the active session means switching
   * sessions reflects that session's phase (Req 6.4).
   */
  phase: number
  /**
   * Called with the new phase index when a completed ADE turn advances the
   * phase to a later one. Never called when the phase would stay the same or
   * regress (Req 6.3). Typically wired to `useDesignSessions().setPhase`.
   */
  onAdvance: (phase: number) => void
}

export interface UsePhaseIndicator {
  /** The current phase index (0..PHASES.length-1), clamped to a valid range. */
  phase: number
  /** The label for the current phase, e.g. "Pattern Selection" (Req 6.1). */
  phaseLabel: Phase
  /** The ordered phase labels for rendering the indicator (Req 6.1). */
  phases: readonly Phase[]
  /**
   * Process a completed ADE response: compute `advancePhase(phase, text)` and,
   * when it is later than the current phase, invoke `onAdvance` with it
   * (Req 6.2). Monotonic — never advances backward (Req 6.3). Returns the phase
   * index after considering `text` (the current phase when nothing advanced).
   */
  handleAgentMessage: (text: string) => number
}

/**
 * Track and advance the agent-design lifecycle phase for the active session.
 *
 * The hook is deliberately stateless: the authoritative, monotonic phase lives
 * in the design-session store (`useDesignSessions`). This hook derives display
 * state from the supplied `phase` and forwards monotonic advancements through
 * `onAdvance`, keeping phase state co-located with the session it belongs to
 * (Req 6.3, 6.4).
 */
export function usePhaseIndicator({ phase, onAdvance }: UsePhaseIndicatorOptions): UsePhaseIndicator {
  const current = clampPhase(phase)

  const handleAgentMessage = useCallback(
    (text: string): number => {
      const next = advancePhase(current, text)
      // Only advance forward (Req 6.2, 6.3); never regress or re-emit no-ops.
      if (next > current) {
        onAdvance(next)
      }
      return next
    },
    [current, onAdvance],
  )

  return {
    phase: current,
    phaseLabel: PHASES[current],
    phases: PHASES,
    handleAgentMessage,
  }
}
