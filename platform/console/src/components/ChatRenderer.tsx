import React, { useState, useRef, useEffect, useCallback, useMemo, createElement, type ReactNode } from 'react'
import { marked } from 'marked'
import DOMPurify from 'dompurify'
import { useAuth } from '../auth/CognitoProvider'
import { streamAgent, type AuthMode, type Attachment } from '../services/agentStream'
import { canSend } from '../workspaces/build/messageGuard'

export interface ChatRendererProps {
  agentEndpoint: string
  agentName: string
  agentDescription?: string
  /**
   * Optional target runtime ARN override. When supplied it is passed through to
   * a2aClient/invoke as the invocation target (per-agent chat, Req 11.1). When
   * omitted, the invoke proxy defaults to the Studio runtime.
   */
  agentArn?: string
  architecture?: 'supervisor' | 'swarm' | 'sequential' | string
  /**
   * Stable session id. Combined with `agentName` it partitions the per-session
   * localStorage conversation cache (`console-chat:{userId}:{agentName}`), so
   * callers can key a distinct conversation per design session / per agent.
   */
  sessionId?: string
  /**
   * Fires once with the completed agent response text after a streamed turn
   * finishes (non-empty responses only). Lets a parent run phase detection,
   * exec-ID extraction, and manifest extraction on completed turns without
   * duplicating the streaming loop.
   */
  onAgentMessage?: (text: string) => void
  /**
   * Optional maximum message length (trimmed). When set, a message whose
   * trimmed length exceeds this bound is blocked from sending, mirroring the
   * shared `canSend` guard. When omitted there is no upper bound (Req 9.10).
   */
  maxLength?: number
  /**
   * Fires with the user's message text at send time, right after the
   * empty/maxLength guard passes and before the agent invoke. Lets a parent
   * record the outgoing user turn (e.g. to derive a session title, Req 1.3).
   */
  onUserMessage?: (text: string) => void
  /**
   * A prompt the parent wants programmatically sent. When it changes to a
   * non-empty value, the chat input is populated with it and auto-sent once,
   * then `onPendingInputConsumed` is invoked so the parent can clear it
   * (Req 3.3). Re-sending of the same value is guarded against.
   */
  pendingInput?: string
  /** Called once after a non-empty `pendingInput` has been consumed (Req 3.3). */
  onPendingInputConsumed?: () => void
  /**
   * The first-party invoke endpoint this chat POSTs to. All chat surfaces now
   * stream through an always-on ECS/Fargate backend behind an ALB — no API
   * Gateway anywhere:
   *   - `/ade-api/invoke`      — the ADE design chat AND every deployed-agent
   *     chat (the agent's runtime ARN is passed as the target; the backend
   *     enforces the Requirement-11 allow-list). This is the default.
   *   - `/examples-api/invoke` — the Examples surface (JWT + lifecycle
   *     allow-list, ADR-046).
   * The SSE wire format is identical across them (`data: {type,text}` …
   * `data: [DONE]`), and turns render token-by-token.
   */
  invokeEndpoint?: string
  /**
   * Auth mode for the streaming invoke. `'cognito'` (default) forwards the
   * user's bearer JWT — required by both `/ade-api` and `/examples-api`
   * (each validates it in-service). `'none'` sends no auth header; no
   * first-party backend accepts that today.
   */
  authMode?: AuthMode
}

interface ChatMessage {
  role: 'user' | 'agent'
  text: string
  timestamp: number
  /** File names attached to a user turn (rendered as chips; bytes not persisted). */
  attachments?: { name: string; mimeType: string }[]
}

/** Accepted upload types + caps for the ADE chat file picker. */
const ACCEPTED_FILE_TYPES = 'image/*,application/pdf,text/*,.md,.json,.csv,.yaml,.yml'
const MAX_UPLOAD_BYTES = 10 * 1024 * 1024 // 10 MB total per turn (matches backend)

/** Read a File into base64 (no data: prefix), for an A2A FilePart. */
function fileToBase64(file: File): Promise<string> {
  return new Promise((resolve, reject) => {
    const reader = new FileReader()
    reader.onload = () => {
      const result = reader.result as string
      // strip the "data:<mime>;base64," prefix
      const comma = result.indexOf(',')
      resolve(comma >= 0 ? result.slice(comma + 1) : result)
    }
    reader.onerror = () => reject(reader.error ?? new Error('file read failed'))
    reader.readAsDataURL(file)
  })
}

