// AgentToolsPanel — displays the Agent Deployment Engineer's built-in tools.
//
// Unlike the GatewayToolsPanel (which lists external MCP tools registered on
// the AgentCore Gateway), these are the ADE agent's own first-party Strands
// tools — the capabilities the LLM invokes to design, validate, scaffold, and
// DEPLOY agents. They are defined in the agent code (studio/app/main.py:
// `Agent(tools=[...])`) and are not discoverable over the gateway `tools/list`
// protocol, so the list is curated here to mirror that registration.
//
// Keep this in sync with studio/app/main.py's tool list.

/** A single ADE built-in tool as surfaced to the UI. */
export interface AgentTool {
  /** The underlying Strands tool function name (studio/app/tools/*). */
  id: string
  /** Friendly display name. */
  name: string
  /** Short, plain-language description of what the tool does. */
  description: string
}

/**
 * The Agent Deployment Engineer's built-in tools, in the order the agent uses
 * them across the design → deploy workflow. Mirrors the `tools=[...]` list in
 * studio/app/main.py.
 */
export const ADE_TOOLS: AgentTool[] = [
  {
    id: 'pattern_recommender',
    name: 'Pattern Recommender',
    description:
      'Recommends the best architecture pattern (standalone, supervisor, sequential, router, swarm) for your use case.',
  },
  {
    id: 'yaml_generator',
    name: 'Manifest Generator',
    description: 'Generates agent.yaml / application.yaml manifests from your requirements.',
  },
  {
    id: 'yaml_validator',
    name: 'Manifest Validator',
    description: 'Validates generated manifests against the platform schema before deployment.',
  },
  {
    id: 'code_scaffolder',
    name: 'Code Scaffolder',
    description: 'Generates main.py and Dockerfile for each agent following platform conventions.',
  },
  {
    id: 'pipeline_trigger',
    name: 'Deploy (Pipeline Trigger)',
    description:
      'Commits the generated files to CodeCommit and triggers the deploy pipeline to build and ship the agent to AgentCore Runtime.',
  },
  {
    id: 'pipeline_status',
    name: 'Deployment Status',
    description: 'Checks the status of a running deployment pipeline execution.',
  },
  {
    id: 'mcp_catalog_browser',
    name: 'MCP Catalog Browser',
    description: 'Looks up the MCP tools available on the AgentCore Gateway for the agent being built.',
  },
]

export interface AgentToolsPanelProps {
  /** Override the tool list (used for tests). Defaults to {@link ADE_TOOLS}. */
  tools?: AgentTool[]
}

/**
 * Renders the Agent Deployment Engineer's built-in tools (name + description).
 * Static, always-visible — these capabilities are inherent to the agent, so
 * unlike the gateway tool list there is no fetch or empty state.
 */
export function AgentToolsPanel({ tools = ADE_TOOLS }: AgentToolsPanelProps) {
  return (
    <div className="space-y-2">
      <h3 className="text-xs font-medium text-brand-400 uppercase tracking-wider px-1">
        Agent Tools
      </h3>

      <ul className="space-y-1" aria-label="Agent Deployment Engineer tools">
        {tools.map((tool) => (
          <li key={tool.id} className="rounded bg-gray-700 px-2 py-1.5">
            <p className="text-xs font-medium text-gray-200 break-words">{tool.name}</p>
            {tool.description && (
              <p className="text-xs text-gray-400 break-words">{tool.description}</p>
            )}
          </li>
        ))}
      </ul>
    </div>
  )
}
