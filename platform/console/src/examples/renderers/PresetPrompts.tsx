import type { ExamplePresentation } from '../registry'

/** Clickable preset-prompt chips. Supports flat prompts or grouped-by-tab. */
export function PresetPrompts({
  presentation,
  onPick,
  disabled,
}: {
  presentation: ExamplePresentation
  onPick: (prompt: string) => void
  disabled?: boolean
}) {
  const groups = presentation.promptGroups
  if (groups) {
    return (
      <div className="space-y-3">
        {Object.entries(groups).map(([tab, prompts]) => (
          <div key={tab}>
            <div className="text-xs font-semibold uppercase tracking-wide text-brand-400 mb-1">
              {tab}
            </div>
            <div className="flex flex-wrap gap-2">
              {prompts.map((p) => (
                <PromptChip key={p} prompt={p} onPick={onPick} disabled={disabled} />
              ))}
            </div>
          </div>
        ))}
      </div>
    )
  }
  return (
    <div className="flex flex-wrap gap-2">
      {presentation.presetPrompts.map((p) => (
        <PromptChip key={p} prompt={p} onPick={onPick} disabled={disabled} />
      ))}
    </div>
  )
}

function PromptChip({
  prompt,
  onPick,
  disabled,
}: {
  prompt: string
  onPick: (p: string) => void
  disabled?: boolean
}) {
  const label = prompt.length > 70 ? prompt.slice(0, 70) + '…' : prompt
  return (
    <button
      onClick={() => onPick(prompt)}
      disabled={disabled}
      title={prompt}
      className="text-left text-xs px-3 py-1.5 rounded-full border border-surface-border bg-surface-panel text-brand-200 hover:border-accent/50 hover:text-brand-50 disabled:opacity-50 transition-colors"
    >
      {label}
    </button>
  )
}
