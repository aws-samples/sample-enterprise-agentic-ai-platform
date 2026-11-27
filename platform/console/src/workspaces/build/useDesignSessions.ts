// Design-session state + persistence for the Build workspace (Console Studio
// parity).
//
// Ports the conversation-management logic from the standalone Agent Builder
// Studio UI (`platform/demo-ui/standalone/agent-builder-studio-ui/src/App.tsx`)
// into a reusable React hook that BuildWorkspace (task 9.1) consumes.
//
// Responsibilities (Requirement 1 + Requirement 6.4):
//   - create / select / delete named design sessions (Conversation[])
//   - persist sessions per authenticated Cognito `sub` under
//       `console-build-sessions:{sub}`   (the session list)
//       `console-build-active:{sub}`      (the active session id)
//   - derive a session title from the first non-empty user message (1.3)
//   - restore the previously active session on load (1.8)
//   - track a monotonic per-session `phase` (6.4)
//   - preserve in-memory state and surface an error flag when a localStorage
//     write fails (1.9)
//
// The `sub` is read from `useAuth().userId` (the Cognito subject claim).
//
// Pure helpers (key builders, load/save, title derivation, the delete reducer,
// and the session factory) are exported alongside the hook so they can be unit-
// and property-tested in isolation (task 4.2).

import { useCallback, useEffect, useRef, useState } from 'react'
import { useAuth } from '../../auth/CognitoProvider'
import type { Conversation, Message } from './types'

/** Default title for a freshly created session (before the first message). */
export const DEFAULT_SESSION_TITLE = 'New Design Session'

/** Maximum length of a derived session title (Req 1.3). */
export const TITLE_MAX_LENGTH = 50

// --- localStorage key builders (sub-scoped, Req 1.2) ---

/** localStorage key holding the session list for a Cognito `sub`. */
export function sessionsKey(sub: string): string {
  return `console-build-sessions:${sub}`
}

/** localStorage key holding the active session id for a Cognito `sub`. */
export function activeKey(sub: string): string {
  return `console-build-active:${sub}`
}

// --- Pure persistence helpers ---

/**
 * Load the persisted session list for `sub`. Returns an empty list when nothing
 * is stored or the stored value cannot be parsed (never throws).
 */
export function loadSessions(sub: string): Conversation[] {
  if (!sub) return []
  try {
    const raw = localStorage.getItem(sessionsKey(sub))
    if (!raw) return []
    const parsed = JSON.parse(raw)
    return Array.isArray(parsed) ? (parsed as Conversation[]) : []
  } catch {
    return []
  }
}

/**
 * Persist the session list for `sub`. Throws if the underlying write fails
 * (e.g. quota exceeded); callers wrap this to surface the error flag (Req 1.9).
 */
export function saveSessions(sub: string, sessions: Conversation[]): void {
  localStorage.setItem(sessionsKey(sub), JSON.stringify(sessions))
}

/** Load the persisted active session id for `sub`, or null (never throws). */
export function loadActiveId(sub: string): string | null {
  if (!sub) return null
  try {
    return localStorage.getItem(activeKey(sub))
  } catch {
    return null
  }
}

/** Persist the active session id for `sub`. Throws on write failure. */
export function saveActiveId(sub: string, id: string | null): void {
  if (id === null) {
    localStorage.removeItem(activeKey(sub))
  } else {
    localStorage.setItem(activeKey(sub), id)
  }
}

// --- Pure factory / derivation helpers ---

/**
 * Create a new, empty {@link Conversation} with a unique id, a default title,
 * an empty message list, and phase 0 (Req 1.1, 6.1).
 */
export function createConversation(): Conversation {
  const now = Date.now()
  return {
    id: crypto.randomUUID(),
    title: DEFAULT_SESSION_TITLE,
    createdAt: now,
    updatedAt: now,
    phase: 0,
    messages: [],
  }
}

