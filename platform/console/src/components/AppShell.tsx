import { NavLink, Outlet } from 'react-router-dom'
import { useAuth } from '../auth/CognitoProvider'
import { usePermissions, WorkspaceKey } from '../auth/usePermissions'
import { BUSelector } from './BUSelector'

// Unified console navigation grouped into the four platform pillars
// (BUILD / SECURE / OPERATE / OPTIMIZE), matching the platform's pillar model.
// Every item stays permission-gated via usePermissions; pillars with no
// accessible items are hidden. Route paths are unchanged so workspace
// components are reused as-is — only the navigation grouping differs.
type NavItem = { path: string; label: string; scope: WorkspaceKey }
type Pillar = { id: string; label: string; items: NavItem[] }

const PILLARS: ReadonlyArray<Pillar> = [
  {
    id: 'build',
    label: 'Build',
    items: [
      { path: '/build', label: 'Agent School', scope: 'build' },
      { path: '/data', label: 'Knowledge', scope: 'data' },
    ],
  },
  {
    id: 'secure',
    label: 'Secure',
    items: [
      { path: '/governance', label: 'Policies & Audit', scope: 'governance' },
      { path: '/admin', label: 'Admin', scope: 'admin' },
    ],
  },
  {
    id: 'operate',
    label: 'Operate',
    items: [
      { path: '/apps', label: 'Agent Directory', scope: 'apps' },
      { path: '/examples', label: 'Examples', scope: 'examples' },
      { path: '/observability', label: 'Observability', scope: 'observability' },
    ],
  },
  {
    id: 'optimize',
    label: 'Optimize',
    items: [
      { path: '/quality', label: 'Quality & Certification', scope: 'quality' },
      { path: '/platform', label: 'Lifecycle State', scope: 'platform' },
    ],
  },
]

const linkClass = ({ isActive }: { isActive: boolean }) =>
  `px-3 py-1.5 text-sm font-medium rounded transition-colors ${
    isActive
      ? 'bg-accent text-white'
      : 'text-brand-200 hover:text-brand-50 hover:bg-surface-elevated'
  }`

export function AppShell() {
  const { isAuthenticated, username, login, logout } = useAuth()
  const { canAccess } = usePermissions()

  // Filter each pillar's items by permission, then drop empty pillars.
  const pillars = PILLARS.map((pillar) => ({
    ...pillar,
    items: pillar.items.filter(({ scope }) => canAccess(scope)),
  })).filter((pillar) => pillar.items.length > 0)

  return (
    <div className="min-h-screen flex flex-col bg-surface text-brand-100">
      {/* Header: row 1 = brand + punchline | user; row 2 = pillar nav */}
      <header className="bg-surface-panel border-b border-surface-border px-6">
        <div className="max-w-[2560px] mx-auto">
          {/* Row 1 — brand + punchline (left), user (right) */}
          <div className="flex items-center justify-between gap-6 py-3">
            {/* Brand — left */}
            <div className="flex items-center gap-3 min-w-0">
              <div className="w-10 h-10 shrink-0 rounded-md bg-accent flex items-center justify-center" aria-label="Enterprise Agentic AI Platform (EAP)" role="img">
                {/* Brand mark: an "E" whose three arms are the YAML doc marker (---),
                    signalling the declarative model: YAML in, infrastructure out. */}
                <svg className="w-6 h-6" viewBox="0 0 32 32" fill="none" aria-hidden="true">
                  <g fill="white">
                    {/* E stem */}
                    <rect x="6" y="5" width="5" height="22" rx="1.5" />
                    {/* E arms, drawn as the three YAML "---" bars */}
                    <rect x="6" y="5" width="20" height="4.5" rx="2.25" />
                    <rect x="6" y="13.75" width="15" height="4.5" rx="2.25" />
                    <rect x="6" y="22.5" width="20" height="4.5" rx="2.25" />
                  </g>
                </svg>
              </div>
              <div className="leading-tight min-w-0">
                <div className="flex items-baseline gap-2">
                  <span className="text-xl font-semibold text-white">Enterprise Agentic AI Platform</span>
                  <span className="text-sm text-white/70 hidden lg:inline">EAP · Open Source</span>
                </div>
                <span className="text-xs text-white/50 hidden md:block">Build, govern, and scale AI agents across every Business Unit, securely, in hours not months. Declare your agents — the platform handles the rest. · Powered by Amazon Bedrock AgentCore</span>
              </div>
            </div>

            {/* User — right */}
            <div className="shrink-0 flex items-center gap-3">
              <BUSelector />
              {isAuthenticated ? (
                <>
                  <span className="text-sm text-white hidden md:inline">{username}</span>
                  <button
                    onClick={logout}
                    className="text-sm px-3 py-1.5 rounded border border-surface-border text-brand-300 hover:text-status-error hover:border-status-error/50 transition-colors"
                  >
                    Sign Out
                  </button>
                </>
              ) : (
                <button
                  onClick={login}
                  className="text-sm px-4 py-1.5 rounded bg-accent text-white font-medium hover:bg-accent-hover transition-colors"
                >
                  Sign In
                </button>
              )}
            </div>
          </div>

          {/* Row 2 — pillar nav */}
          <nav className="flex items-stretch gap-5 border-t border-surface-border/60 py-2.5" role="navigation" aria-label="Pillars">
            {pillars.map((pillar, i) => (
              <div key={pillar.id} className="flex items-stretch gap-5">
                {i > 0 && <span className="w-px self-stretch bg-surface-border/70" aria-hidden="true" />}
                {/* Pillar column: label header stacked above its items */}
                <div className="flex flex-col gap-1">
                  <span className="text-sm font-bold uppercase tracking-wider text-brand-300 px-1 text-left">
                    {pillar.label}
                  </span>
                  <div className="flex gap-1">
                    {pillar.items.map(({ path, label }) => (
                      <NavLink key={path} to={path} className={linkClass}>
                        {label}
                      </NavLink>
                    ))}
                  </div>
                </div>
              </div>
            ))}
          </nav>
        </div>
      </header>

      {/* Content */}
      <main className="flex-1 max-w-[2560px] mx-auto w-full px-6 py-6" role="main">
        <Outlet />
      </main>
    </div>
  )
}
