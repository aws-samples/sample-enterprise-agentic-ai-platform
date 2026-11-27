// Phase-detection helpers for the Build workspace (Console Studio parity).
//
// Mirrors the phase-detection heuristics used by the standalone Agent Builder
// Studio UI (`platform/demo-ui/standalone/agent-builder-studio-ui/src/App.tsx`).
// These are pure functions with no side effects.
//
// The design's Phase_Indicator (Requirements 6.1, 6.2, 6.3) tracks the
// agent-design lifecycle as five ordered phases:
//   0 Discovery
//   1 Pattern Selection
//   2 Customization
//   3 YAML & Code Generation
//   4 Deployment
//
// The PHASES label constant lives in ./types (task 1.1); it is intentionally
// not imported here so these helpers stay dependency-free and testable in
// isolation. `detectPhase` only needs to return the numeric index (0..4).

/** Number of lifecycle phases (indices 0..4). */
export const PHASE_COUNT = 5

/**
 * Detect the highest phase index (0..4) indicated by an ADE response text.
 *
 * Uses the same case-insensitive keyword heuristics as the standalone UI:
 *   - "pattern" AND ("recommend" OR "suggest")           -> 1 (Pattern Selection)
 *   - "customiz" OR "adjust" OR "modify"                 -> 2 (Customization)
 *   - "agent.yaml" OR "manifest" OR "generated"          -> 3 (YAML & Code Generation)
 *   - "deploy" OR "pipeline" OR "commit"                 -> 4 (Deployment)
 *
 * Returns the highest matching phase index, or 0 (Discovery) when nothing
 * matches. Multiple heuristics may match a single response; the highest wins.
 *
 * @param text The ADE response text to inspect.
 * @returns A phase index in the range 0..4.
 */
export function detectPhase(text: string): number {
  if (!text) return 0
  const lower = text.toLowerCase()

  let phase = 0
  if (lower.includes('pattern') && (lower.includes('recommend') || lower.includes('suggest'))) {
    phase = Math.max(phase, 1)
  }
  if (lower.includes('customiz') || lower.includes('adjust') || lower.includes('modify')) {
    phase = Math.max(phase, 2)
  }
  if (lower.includes('agent.yaml') || lower.includes('manifest') || lower.includes('generated')) {
    phase = Math.max(phase, 3)
  }
  if (lower.includes('deploy') || lower.includes('pipeline') || lower.includes('commit')) {
    phase = Math.max(phase, 4)
  }
  return phase
}

/**
 * Advance a previously-reached phase given a new ADE response, never
 * regressing to an earlier phase (Requirement 6.3).
 *
 * @param prev The phase index reached so far in the session.
 * @param text The newly completed ADE response text.
 * @returns `max(prev, detectPhase(text))`.
 */
export function advancePhase(prev: number, text: string): number {
  return Math.max(prev, detectPhase(text))
}
