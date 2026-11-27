// Message-validity send guard for the Build workspace (Console Studio parity).
//
// Pure, side-effect-free helper shared by the ADE chat and the deployed-agent
// detail view to decide whether a candidate message may be sent to the
// Invoke_Capability.
//
// Requirements:
//   - 2.2  The ADE chat SHALL NOT invoke the Invoke_Capability for an empty or
//          whitespace-only message. ADE chat imposes no upper length bound
//          (maxLen defaults to Infinity).
//   - 9.10 The Agent_Detail_View chat SHALL NOT invoke for an empty,
//          whitespace-only, or over-10,000-character message (maxLen = 10000).
//
// Design Property 6 (Message validity guard): for any candidate message string
// and any maximum length L, the guard permits invocation if and only if the
// trimmed string is non-empty and its length does not exceed L.

/** Maximum message length for the deployed-agent detail view chat (Req 9.10). */
export const DETAIL_VIEW_MAX_LEN = 10000

/**
 * Decide whether a candidate message may be sent to the Invoke_Capability.
 *
 * Returns `true` if and only if the message, after trimming leading and
 * trailing whitespace, is non-empty AND its length does not exceed `maxLen`.
 *
 * The length compared against `maxLen` is the trimmed length, so surrounding
 * whitespace never pushes an otherwise-valid message over the bound.
 *
 * @param text   The candidate message string.
 * @param maxLen The maximum allowed (trimmed) length. Defaults to `Infinity`
 *               for the ADE chat, which imposes no upper bound; pass
 *               `DETAIL_VIEW_MAX_LEN` (10000) for the detail-view chat.
 * @returns `true` if the message is valid to send, otherwise `false`.
 */
export function canSend(text: string, maxLen: number = Infinity): boolean {
  const trimmed = text.trim()
  return trimmed.length > 0 && trimmed.length <= maxLen
}
