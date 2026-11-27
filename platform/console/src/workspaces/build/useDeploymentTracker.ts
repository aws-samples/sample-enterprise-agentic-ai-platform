/**
 * useDeploymentTracker.ts — Deployment tracking + polling state machine (Req 7)
 *
 * Mirrors the standalone Agent Builder Studio's deployment polling
 * (platform/demo-ui/standalone/agent-builder-studio-ui/src/App.tsx) and the
 * design's "Deployment-tracking state machine" / "Status Polling Flow-Back"
 * sections.
 *
 * The hook holds a map keyed by CodePipeline execution ID of {@link ActiveDeployment}
 * entries. A single 10s interval polls every `in_progress` entry via
 * `GET /api/deployment-status/:executionId` (Req 7.2) and applies the result:
 *  - update stage/status only on change (Req 7.3);
 *  - terminal `succeeded` → stop polling + fire `onSucceeded` to force-refresh
 *    the deployed-agents list (Req 7.4);
 *  - terminal `failed|cancelled|stopped|superseded` → display + stop (Req 7.5);
 *  - poll failure → retain last-known, keep polling, surface error after 3
 *    consecutive failures (Req 7.6);
 *  - `in_progress` > 30 min → mark timed out, stop polling (Req 7.7).
 *
 * The pure state-transition logic (`applyPollResult`, `classifyTerminal`,
 * `shouldTimeout`, `markTimedOut`, plus the threshold/interval/timeout
 * constants) is exported separately so it can be property-tested (task 5.2)
 * without a React runtime.
 *
 * _Requirements: 7.1, 7.2, 7.3, 7.4, 7.5, 7.6, 7.7_
 */

import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { useAuth } from '../../auth/CognitoProvider'
import { extractExecutionIds } from './execIds'
import type { ActiveDeployment, DeploymentState } from './types'

// --- Constants (Req 7.2, 7.6, 7.7) ---

/** Polling cadence for in-progress deployments (Req 7.2). */
export const POLL_INTERVAL_MS = 10_000

/** An in-progress deployment older than this is timed out (Req 7.7). */
export const DEPLOYMENT_TIMEOUT_MS = 1_800_000 // 30 minutes

/** Consecutive failed polls before an error is surfaced (Req 7.6). */
export const FAILURE_ERROR_THRESHOLD = 3

/** Error surfaced once the consecutive-failure threshold is reached (Req 7.6). */
export const POLL_FAILURE_MESSAGE = 'Unable to reach deployment status service'

/** Indication surfaced when a deployment exceeds the timeout (Req 7.7). */
export const TIMEOUT_MESSAGE = 'Deployment timed out after 30 minutes'

/** Terminal CodePipeline statuses — polling stops once reached (Req 7.4, 7.5). */
export const TERMINAL_STATUSES: ReadonlySet<DeploymentState> = new Set<DeploymentState>([
  'succeeded',
  'failed',
  'cancelled',
  'stopped',
  'superseded',
])

// --- Pure state-transition helpers (property-testable) ---

/**
 * The outcome of a single status poll, normalized for {@link applyPollResult}.
 *  - `{ ok: true, ... }` — the status service responded; `status`/`stage`/`error`
 *    are applied when present.
 *  - `{ ok: false }` — the poll failed or returned no status (Req 7.6).
 */
export type PollOutcome =
  | { ok: true; status?: DeploymentState; stage?: string; error?: string | null }
  | { ok: false }

/**
 * True when `status` is terminal and polling for that deployment should stop
 * (Req 7.4, 7.5).
 */
export function classifyTerminal(status: DeploymentState): boolean {
  return TERMINAL_STATUSES.has(status)
}

/**
 * True when an in-progress deployment has exceeded the 30-minute timeout at
 * time `now` (Req 7.7). Terminal and already-timed-out entries never time out
 * again.
 */
export function shouldTimeout(entry: ActiveDeployment, now: number): boolean {
  if (entry.status !== 'in_progress' || entry.timedOut) return false
  return now - entry.startedAt > DEPLOYMENT_TIMEOUT_MS
}