/** A staged upload held in the composer before the turn is sent. */
interface StagedFile {
  name: string
  mimeType: string
  size: number
  bytes: string // base64
}

interface ConversationData {
  sessionId: string
  messages: ChatMessage[]
  lastUpdated: number
}

function getStorageKey(userId: string, agentName: string): string {
  return `console-chat:${userId}:${agentName}`
}

function loadConversation(userId: string, agentName: string): ConversationData | null {
  try {
    const raw = localStorage.getItem(getStorageKey(userId, agentName))
    if (!raw) return null
    return JSON.parse(raw)
  } catch {
    return null
  }
}

function saveConversation(userId: string, agentName: string, data: ConversationData): void {
  localStorage.setItem(getStorageKey(userId, agentName), JSON.stringify(data))
}

// DOMPurify allowlist for agent Markdown (see MarkdownView).
const SANITIZE_CONFIG = {
  USE_PROFILES: { html: true },
  FORBID_TAGS: ['style', 'form', 'input', 'button', 'textarea', 'select'],
  FORBID_ATTR: ['style'],
}

// DOM attribute names whose React prop name differs.
const REACT_ATTR_NAMES: Record<string, string> = {
  class: 'className',
  for: 'htmlFor',
  colspan: 'colSpan',
  rowspan: 'rowSpan',
  tabindex: 'tabIndex',
  srcset: 'srcSet',
  crossorigin: 'crossOrigin',
  referrerpolicy: 'referrerPolicy',
  datetime: 'dateTime',
}

// Elements React must render without children.
const VOID_ELEMENTS = new Set(['br', 'hr', 'img', 'wbr', 'col', 'area', 'source', 'track'])

// Table elements that may not contain whitespace text nodes in React.
const TABLE_ELEMENTS = new Set(['table', 'thead', 'tbody', 'tfoot', 'tr', 'colgroup'])

// Convert a sanitized DOM node into React elements. Text becomes React text
// nodes (escaped by React), so no HTML string is ever injected into the page.
function domToReact(node: Node, key: string): ReactNode {
  if (node.nodeType === Node.TEXT_NODE) return node.textContent
  if (node.nodeType !== Node.ELEMENT_NODE) return null
  const el = node as Element
  const tag = el.tagName.toLowerCase()
  const props: Record<string, string> = { key }
  for (const attr of Array.from(el.attributes)) {
    props[REACT_ATTR_NAMES[attr.name] ?? attr.name] = attr.value
  }
  if (VOID_ELEMENTS.has(tag)) return createElement(tag, props)
  const children = Array.from(el.childNodes)
    .filter((child) => !(TABLE_ELEMENTS.has(tag) && child.nodeType === Node.TEXT_NODE && !child.textContent?.trim()))
    .map((child, i) => domToReact(child, `${key}.${i}`))
  return createElement(tag, props, ...children)
}

/**
 * Render agent Markdown as React elements. Agent output is untrusted (it can
 * carry text from prompt-injected web pages, documents or tool results), so
 * the HTML marked produces is sanitized with DOMPurify into a DOM fragment:
 * scripts, event handlers, javascript: URLs, iframes, forms and similar are
 * removed. The fragment is then converted to React elements, so no HTML
 * string is injected into the page. Every render of agent Markdown must use
 * this component (threat model T-008).
 */
export function MarkdownView({ text, className }: { text: string; className?: string }) {
  const content = useMemo(() => {
    if (!text) return null
    const html = marked.parse(text, { async: false }) as string
    const fragment = DOMPurify.sanitize(html, { ...SANITIZE_CONFIG, RETURN_DOM_FRAGMENT: true })
    return Array.from(fragment.childNodes).map((child, i) => domToReact(child, String(i)))
  }, [text])
  return <div className={className}>{content}</div>
}

// Links in agent output open in a new tab without giving the target page a
// handle on this window (reverse tabnabbing).
DOMPurify.addHook('afterSanitizeAttributes', (node) => {
  if (node.tagName === 'A' && node.getAttribute('href')) {
    node.setAttribute('target', '_blank')
    node.setAttribute('rel', 'noopener noreferrer')
  }
})

