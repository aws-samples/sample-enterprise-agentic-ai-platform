// Shared TypeScript data models for the Console Build (Studio-parity) workspace.
//
// These shapes are shared between the frontend and the `studio-read` Lambda:
// the Lambda emits these shapes and the frontend consumes them. Field names on
// wire responses use snake_case to match the standalone BFF contract the UI
// already understands (DeployedRuntime / DeployedAgent / DeploymentStatus);
// frontend-owned view models (ActiveDeployment, Conversation, Message,
// ManifestBlock) use camelCase where the design shows it.
//

/**
 * One peer runtime within a deployed application (wire shape, snake_case).
 * _Requirements: 8.5_
 */
export interface DeployedRuntime {
  agent_name: string
  runtime_name: string
  runtime_arn: string
  endpoint_qualifier: string
  status: string
  /** manifest role (orchestrator/supervisor/worker/standalone/…); '' when unknown */
  agent_role?: string
  /** manifest agent key (application.yaml `name`) this runtime was deployed from */
  agent_key?: string
}

/**
 * One node in an application's deployed topology graph, sourced from the app's
 * application.yaml. Edge fields are directional lists of other node names.
 */
export interface TopologyAgent {
  name: string
  role: string
  calls: string[]
  called_by: string[]
  can_call: string[]
  depends_on: string[]
}

/**
 * Authoritative deployed-architecture graph for an application, rendered
 * per-pattern in the architecture pane. Sourced from application.yaml.
 */
export interface AppTopology {
  pattern: string
  agents: TopologyAgent[]
}

/**
 * One deployed application — the `GET /api/my-deployed-agents` record
 * (wire shape, snake_case).
 * _Requirements: 8.5_
 */
export interface DeployedAgent {
  /** standalone | supervisor | multi-agent | sequential | swarm | router | ... */
  app_name: string
  /** owning business unit / domain (single shared table discriminator); '' if unknown */
  bu?: string
  pattern: string
  /** e.g. "orchestration/supervisor" | "standalone" */
  pattern_folder: string
  primary_runtime_arn: string
  primary_endpoint_qualifier: string
  /** all peers; empty when no runtime matched (Req 8.6) */
  runtimes: DeployedRuntime[]
  /** deployed-architecture graph from application.yaml (null/absent when unavailable) */
  topology?: AppTopology | null
}

/**
 * Terminal + transitional deployment states shared by the tracker and the
 * Deployment_Status_Service.
 */
export type DeploymentState =
  | 'in_progress'
  | 'succeeded'
  | 'failed'
  | 'cancelled'
  | 'stopped'
  | 'superseded'
  | 'unknown'

/**
 * Frontend-tracked deployment (Deployment_Tracker state entry, camelCase).
 * _Requirements: 7.1_
 */
export interface ActiveDeployment {
  executionId: string
  appName: string
  patternFolder?: string
  status: DeploymentState
  stage: string
  /** epoch ms; used for the 30-min timeout (Req 7.7) */
  startedAt: number
  /** for the 3-failure error surfacing (Req 7.6) */
  consecutiveFailures: number
  timedOut?: boolean
  error?: string
}

/**
 * Deployment_Status_Service response (`GET /api/deployment-status/:id`).
 */
export interface DeploymentStatus {
  executionId: string
  status: ActiveDeployment['status']
  stage: string
  error: string | null
  pattern: string
  runtimes: Array<{ name: string; runtime_arn: string; endpoint_qualifier: string }>
}

/**
 * ADE metadata (Agent_Card).
 * _Requirements: (Req 5.1, 5.2, 12.7)_
 */
export interface AgentCard {
  name: string
  description: string
  version: string
  framework: string
  model: string
  protocols: string[]
  skills: Array<{ id: string; name: string; description: string }>
}

/**
 * Chat message (UI view model, camelCase).
 */
export interface Message {
  role: 'user' | 'agent'
  text: string
  timestamp?: number
}

/**
 * Named ADE design session (Req 1) — UI view model, camelCase.
 * _Requirements: 1.1, 6.1_
 */
export interface Conversation {
  /** uuid */
  id: string
  /** first 50 chars of first user message, trimmed (Req 1.3) */
  title: string
  createdAt: number
  /** for "most recently modified" selection on delete (Req 1.5) */
  updatedAt: number
  /** 0..4 monotonic within session (Req 6.3) */
  phase: number
  messages: Message[]
}

/**
 * Extracted manifest panel (Req 10).
 */
export interface ManifestBlock {
  label: string
  content: string
  language: 'yaml' | 'json'
}

/**
 * Agent-design lifecycle phases, in order (Req 6.1).
 */
export const PHASES = [
  'Discovery',
  'Pattern Selection',
  'Customization',
  'YAML & Code Generation',
  'Deployment',
] as const

/** A single phase label from {@link PHASES}. */
export type Phase = (typeof PHASES)[number]