/**
 * Mark an entry as timed out (Req 7.7). Preserves an existing error, otherwise
 * surfaces the timeout indication. Returns the same reference when already
 * timed out so callers can skip needless re-renders.
 */
export function markTimedOut(entry: ActiveDeployment): ActiveDeployment {
  if (entry.timedOut) return entry
  return { ...entry, timedOut: true, error: entry.error ?? TIMEOUT_MESSAGE }
}

/**
 * Apply a poll outcome to a tracked deployment (Req 7.3, 7.5, 7.6).
 *
 * On a successful poll the returned status/stage/error are merged (status/stage
 * only overwrite when the service provided a value), and the consecutive-failure
 * counter resets. On a failed poll the last-known status/stage are retained, the
 * failure counter increments, and once {@link FAILURE_ERROR_THRESHOLD} is reached
 * the poll-failure error is surfaced.
 *
 * The same reference is returned when nothing changed, giving idempotence on
 * no-op polls (a property task 5.2 can rely on).
 */
export function applyPollResult(entry: ActiveDeployment, outcome: PollOutcome): ActiveDeployment {
  if (!outcome.ok) {
    const consecutiveFailures = entry.consecutiveFailures + 1
    const error =
      consecutiveFailures >= FAILURE_ERROR_THRESHOLD ? POLL_FAILURE_MESSAGE : entry.error
    if (consecutiveFailures === entry.consecutiveFailures && error === entry.error) {
      return entry
    }
    // Retain last-known status/stage (Req 7.6); only the failure bookkeeping moves.
    return { ...entry, consecutiveFailures, error }
  }

  const nextStatus = outcome.status ?? entry.status
  const nextStage = outcome.stage ?? entry.stage
  const nextError = outcome.error ?? undefined

  const changed =
    nextStatus !== entry.status ||
    nextStage !== entry.stage ||
    nextError !== entry.error ||
    entry.consecutiveFailures !== 0

  if (!changed) return entry

  return {
    ...entry,
    status: nextStatus,
    stage: nextStage,
    error: nextError,
    consecutiveFailures: 0,
  }
}

// --- Hook ---

/** Optional context attached to deployments registered from an ADE turn. */
export interface RegisterContext {
  appName?: string
  patternFolder?: string
}

export interface UseDeploymentTrackerOptions {
  /**
   * Called once when a tracked deployment transitions to `succeeded` (Req 7.4).
   * The caller uses this to force-refresh the deployed-agents list.
   */
  onSucceeded?: (deployment: ActiveDeployment) => void
}

export interface UseDeploymentTracker {
  /** Tracked deployments keyed by execution ID. */
  deployments: Record<string, ActiveDeployment>
  /** Tracked deployments as a list, most-recently-started first. */
  list: ActiveDeployment[]
  /**
   * Harvest execution IDs from an ADE turn and register any not already tracked
   * as `in_progress` (Req 7.1). Returns the newly registered execution IDs.
   */
  register: (text: string, context?: RegisterContext) => string[]
  /** True while at least one deployment is still in progress. */
  hasActive: boolean
  /** True when any tracked deployment is surfacing an error (Req 7.6). */
  hasError: boolean
  /** True when any tracked deployment has timed out (Req 7.7). */
  hasTimedOut: boolean
}

/**
 * React hook implementing the Deployment_Tracker (Req 7). See the module
 * docstring for the state-machine summary.
 */