/**
 * Whether a string is a syntactically valid Bedrock AgentCore runtime ARN.
 *
 * The invoke proxy validates any supplied target against the discovered-runtime
 * allow-list and rejects non-ARN values with HTTP 400. Consumers like the ADE
 * chat and the App Directory pass a synthetic runtime URL as `agentEndpoint`
 * (there is no real ARN client-side), so we only forward a target when it is an
 * actual ARN — otherwise we send none and the proxy falls back to its default
 * (Studio) runtime, matching the pre-validation behavior.
 */
const RUNTIME_ARN_RE = /^arn:aws[a-z-]*:bedrock-agentcore:[a-z0-9-]+:\d{12}:runtime\/[A-Za-z0-9_.-]+$/
function isRuntimeArn(value: string | undefined): value is string {
  return !!value && RUNTIME_ARN_RE.test(value)
}

export function ChatRenderer({ agentEndpoint, agentName, agentDescription, agentArn, sessionId: initialSessionId, onAgentMessage, maxLength, onUserMessage, pendingInput, onPendingInputConsumed, invokeEndpoint = '/api/invoke', authMode = 'cognito' }: ChatRendererProps) {
  const { token, userId, login } = useAuth()
  const [messages, setMessages] = useState<ChatMessage[]>([])
  const [input, setInput] = useState('')
  const [isStreaming, setIsStreaming] = useState(false)
  const [sessionId, setSessionId] = useState(initialSessionId || crypto.randomUUID())
  const [stagedFiles, setStagedFiles] = useState<StagedFile[]>([])
  const [fileError, setFileError] = useState<string | null>(null)
  const messagesEndRef = useRef<HTMLDivElement>(null)
  const inputRef = useRef<HTMLTextAreaElement>(null)
  const fileInputRef = useRef<HTMLInputElement>(null)

  // Read + stage picked files (base64), enforcing the total-size cap. Runs on
  // the file-input change; clears the input so the same file can be re-picked.
  const handleFilesPicked = useCallback(
    async (fileList: FileList | null) => {
      if (!fileList || fileList.length === 0) return
      setFileError(null)
      const picked = Array.from(fileList)
      try {
        const staged: StagedFile[] = []
        for (const f of picked) {
          staged.push({
            name: f.name,
            mimeType: f.type || 'application/octet-stream',
            size: f.size,
            bytes: await fileToBase64(f),
          })
        }
        setStagedFiles((prev) => {
          const next = [...prev, ...staged]
          const total = next.reduce((n, s) => n + s.size, 0)
          if (total > MAX_UPLOAD_BYTES) {
            setFileError(
              `Attachments exceed ${Math.round(MAX_UPLOAD_BYTES / (1024 * 1024))} MB. Remove a file and try again.`,
            )
            return prev
          }
          return next
        })
      } catch {
        setFileError('Could not read one of the selected files.')
      } finally {
        if (fileInputRef.current) fileInputRef.current.value = ''
      }
    },
    [],
  )

  const removeStagedFile = useCallback((idx: number) => {
    setStagedFiles((prev) => prev.filter((_, i) => i !== idx))
    setFileError(null)
  }, [])

  // Load persisted conversation on mount
  useEffect(() => {
    const saved = loadConversation(userId, agentName)
    if (saved) {
      setMessages(saved.messages)
      setSessionId(saved.sessionId)
    }
  }, [userId, agentName])

  // Persist conversation on message changes
  useEffect(() => {
    if (messages.length > 0) {
      saveConversation(userId, agentName, {
        sessionId,
        messages,
        lastUpdated: Date.now(),
      })
    }
  }, [messages, sessionId, userId, agentName])

  // Auto-scroll to bottom
  useEffect(() => {
    messagesEndRef.current?.scrollIntoView({ behavior: 'smooth' })
  }, [messages])

  const sendMessage = useCallback(async (rawText: string) => {
    const trimmed = rawText.trim()
    // A turn is sendable if it has text OR at least one staged file. Empty text
    // is allowed when files are attached (e.g. "here's a diagram"). The length
    // guard still applies to the text (Req 2.2, 9.10). Skip while streaming.
    const hasFiles = stagedFiles.length > 0
    if (isStreaming) return
    if (!hasFiles && !canSend(rawText, maxLength ?? Infinity)) return
    if (hasFiles && trimmed.length > (maxLength ?? Infinity)) return

    // Snapshot + clear the staged files for this turn.
    const attachments: Attachment[] = stagedFiles.map((f) => ({
      bytes: f.bytes,
      mimeType: f.mimeType,
      name: f.name,
    }))
    const attachmentMeta = stagedFiles.map((f) => ({ name: f.name, mimeType: f.mimeType }))
    setStagedFiles([])
    setFileError(null)

    // Notify the parent of the outgoing user turn before the invoke (Req 1.3).
    onUserMessage?.(trimmed)

    const userMsg: ChatMessage = {
      role: 'user',
      text: trimmed,
      timestamp: Date.now(),
      attachments: attachmentMeta.length ? attachmentMeta : undefined,
    }
    setMessages(prev => [...prev, userMsg])
    setInput('')
    setIsStreaming(true)

    let agentText = ''
    try {
      // Only forward a target ARN when it is a real runtime ARN (per-agent
      // chat via AgentDetailView). For ADE/App-Directory chat the endpoint is a
      // synthetic URL, so we send no target and the proxy uses the default
      // Studio runtime — avoids a 400 from the proxy's targetArn validation.
      const targetArn = isRuntimeArn(agentArn) ? agentArn : undefined
      for await (const event of streamAgent({
        endpoint: invokeEndpoint,
        message: trimmed,
        sessionId,
        authMode,
        token: token || '',
        agentArn: targetArn,
        attachments: attachments.length ? attachments : undefined,
        onUnauthorized: login,
      })) {
        if (event.type === 'chunk' && event.text) {
          agentText += event.text
          setMessages(prev => {
            const updated = [...prev]
            const lastMsg = updated[updated.length - 1]
            if (lastMsg?.role === 'agent') {
              updated[updated.length - 1] = { ...lastMsg, text: agentText }
            } else {
              updated.push({ role: 'agent', text: agentText, timestamp: Date.now() })
            }
            return updated
          })
        } else if (event.type === 'final' && event.text) {
          agentText = event.text
          setMessages(prev => {
            const updated = [...prev]
            const lastMsg = updated[updated.length - 1]
            if (lastMsg?.role === 'agent') {
              updated[updated.length - 1] = { ...lastMsg, text: agentText }
            } else {
              updated.push({ role: 'agent', text: agentText, timestamp: Date.now() })
            }
            return updated
          })
        } else if (event.type === 'error') {
          const errorText = agentText
            ? agentText + ' [Connection interrupted]'
            : event.text || 'An error occurred'
          setMessages(prev => {
            const updated = [...prev]
            const lastMsg = updated[updated.length - 1]
            if (lastMsg?.role === 'agent') {
              updated[updated.length - 1] = { ...lastMsg, text: errorText }
            } else {
              updated.push({ role: 'agent', text: errorText, timestamp: Date.now() })
            }
            return updated
          })
        } else if (event.type === 'session' && event.sessionId) {
          setSessionId(event.sessionId)
        }
      }

      // Notify the parent of a completed turn so it can run phase detection,
      // exec-ID extraction, and manifest extraction without duplicating the
      // streaming loop. Only fires for non-empty responses (Req 2.1, 16.1).
      if (agentText) {
        onAgentMessage?.(agentText)
      }

      // If no agent text arrived (empty/failed response), always surface a
      // visible message so the user never sees silent nothing.
      if (!agentText) {
        const fallback = 'No response from the agent. It may still be starting up (cold start) or unavailable — try again in a moment.'
        setMessages(prev => {
          const updated = [...prev]
          const lastMsg = updated[updated.length - 1]
          if (lastMsg?.role === 'agent' && !lastMsg.text) {
            updated[updated.length - 1] = { ...lastMsg, text: fallback }
            return updated
          }
          if (lastMsg?.role !== 'agent') {
            return [...updated, { role: 'agent', text: fallback, timestamp: Date.now() }]
          }
          return updated
        })
      }
    } catch {
      const errorText = agentText
        ? agentText + ' [Connection interrupted]'
        : 'Agent unreachable. Check agent status in App Directory.'
      setMessages(prev => {
        const updated = [...prev]
        const lastMsg = updated[updated.length - 1]
        if (lastMsg?.role === 'agent') {
          updated[updated.length - 1] = { ...lastMsg, text: errorText }
        } else {
          updated.push({ role: 'agent', text: errorText, timestamp: Date.now() })
        }
        return updated
      })
    } finally {
      setIsStreaming(false)
    }
  }, [isStreaming, maxLength, onUserMessage, agentEndpoint, agentArn, sessionId, token, login, onAgentMessage, invokeEndpoint, authMode, stagedFiles])

  const handleSend = useCallback(() => {
    void sendMessage(input)
  }, [sendMessage, input])

  // Programmatic send from the parent (Req 3.3). When `pendingInput` changes to
  // a non-empty value, populate the input and auto-send it once, then notify
  // the parent so it can clear the pending value. The ref guards against
  // re-sending the same value on unrelated re-renders.
  const pendingSentRef = useRef<string | null>(null)
  useEffect(() => {
    if (!pendingInput) {
      pendingSentRef.current = null
      return
    }
    if (pendingSentRef.current === pendingInput) return
    pendingSentRef.current = pendingInput
    setInput(pendingInput)
    void sendMessage(pendingInput)
    onPendingInputConsumed?.()
  }, [pendingInput, sendMessage, onPendingInputConsumed])

  const handleKeyDown = (e: React.KeyboardEvent) => {
    if (e.key === 'Enter' && !e.shiftKey) {
      e.preventDefault()
      handleSend()
    }
  }

  const clearConversation = () => {
    setMessages([])
    setSessionId(crypto.randomUUID())
    localStorage.removeItem(getStorageKey(userId, agentName))
  }

  return (
    <div className="flex flex-col h-full">
      {/* Header. ChatRenderer is a PURE chat pane — Architecture / Logs /
          topology live in UnifiedAgentView's inspector rail, not here, so this
          no longer carries a viz tab or placeholder. */}
      <div className="flex items-center justify-between px-4 py-3 border-b border-gray-700 bg-gray-800">
        <div>
          <h2 className="text-lg font-semibold text-white">{agentName}</h2>
          {agentDescription && <p className="text-sm text-gray-400">{agentDescription}</p>}
        </div>
        <div className="flex items-center gap-2">
          <button
            onClick={clearConversation}
            className="text-xs text-gray-400 hover:text-white px-2 py-1 rounded border border-gray-600 hover:border-gray-400"
            title="Clear conversation"
          >
            Clear
          </button>
        </div>
      </div>

      {/* Messages area */}
      {(
        <div className="flex-1 overflow-y-auto px-4 py-4 space-y-4" role="log" aria-live="polite">
          {messages.length === 0 && (
            agentName.startsWith('ade:') ? (
              <div className="mx-auto mt-6 max-w-2xl rounded-lg border border-gray-700 bg-gray-800/60 px-5 py-4 text-sm leading-relaxed text-gray-200">
                <p className="mb-2 text-base font-semibold text-white">👋 I'm the Agent Deployment Engineer</p>
                <p className="mb-3 text-gray-300">
                  I turn plain-language intent into deployed, production-grade AI agents on
                  Amazon Bedrock AgentCore — no code, no infrastructure tickets. Describe
                  what you want in your own words and I'll choose the right multi-agent
                  architecture (standalone, supervisor, sequential, or swarm), scaffold it,
                  and deploy it for you.
                </p>
                <p className="mb-1 font-medium text-gray-100">Why EAP</p>
                <p className="mb-3 text-gray-300">
                  Every business unit wants AI agents, but building each one from scratch means
                  re-solving identity, security, observability, deployment, and governance —
                  months of undifferentiated work. EAP is the shared foundation that
                  handles all of it, so any team can <span className="text-gray-100">Build · Govern · Run · Evolve</span> agents
                  at enterprise scale, each within central guardrails and its own blast radius.
                </p>
                <p className="mb-1 font-medium text-gray-100">Try asking me to:</p>
                <ul className="ml-4 list-disc space-y-0.5 text-gray-300">
                  <li>"Build an agent that reviews AWS architectures for security best practices."</li>
                  <li>"Create a research team that searches the web and writes a summary report."</li>
                  <li>"Design a data pipeline that extracts, enriches, and summarizes documents."</li>
                </ul>
                <p className="mt-3 text-gray-400">Describe your agent below to get started.</p>
              </div>
            ) : (
              <div className="text-center text-gray-500 mt-8">
                <p>Start a conversation with {agentName}</p>
              </div>
            )
          )}
          {messages.map((msg, i) => (
            <div key={i} className={`flex ${msg.role === 'user' ? 'justify-end' : 'justify-start'}`}>
              <div
                className={`max-w-[80%] rounded-lg px-4 py-2 ${
                  msg.role === 'user'
                    ? 'bg-blue-600 text-white'
                    : 'bg-gray-700 text-gray-100'
                }`}
              >
                {msg.role === 'agent' ? (
                  <MarkdownView className="prose prose-invert prose-sm max-w-none" text={msg.text} />
                ) : (
                  <div>
                    {msg.attachments && msg.attachments.length > 0 && (
                      <div className="mb-1.5 flex flex-wrap gap-1.5">
                        {msg.attachments.map((a, ai) => (
                          <span
                            key={`${a.name}-${ai}`}
                            className="flex items-center gap-1 rounded bg-blue-500/40 px-1.5 py-0.5 text-[11px]"
                            title={a.name}
                          >
                            <span aria-hidden>{a.mimeType.startsWith('image/') ? '🖼️' : a.mimeType === 'application/pdf' ? '📄' : '📎'}</span>
                            <span className="max-w-[10rem] truncate">{a.name}</span>
                          </span>
                        ))}
                      </div>
                    )}
                    {msg.text && <p className="text-sm whitespace-pre-wrap">{msg.text}</p>}
                  </div>
                )}
              </div>
            </div>
          ))}
          {isStreaming && (
            <div className="flex justify-start">
              <div className="bg-gray-700 rounded-lg px-4 py-2">
                <span className="text-gray-400 animate-pulse">●●●</span>
              </div>
            </div>
          )}
          <div ref={messagesEndRef} />
        </div>
      )}

      {/* Input area */}
      <div className="px-4 py-3 border-t border-gray-700 bg-gray-800">
        {/* Staged-file chips (attachments queued for the next turn) */}
        {stagedFiles.length > 0 && (
          <div className="mb-2 flex flex-wrap gap-2">
            {stagedFiles.map((f, i) => (
              <span
                key={`${f.name}-${i}`}
                className="flex items-center gap-1.5 rounded-full border border-gray-600 bg-gray-700 px-2.5 py-1 text-xs text-gray-200"
                title={`${f.name} (${(f.size / 1024).toFixed(0)} KB)`}
              >
                <span aria-hidden>{f.mimeType.startsWith('image/') ? '🖼️' : f.mimeType === 'application/pdf' ? '📄' : '📎'}</span>
                <span className="max-w-[12rem] truncate">{f.name}</span>
                <button
                  type="button"
                  onClick={() => removeStagedFile(i)}
                  className="ml-0.5 text-gray-400 hover:text-red-300"
                  aria-label={`Remove ${f.name}`}
                >
                  ×
                </button>
              </span>
            ))}
          </div>
        )}
        {fileError && (
          <p role="alert" className="mb-2 text-xs text-red-400">{fileError}</p>
        )}
        <div className="flex gap-2">
          {/* Hidden native picker + attach button */}
          <input
            ref={fileInputRef}
            type="file"
            multiple
            accept={ACCEPTED_FILE_TYPES}
            className="hidden"
            onChange={(e) => void handleFilesPicked(e.target.files)}
            aria-hidden="true"
            tabIndex={-1}
          />
          <button
            type="button"
            onClick={() => fileInputRef.current?.click()}
            disabled={isStreaming}
            className="shrink-0 rounded-lg border border-gray-600 px-3 py-2 text-sm text-gray-300 hover:border-gray-400 hover:text-white disabled:opacity-50 disabled:cursor-not-allowed"
            title="Attach files (images, PDFs, text)"
            aria-label="Attach files"
          >
            📎
          </button>
          <textarea
            ref={inputRef}
            value={input}
            onChange={e => setInput(e.target.value)}
            onKeyDown={handleKeyDown}
            placeholder={`Message ${agentName}...`}
            className="flex-1 bg-gray-700 text-white rounded-lg px-4 py-2 resize-none focus:outline-none focus:ring-2 focus:ring-blue-500 text-sm"
            rows={1}
            disabled={isStreaming}
            aria-label={`Message input for ${agentName}`}
          />
          <button
            onClick={handleSend}
            disabled={isStreaming || (!input.trim() && stagedFiles.length === 0)}
            className="px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-500 disabled:opacity-50 disabled:cursor-not-allowed text-sm font-medium"
            aria-label="Send message"
          >
            Send
          </button>
        </div>
      </div>
    </div>
  )
}