/**
 * Derive a session title from a message: trim leading/trailing whitespace, then
 * take the first {@link TITLE_MAX_LENGTH} characters (Req 1.3).
 */
export function deriveTitle(text: string): string {
  return text.trim().slice(0, TITLE_MAX_LENGTH)
}

/** True when a session has no user-authored message yet. */
function hasNoUserMessage(session: Conversation): boolean {
  return !session.messages.some((m) => m.role === 'user')
}

/**
 * Pure delete reducer implementing the deletion rules (Req 1.5, 1.6, 1.7).
 *
 *  - Deleting a non-active session leaves the active session unchanged (1.7).
 *  - Deleting the active session while others remain activates the
 *    most-recently-updated remaining session (1.5).
 *  - Deleting the active session while none remain creates a new empty session
 *    and makes it active (1.6).
 *
 * Returns the next session list and active id. When a fresh session is created
 * (1.6) it is included in the returned list.
 */
export function applyDelete(
  sessions: Conversation[],
  activeId: string | null,
  deleteId: string,
): { sessions: Conversation[]; activeId: string | null } {
  const remaining = sessions.filter((s) => s.id !== deleteId)

  // Req 1.7: deleting a non-active session — active unchanged.
  if (deleteId !== activeId) {
    return { sessions: remaining, activeId }
  }

  // Req 1.5: deleting the active session with others remaining — activate the
  // most-recently-updated remaining session.
  if (remaining.length > 0) {
    const mostRecent = remaining.reduce((a, b) => (b.updatedAt > a.updatedAt ? b : a))
    return { sessions: remaining, activeId: mostRecent.id }
  }

  // Req 1.6: deleting the active session with none remaining — new empty
  // session becomes active.
  const fresh = createConversation()
  return { sessions: [fresh], activeId: fresh.id }
}

// --- The hook ---

export interface UseDesignSessions {
  /** All design sessions for the current user (most-recently-created first). */
  sessions: Conversation[]
  /** The active session id, or null when there is no active session. */
  activeSessionId: string | null
  /** The active session, or null when there is no active session. */
  activeSession: Conversation | null
  /** True when the most recent localStorage write failed (Req 1.9). */
  persistError: boolean
  /** Create a new empty session, make it active, and return its id (Req 1.1). */
  createSession: () => string
  /** Make an existing session active, restoring its history/phase (Req 1.4). */
  selectSession: (id: string) => void
  /** Delete a session, applying the deletion rules (Req 1.5–1.7). */
  deleteSession: (id: string) => void
  /** Append a message to the active session, deriving the title on the first
   *  non-empty user message (Req 1.3) and bumping `updatedAt`. */
  appendMessage: (message: Message) => void
  /** Replace the active session's messages (mirror from ChatRenderer),
   *  deriving the title from the first user message when still default. */
  setMessages: (messages: Message[]) => void
  /** Set the active session's phase (monotonicity enforced by the caller). */
  setPhase: (phase: number) => void
}

/**
 * Manage the current user's design sessions with sub-scoped localStorage
 * persistence. See the module header and {@link UseDesignSessions} for the
 * behavioural contract.
 */
