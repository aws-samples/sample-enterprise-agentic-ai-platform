interface WorkspaceHeaderProps {
  icon?: string
  title: string
  subtitle: string
  persona: string
}

export function WorkspaceHeader({ title, subtitle, persona }: WorkspaceHeaderProps) {
  return (
    <div className="mb-6 pb-4 border-b border-surface-border">
      <div className="flex items-baseline justify-between">
        <div>
          <h1 className="text-lg font-semibold text-brand-50 tracking-tight">{title}</h1>
          <p className="text-sm text-brand-300 mt-0.5">{subtitle}</p>
        </div>
        <span className="shrink-0 inline-flex items-center gap-1.5 rounded-md border border-accent/40 bg-accent/10 px-2.5 py-1 text-xs font-medium text-brand-100">
          <span className="uppercase tracking-wider text-accent-fg font-semibold">Persona</span>
          <span className="h-3 w-px bg-accent/40" aria-hidden="true" />
          <span>{persona}</span>
        </span>
      </div>
    </div>
  )
}
