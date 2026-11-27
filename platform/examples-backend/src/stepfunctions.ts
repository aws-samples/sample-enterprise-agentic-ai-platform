// Step Functions helper — start / describe / history for SFN-backed examples
// (supervisor + sequential-workflow patterns). Example-agnostic: the caller
// passes the state machine ARN (resolved from the lifecycle table's
// state_machine_arn added in ADR-037).
//
// The history endpoint reconstructs the A2A JSON-RPC request/response pairs the
// SFN→AgentCore bridge Lambda exchanges, so the console's A2A inspector and
// step-timeline can render them — ported from the demo-ui SFN backends.

import {
  SFNClient,
  StartExecutionCommand,
  DescribeExecutionCommand,
  GetExecutionHistoryCommand,
} from '@aws-sdk/client-sfn'

const REGION = process.env.AWS_REGION || 'us-east-1'
const sfn = new SFNClient({ region: REGION })

export interface StartResult {
  executionArn: string
  executionName: string
}

/** Start a Step Functions execution with input {"query": text}. */
export async function startExecution(stateMachineArn: string, query: string): Promise<StartResult> {
  const executionName = `console-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`
  const result = await sfn.send(
    new StartExecutionCommand({
      stateMachineArn,
      name: executionName,
      input: JSON.stringify({ query }),
    })
  )
  return { executionArn: result.executionArn!, executionName }
}

export interface StatusResult {
  status?: string
  startDate?: Date
  stopDate?: Date
  output: unknown
}

/** Describe an execution; JSON-parse its output when possible. */
export async function describeExecution(executionArn: string): Promise<StatusResult> {
  const result = await sfn.send(new DescribeExecutionCommand({ executionArn }))
  let output: unknown = null
  if (result.output) {
    try {
      output = JSON.parse(result.output)
    } catch {
      output = result.output
    }
  }
  return {
    status: result.status,
    startDate: result.startDate,
    stopDate: result.stopDate,
    output,
  }
}

export interface HistoryEvent {
  id?: number
  type?: string
  timestamp?: Date
  details: unknown
}

export interface A2APayloadEntry {
  agent: string
  direction: 'request' | 'response'
  timestamp: string
  payload: unknown
  eventId: number
}

export interface HistoryResult {
  events: HistoryEvent[]
  a2aPayloads: A2APayloadEntry[]
}

/**
 * Derive an agent short-name from a Lambda-invoke AgentRuntimeEndpointArn,
 * stripping the `_endpoint` suffix and the domain/app runtime-name prefix.
 * `runtimePrefix` is e.g. "team_bu_1_rrf_search_app_" (optional).
 */
function agentNameFromEndpointArn(endpointArn: string, runtimePrefix?: string): string {
  let name = endpointArn.split('/').pop()?.replace(/_endpoint$/, '') || 'unknown'
  if (runtimePrefix && name.startsWith(runtimePrefix)) {
    name = name.slice(runtimePrefix.length)
  }
  return name
}

/**
 * Get execution history and reconstruct A2A request/response pairs from the
 * TaskScheduled / TaskSucceeded events emitted by the SFN→AgentCore bridge.
 */
export async function getExecutionHistory(
  executionArn: string,
  runtimePrefix?: string
): Promise<HistoryResult> {
  const result = await sfn.send(
    new GetExecutionHistoryCommand({ executionArn, includeExecutionData: true })
  )

  const events: HistoryEvent[] = (result.events || []).map((e) => ({
    id: e.id,
    type: e.type,
    timestamp: e.timestamp,
    details:
      e.stateEnteredEventDetails ||
      e.stateExitedEventDetails ||
      e.taskScheduledEventDetails ||
      e.taskSucceededEventDetails ||
      e.executionStartedEventDetails ||
      e.executionSucceededEventDetails ||
      null,
  }))

  const a2aPayloads: A2APayloadEntry[] = []

  for (const e of result.events || []) {
    // TaskScheduled → the Lambda invocation input carries the A2A request.
    if (e.type === 'TaskScheduled' && e.taskScheduledEventDetails) {
      try {
        const params = JSON.parse(e.taskScheduledEventDetails.parameters || '{}')
        const lambdaPayload = params.Payload || {}
        const endpointArn = lambdaPayload.AgentRuntimeEndpointArn || ''
        const agentName = agentNameFromEndpointArn(endpointArn, runtimePrefix)
        const agentPayload = lambdaPayload.Payload || {}
        a2aPayloads.push({
          agent: agentName,
          direction: 'request',
          timestamp: e.timestamp?.toISOString() || '',
          payload: {
            jsonrpc: '2.0',
            method: 'message/send',
            id: 'sfn-bridge',
            params: {
              message: {
                role: 'user',
                parts: [{ kind: 'text', text: JSON.stringify(agentPayload) }],
              },
            },
          },
          eventId: e.id || 0,
        })
      } catch {
        /* skip unparseable */
      }
    }

    // TaskSucceeded → the agent response.
    if (e.type === 'TaskSucceeded' && e.taskSucceededEventDetails) {
      try {
        const output = JSON.parse(e.taskSucceededEventDetails.output || '{}')
        a2aPayloads.push({
          agent: 'unknown',
          direction: 'response',
          timestamp: e.timestamp?.toISOString() || '',
          payload: {
            jsonrpc: '2.0',
            id: 'sfn-bridge',
            result: { artifacts: [{ parts: [{ kind: 'text', text: JSON.stringify(output) }] }] },
          },
          eventId: e.id || 0,
        })
      } catch {
        /* skip */
      }
    }
  }

  return { events, a2aPayloads }
}
