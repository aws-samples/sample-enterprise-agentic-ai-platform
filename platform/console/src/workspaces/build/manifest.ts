// Manifest-block extraction for the Console Build (Studio-parity) workspace.
//
// Ports the standalone Agent Builder Studio's `extractYamlBlocks` logic
// (platform/demo-ui/standalone/agent-builder-studio-ui/src/App.tsx) into a
// pure, testable function. The standalone version only returned {label, content};
// here we additionally classify the fence language so the UI can render/copy
// YAML and JSON manifests distinctly.
//
// _Requirements: 10.1, 10.2_

import type { ManifestBlock } from './types'

/**
 * Matches fenced code blocks opened with ```yaml, ```yml, or ```json.
 *
 * - Group 1 captures the fence language token (`yaml` | `yml` | `json`).
 * - Group 2 captures the inner block text (non-greedy, up to the closing fence).
 *
 * Trailing whitespace after the language token is tolerated before the newline;
 * both `\n` and `\r\n` line endings are supported. The `g` flag drives the
 * document-order scan via `regex.exec` in a loop.
 */
const FENCED_BLOCK = /```(yaml|yml|json)[ \t]*\r?\n([\s\S]*?)```/g

/** Extracts a top-level `name:` field value from manifest content, if present. */
const NAME_FIELD = /^name:\s*(.+)$/m

/**
 * Extract YAML/JSON fenced code blocks from an ADE response as labeled,
 * copyable manifest panels.
 *
 * Scans `text` for fenced ```yaml`/```yml`/```json blocks in document order.
 * For each block:
 * - `content` is the trimmed inner text of the block.
 * - `language` is `'yaml'` for `yaml`/`yml` fences and `'json'` for `json` fences.
 * - `label` is the block's top-level `name:` field value when present, otherwise
 *   `manifest-{n}` using the 1-based position among the extracted blocks.
 *
 * Pure function: no side effects, no external state; identical input always
 * yields an identical result.
 *
 * @param text - The agent response text to scan.
 * @returns The extracted manifest blocks in document order.
 */
export function extractManifestBlocks(text: string): ManifestBlock[] {
  const blocks: ManifestBlock[] = []
  // Use a fresh regex instance to keep the function reentrant/pure despite the
  // stateful `lastIndex` of a `g`-flagged RegExp.
  const regex = new RegExp(FENCED_BLOCK.source, 'g')
  let match: RegExpExecArray | null
  while ((match = regex.exec(text)) !== null) {
    const fence = match[1].toLowerCase()
    const language: ManifestBlock['language'] = fence === 'json' ? 'json' : 'yaml'
    const content = match[2].trim()
    const nameMatch = content.match(NAME_FIELD)
    const label = nameMatch ? nameMatch[1].trim() : `manifest-${blocks.length + 1}`
    blocks.push({ label, content, language })
  }
  return blocks
}
