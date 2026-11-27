import type { ReactNode } from 'react'

/**
 * Tabs — a small, shared tab-bar primitive used across the console agent views
 * (Chat | Architecture | Logs). Extracted from the inline tab bar that lived in
 * ChatRenderer so ADE, the Examples patterns, and the App-Directory detail view
 * all render an identical control.
 *
 * Controlled: the parent owns the active key and passes `onChange`. Panels are
 * rendered by the parent (this component only renders the tab strip), which
 * keeps panel state (chat history, log polling) mounted across switches.
 */

export interface TabDef {
  key: string
  label: ReactNode
  /** Optional: hide a tab (e.g. no topology → no Architecture tab). */
  hidden?: boolean
}

export interface TabsProps {
  tabs: TabDef[]
  active: string
  onChange: (key: string) => void
  /** Optional right-aligned content (e.g. a Clear button). */
  actions?: ReactNode
  className?: string
}

export function Tabs({ tabs, active, onChange, actions, className }: TabsProps) {
  const visible = tabs.filter((t) => !t.hidden)
  return (
    <div className={`flex items-center justify-between ${className ?? ''}`}>
      <div
        className="flex overflow-hidden rounded-md border border-surface-border"
        role="tablist"
      >
        {visible.map((t) => {
          const isActive = t.key === active
          return (
            <button
              key={t.key}
              role="tab"
              aria-selected={isActive}
              onClick={() => onChange(t.key)}
              className={`px-3 py-1 text-sm transition-colors ${
                isActive
                  ? 'bg-accent text-white'
                  : 'bg-surface-panel text-brand-300 hover:bg-surface-elevated hover:text-brand-50'
              }`}
            >
              {t.label}
            </button>
          )
        })}
      </div>
      {actions}
    </div>
  )
}