export function useDeploymentTracker(
  options: UseDeploymentTrackerOptions = {},
): UseDeploymentTracker {
  const { token } = useAuth()
  const [deployments, setDeployments] = useState<Record<string, ActiveDeployment>>({})

  // Latest deployments snapshot for the polling closure (avoids stale reads
  // without widening the interval's dependency set).
  const deploymentsRef = useRef(deployments)
  deploymentsRef.current = deployments

  // Keep the latest options/token in refs so the polling closure never goes
  // stale without forcing the interval to tear down and rebuild.
  const onSucceededRef = useRef(options.onSucceeded)
  onSucceededRef.current = options.onSucceeded
  const tokenRef = useRef(token)
  tokenRef.current = token

  const register = useCallback((text: string, context: RegisterContext = {}): string[] => {
    let registered: string[] = []
    setDeployments((prev) => {
      const newIds = extractExecutionIds(text, Object.keys(prev))
      if (newIds.length === 0) return prev
      registered = newIds
      const now = Date.now()
      const next = { ...prev }
      for (const executionId of newIds) {
        next[executionId] = {
          executionId,
          appName: context.appName ?? '',
          patternFolder: context.patternFolder,
          status: 'in_progress',
          stage: '',
          startedAt: now,
          consecutiveFailures: 0,
        }
      }
      return next
    })
    return registered
  }, [])

  // Poll a single deployment and fold the outcome into state (Req 7.2, 7.3).
  const pollOne = useCallback(async (entry: ActiveDeployment) => {
    let outcome: PollOutcome
    try {
      const params = new URLSearchParams()
      if (entry.appName) params.set('app_name', entry.appName)
      if (entry.patternFolder) params.set('pattern_folder', entry.patternFolder)
      const query = params.toString()
      const url =
        `/api/deployment-status/${encodeURIComponent(entry.executionId)}` +
        (query ? `?${query}` : '')

      const authToken = tokenRef.current
      const resp = await fetch(url, {
        headers: authToken ? { Authorization: `Bearer ${authToken}` } : undefined,
      })
      if (!resp.ok) {
        outcome = { ok: false }
      } else {
        const data = (await resp.json()) as {
          status?: DeploymentState
          stage?: string
          error?: string | null
        }
        // A response without a status is treated as a failed poll (Req 7.6).
        outcome = data && data.status ? { ok: true, ...data } : { ok: false }
      }
    } catch {
      // Transient network error — retain last-known and keep polling (Req 7.6).
      outcome = { ok: false }
    }

    setDeployments((prev) => {
      const existing = prev[entry.executionId]
      if (!existing) return prev
      const updated = applyPollResult(existing, outcome)
      if (updated === existing) return prev
      // Fire the success callback exactly on the in_progress → succeeded edge (Req 7.4).
      if (updated.status === 'succeeded' && existing.status !== 'succeeded') {
        onSucceededRef.current?.(updated)
      }
      return { ...prev, [entry.executionId]: updated }
    })
  }, [])

  // Single interval driving all in-progress polls (Req 7.2). Re-established only
  // when the set of in-progress execution IDs changes.
  const inProgressKey = Object.keys(deployments)
    .filter((k) => deployments[k].status === 'in_progress' && !deployments[k].timedOut)
    .sort()
    .join(',')

  useEffect(() => {
    if (!inProgressKey) return

    // Enforce the 30-min timeout before each polling pass (Req 7.7).
    const sweepTimeouts = () => {
      const now = Date.now()
      setDeployments((prev) => {
        let changed = false
        const next: Record<string, ActiveDeployment> = {}
        for (const [id, entry] of Object.entries(prev)) {
          if (shouldTimeout(entry, now)) {
            next[id] = markTimedOut(entry)
            changed = true
          } else {
            next[id] = entry
          }
        }
        return changed ? next : prev
      })
    }

    const pollActive = () => {
      sweepTimeouts()
      const now = Date.now()
      for (const entry of Object.values(deploymentsRef.current)) {
        if (entry.status === 'in_progress' && !entry.timedOut && !shouldTimeout(entry, now)) {
          void pollOne(entry)
        }
      }
    }

    // Fire immediately so the first status update lands fast, then settle into
    // the 10s cadence — matching the standalone Studio behaviour.
    pollActive()
    const interval = setInterval(pollActive, POLL_INTERVAL_MS)
    return () => clearInterval(interval)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [inProgressKey, pollOne])

  const list = useMemo(
    () => Object.values(deployments).sort((a, b) => b.startedAt - a.startedAt),
    [deployments],
  )

  const hasActive = useMemo(
    () => list.some((d) => d.status === 'in_progress' && !d.timedOut),
    [list],
  )
  const hasError = useMemo(() => list.some((d) => Boolean(d.error)), [list])
  const hasTimedOut = useMemo(() => list.some((d) => Boolean(d.timedOut)), [list])

  return { deployments, list, register, hasActive, hasError, hasTimedOut }
}
