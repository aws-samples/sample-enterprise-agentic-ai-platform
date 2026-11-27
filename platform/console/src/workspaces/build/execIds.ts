/**
 * execIds.ts — CodePipeline execution-ID extraction (Req 7.1)
 *
 * Pure helper that harvests CodePipeline execution identifiers from an ADE
 * reply so the Deployment_Tracker can register them and poll status. Mirrors
 * the standalone Studio UI's `execIdRegex` behaviour
 * (platform/demo-ui/standalone/agent-builder-studio-ui/src/App.tsx):
 * a 36-character UUID in 8-4-4-4-12 hex form, matched case-insensitively.
 *
 * No external dependencies.
 */

// 8-4-4-4-12 hex UUID, matched case-insensitively (lower/upper hex) with word
// boundaries, same as the standalone UI's execIdRegex. Recreated per call so
// the shared regex's `lastIndex` never leaks between invocations.
const EXEC_ID_PATTERN =
  '\\b([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\\b'

/**
 * Extract CodePipeline execution IDs from `text`.
 *
 * @param text    Arbitrary text (typically a completed ADE turn) to scan.
 * @param tracked Execution IDs already being tracked; matches present here are
 *                excluded from the result. Accepts a Set or an array.
 * @returns The execution IDs found in `text`, excluding any already tracked,
 *          deduplicated, in first-seen order.
 */
export function extractExecutionIds(
  text: string,
  tracked: Set<string> | string[],
): string[] {
  if (!text) return []

  const trackedSet = tracked instanceof Set ? tracked : new Set(tracked)
  const seen = new Set<string>()
  const result: string[] = []

  const regex = new RegExp(EXEC_ID_PATTERN, 'gi')
  for (const match of text.matchAll(regex)) {
    const executionId = match[1]
    if (trackedSet.has(executionId) || seen.has(executionId)) continue
    seen.add(executionId)
    result.push(executionId)
  }

  return result
}