export function useDesignSessions(): UseDesignSessions {
  const { userId: sub } = useAuth()

  const [sessions, setSessions] = useState<Conversation[]>([])
  const [activeSessionId, setActiveSessionId] = useState<string | null>(null)
  const [persistError, setPersistError] = useState(false)

  // Track the sub we last loaded for, so we reload when the user changes.
  const loadedSubRef = useRef<string | null>(null)

  // Load persisted state whenever the authenticated sub changes (Req 1.8).
  useEffect(() => {
    if (loadedSubRef.current === sub) return
    loadedSubRef.current = sub

    if (!sub) {
      setSessions([])
      setActiveSessionId(null)
      setPersistError(false)
      return
    }

    const loaded = loadSessions(sub)
    setSessions(loaded)

    const savedActive = loadActiveId(sub)
    if (savedActive && loaded.some((s) => s.id === savedActive)) {
      // Restore the previously active session (Req 1.8).
      setActiveSessionId(savedActive)
    } else {
      setActiveSessionId(loaded[0]?.id ?? null)
    }
    setPersistError(false)
  }, [sub])

  /**
   * Persist the given sessions + active id, preserving in-memory state and
   * surfacing the error flag on failure (Req 1.9). Skipped when there is no
   * authenticated sub to scope the keys.
   */
  const persist = useCallback(
    (nextSessions: Conversation[], nextActive: string | null) => {
      if (!sub) return
      try {
        saveSessions(sub, nextSessions)
        saveActiveId(sub, nextActive)
        setPersistError(false)
      } catch {
        // In-memory state is already updated by the caller; only flag the error.
        setPersistError(true)
      }
    },
    [sub],
  )

  const createSession = useCallback((): string => {
    const fresh = createConversation()
    const next = [fresh, ...sessions]
    setSessions(next)
    setActiveSessionId(fresh.id)
    persist(next, fresh.id)
    return fresh.id
  }, [sessions, persist])

  const selectSession = useCallback(
    (id: string) => {
      if (!sessions.some((s) => s.id === id)) return
      setActiveSessionId(id)
      // Only the active-id pointer changes; the session list is unchanged.
      if (sub) {
        try {
          saveActiveId(sub, id)
          setPersistError(false)
        } catch {
          setPersistError(true)
        }
      }
    },
    [sessions, sub],
  )

  const deleteSession = useCallback(
    (id: string) => {
      const result = applyDelete(sessions, activeSessionId, id)
      setSessions(result.sessions)
      setActiveSessionId(result.activeId)
      persist(result.sessions, result.activeId)
    },
    [sessions, activeSessionId, persist],
  )

  /** Update the active session via `updater`, then persist. No-op if inactive. */
  const mutateActive = useCallback(
    (updater: (session: Conversation) => Conversation) => {
      if (!activeSessionId) return
      let changed = false
      const next = sessions.map((s) => {
        if (s.id !== activeSessionId) return s
        changed = true
        return updater(s)
      })
      if (!changed) return
      setSessions(next)
      persist(next, activeSessionId)
    },
    [sessions, activeSessionId, persist],
  )

  const appendMessage = useCallback(
    (message: Message) => {
      mutateActive((s) => {
        // Derive the title from the first non-empty user message (Req 1.3).
        const nextTitle =
          message.role === 'user' && hasNoUserMessage(s) && message.text.trim()
            ? deriveTitle(message.text)
            : s.title
        return {
          ...s,
          title: nextTitle,
          messages: [...s.messages, message],
          updatedAt: Date.now(),
        }
      })
    },
    [mutateActive],
  )

  const setMessages = useCallback(
    (messages: Message[]) => {
      mutateActive((s) => {
        // Derive the title when still default and a first user message exists.
        let nextTitle = s.title
        if (nextTitle === DEFAULT_SESSION_TITLE) {
          const firstUser = messages.find((m) => m.role === 'user' && m.text.trim())
          if (firstUser) nextTitle = deriveTitle(firstUser.text)
        }
        return { ...s, title: nextTitle, messages, updatedAt: Date.now() }
      })
    },
    [mutateActive],
  )

  const setPhase = useCallback(
    (phase: number) => {
      mutateActive((s) => (s.phase === phase ? s : { ...s, phase, updatedAt: Date.now() }))
    },
    [mutateActive],
  )

  const activeSession = activeSessionId
    ? sessions.find((s) => s.id === activeSessionId) ?? null
    : null

  return {
    sessions,
    activeSessionId,
    activeSession,
    persistError,
    createSession,
    selectSession,
    deleteSession,
    appendMessage,
    setMessages,
    setPhase,
  }
}
