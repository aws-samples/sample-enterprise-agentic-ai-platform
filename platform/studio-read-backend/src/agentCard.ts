/**
 * Agent_Card + Config routes (studio-read backend)
 *
 * Implements two read-only, no-AWS-call routes for the Console Build workspace:
 *
 *   GET /api/agent-card → the ADE (Agent Deployment Engineer) AgentCard:
 *       name, description, version, framework, model, protocols, skills.
 *       Mirrors the standalone Studio BFF `agentCard` object but with the
 *       renamed ADE identity (see design "Backend Routes #7").
 *
 *   GET /api/config → the Cognito settings the Console needs
 *       (cognitoDomain, cognitoRegion, clientId, callbackUrl, scopes),
 *       sourced from environment variables with sensible defaults.
 *
 * Both handlers are exported as RouteHandlers structurally compatible with the
 * router in `index.ts`.
 *
 * Requirements: 5.1, 5.2, 12.7
 */

// ---------------------------------------------------------------------------
// Types — kept structurally compatible with index.ts (ApiGatewayV2Event /
// ApiGatewayResult / RouteHandler are not exported there, so we mirror the
// minimal shapes here).
// ---------------------------------------------------------------------------

interface ApiGatewayV2Event {
  version?: string;
  rawPath?: string;
  rawQueryString?: string;
  body?: string;
  isBase64Encoded?: boolean;
  headers?: Record<string, string>;
  queryStringParameters?: Record<string, string>;
  pathParameters?: Record<string, string>;
  requestContext?: {
    routeKey?: string;
    http?: {
      method?: string;
      path?: string;
    };
  };
}

interface ApiGatewayResult {
  statusCode: number;
  headers: Record<string, string>;
  body: string;
}

type RouteHandler = (event: ApiGatewayV2Event) => Promise<ApiGatewayResult>;

interface AgentSkill {
  id: string;
  name: string;
  description: string;
}

interface AgentCard {
  name: string;
  description: string;
  version: string;
  framework: string;
  model: string;
  protocols: string[];
  capabilities: { streaming: boolean; pushNotifications: boolean };
  skills: AgentSkill[];
}

// ---------------------------------------------------------------------------
// Local JSON response helper (mirrors index.ts jsonResponse to keep this
// module self-contained and avoid importing the router).
// ---------------------------------------------------------------------------

function jsonResponse(statusCode: number, obj: unknown): ApiGatewayResult {
  return {
    statusCode,
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(obj),
  };
}

// ---------------------------------------------------------------------------
// ADE (Agent Deployment Engineer) card — mirrors the standalone Studio BFF
// agentCard, renamed to the ADE identity used by the Console Build workspace.
// ---------------------------------------------------------------------------

export const ADE_AGENT_CARD: AgentCard = {
  name: 'Agent Deployment Engineer',
  description:
    'Conversational agent that helps non-technical users design and deploy agents on the Enterprise Agentic AI Platform (EAP) through natural language.',
  version: '1.0.0',
  framework: 'Strands SDK',
  model: 'Claude Sonnet 5',
  protocols: ['A2A'],
  capabilities: { streaming: false, pushNotifications: false },
  skills: [
    {
      id: 'use-case-discovery',
      name: 'Use Case Discovery',
      description: 'Extracts requirements from natural language descriptions',
    },
    {
      id: 'pattern-recommendation',
      name: 'Pattern Recommendation',
      description: 'Recommends architecture patterns based on use case analysis',
    },
    {
      id: 'manifest-generation',
      name: 'Manifest Generation',
      description: 'Generates YAML manifests and code scaffolding for agents',
    },
    {
      id: 'code-scaffolding',
      name: 'Code Scaffolding',
      description: 'Generates main.py and Dockerfile for each agent',
    },
    {
      id: 'deployment',
      name: 'Deployment',
      description: 'Triggers CI/CD pipeline to deploy generated agents',
    },
  ],
};

// ---------------------------------------------------------------------------
// GET /api/agent-card — return the ADE AgentCard (Req 5.1, 5.2, 12.7)
// ---------------------------------------------------------------------------

export const agentCardHandler: RouteHandler = async () => {
  return jsonResponse(200, ADE_AGENT_CARD);
};

// ---------------------------------------------------------------------------
// GET /api/config — return Cognito settings from env (Req 12.7)
//
// Values come from environment variables with sensible defaults. The studio-read
// Terraform variables already surface cognito_user_pool_id + cognito_app_client_id;
// the app client id is read here as COGNITO_APP_CLIENT_ID and the remaining
// values (domain, region, callback URL, scopes) are additional env reads.
// ---------------------------------------------------------------------------

export const configHandler: RouteHandler = async () => {
  const config = {
    cognitoDomain: process.env.COGNITO_DOMAIN || '',
    cognitoRegion: process.env.COGNITO_REGION || process.env.AWS_REGION || 'us-east-1',
    clientId: process.env.COGNITO_APP_CLIENT_ID || '',
    callbackUrl: process.env.COGNITO_CALLBACK_URL || '',
    scopes: process.env.COGNITO_SCOPES || 'openid gateway/tools.invoke',
  };
  return jsonResponse(200, config);
};
