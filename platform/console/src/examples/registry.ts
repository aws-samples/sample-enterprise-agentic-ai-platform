/**
 * Presentation overlay for the Examples surface (ADR-037).
 *
 * The gallery discovers cards dynamically from the lifecycle table by `pattern`.
 * This overlay supplies the marketing polish that cannot be inferred — display
 * title, tagline, icon, and curated preset prompts — keyed by `app_name`. Apps
 * absent here still render (generated title + pattern default + generic
 * prompts), so a future team-bu-1 app appears automatically.
 *
 * Preset prompts are lifted verbatim from the corresponding demo-ui apps.
 */
import type { ExamplePattern } from '../hooks/useExamples'

export interface ExamplePresentation {
  title: string
  tagline: string
  icon: string
  /** Curated preset prompts shown as clickable chips. */
  presetPrompts: string[]
  /** Optional grouping of prompts by tab (aws-architect uses industry tabs). */
  promptGroups?: Record<string, string[]>
}

// Per-pattern defaults for apps without an explicit overlay entry.
export const PATTERN_DEFAULTS: Record<ExamplePattern, Omit<ExamplePresentation, 'title'>> = {
  standalone: {
    tagline: 'Single-agent assistant',
    icon: '🤖',
    presetPrompts: [
      'Summarize the key benefits of this service',
      'Walk me through a typical use case',
    ],
  },
  swarm: {
    tagline: 'Peer agents collaborating via A2A handoffs',
    icon: '🐝',
    presetPrompts: [
      'Research an emerging technology trend and summarize the trade-offs',
    ],
  },
  supervisor: {
    tagline: 'Orchestrator fans out to worker agents',
    icon: '🎯',
    presetPrompts: ['Search across knowledge sources for a technical topic'],
  },
  'sequential-workflow': {
    tagline: 'Agents chained in a linear pipeline',
    icon: '🔄',
    presetPrompts: ['Process this text through the pipeline'],
  },
}

// Explicit overlay keyed by app_name (the deployed application name).
export const EXAMPLE_OVERLAY: Record<string, ExamplePresentation> = {
  // choreography/swarm/research-swarm
  'research-swarm': {
    title: 'Research Swarm',
    tagline:
      'Three peer agents (researcher, analyst, writer) collaborate via A2A handoffs — no central coordinator.',
    icon: '🐝',
    presetPrompts: [
      'Research the impact of generative AI on software development productivity',
      'Analyze the trade-offs between microservices and monolithic architectures',
      'What are the best practices for implementing zero-trust security in cloud environments',
      'Compare serverless vs container-based architectures for event-driven systems',
      'Research emerging patterns for multi-agent AI systems in enterprise',
    ],
  },

  // standalone/aws-architect-agent
  'aws-architect-agent': {
    title: 'AWS Architect',
    tagline:
      'A Solutions Architect agent that designs AWS architectures, estimates cost, and applies the Well-Architected Framework.',
    icon: '🏗️',
    presetPrompts: [
      'Design a secure payment processing system',
      'Design a telemedicine platform with video',
      'Design a platform that handles Black Friday traffic',
      'Design a multi-tenant SaaS with billing',
    ],
    promptGroups: {
      Financial: [
        'Design a secure payment processing system',
        'Build a fraud detection system for transactions',
      ],
      Healthcare: [
        'Design a telemedicine platform with video',
        'Create a HIPAA-compliant patient data system',
      ],
      'E-commerce': [
        'Design a platform that handles Black Friday traffic',
        'Build a recommendation engine',
      ],
      SaaS: [
        'Design a multi-tenant SaaS with billing',
        'Create a SaaS analytics platform at scale',
      ],
      Data: [
        'Design a real-time IoT data pipeline',
        'Create a data lake for business intelligence',
      ],
      Security: [
        'Design a secure multi-account AWS setup',
        'Build a zero-trust security model',
      ],
    },
  },

  // orchestration/supervisor/rrf-search-app
  'rrf-search-app': {
    title: 'RRF Multi-KB Search',
    tagline:
      'Supervisor pattern — the orchestrator dispatches parallel searches to KB and web retrievers, then fuses results with Reciprocal Rank Fusion.',
    icon: '🔍',
    presetPrompts: [
      'AWS Lambda best practices for production',
      'How to implement VPC peering across accounts',
      'DynamoDB single-table design patterns',
      'ECS vs EKS for microservices',
      'S3 event-driven architecture patterns',
      'CloudWatch custom metrics and alarms',
    ],
  },

  // orchestration/sequential/data-pipeline-app
  'data-pipeline-app': {
    title: 'Data Pipeline',
    tagline:
      'Sequential workflow — three agents chained (extract → enrich → summarize) via Step Functions. Each output feeds the next.',
    icon: '🔄',
    presetPrompts: [
      'The annual science fair at Maplewood Elementary drew over two hundred entries this year. Students presented projects on renewable energy, robotics, and biology. Priya Sharma won first place with her solar-powered water filter, which removes contaminants using a novel membrane design.',
      'Chef Marco opened his first restaurant on a quiet street corner in 1987 with just four tables. His signature dish, a slow-roasted tomato soup, drew crowds from across the city and eventually earned him a coveted culinary award.',
      'The Greenfield Community Garden started as a vacant lot behind the library. Volunteers cleared the debris, built raised beds, and planted their first seeds in spring. Today it produces tomatoes, peppers, squash, and herbs for dozens of local families.',
      'Dr. Elena Park spent fifteen years studying the migration patterns of monarch butterflies across North America. Her research revealed that the insects navigate using a combination of the sun position and the earth magnetic field.',
      'The town of Millbrook held its first ever kite festival on a breezy Saturday in October. Families gathered in the park with kites of every shape and color. Mr. Okafor flew a dragon kite that stretched nearly twenty feet long.',
    ],
  },
}

/** Resolve presentation for an app, falling back to the pattern default. */
export function resolvePresentation(
  appName: string,
  pattern: ExamplePattern
): ExamplePresentation {
  const explicit = EXAMPLE_OVERLAY[appName]
  if (explicit) return explicit
  const def = PATTERN_DEFAULTS[pattern]
  // Generate a human-ish title from the app name for unknown apps.
  const title = appName
    .replace(/[-_]/g, ' ')
    .replace(/\b\w/g, (c) => c.toUpperCase())
  return { title, ...def }
}
