// CloudWatch logs helper — reads recent AgentCore runtime logs for an app so
// the console can render OTel log panels and (for the swarm) infer handoffs.
// Example-agnostic: the caller passes the runtime log-group prefix.
//
// Ported from the demo-ui backends' /api/agent-logs implementations (ADR-037).

import {
  CloudWatchLogsClient,
  DescribeLogGroupsCommand,
  DescribeLogStreamsCommand,
  GetLogEventsCommand,
} from '@aws-sdk/client-cloudwatch-logs'

const REGION = process.env.AWS_REGION || 'us-east-1'
const cwl = new CloudWatchLogsClient({ region: REGION })

export interface LogEntry {
  agent: string
  timestamp: number
  message: string
  level: string
  traceId?: string
  spanId?: string
}

/**
 * Discover the app's endpoint log groups under
 * `/aws/bedrock-agentcore/runtimes/<runtimePrefix>` and return recent events.
 * The agent short-name is derived from the log group name (segment after the
 * prefix, before `_endpoint`).
 */
export async function readAgentLogs(runtimePrefix: string, since: number): Promise<LogEntry[]> {
  const base = `/aws/bedrock-agentcore/runtimes/${runtimePrefix}`
  const groups = await cwl.send(new DescribeLogGroupsCommand({ logGroupNamePrefix: base }))

  const logGroups: Record<string, string> = {}
  for (const lg of groups.logGroups || []) {
    const name = lg.logGroupName || ''
    if (!name.includes('_endpoint')) continue
    // agent short-name = between the prefix and `_endpoint`
    const tail = name.split('/').pop() || name
    const agent = tail.replace(new RegExp(`^${runtimePrefix}`), '').replace(/_endpoint.*$/, '')
    if (agent) logGroups[agent] = name
  }

  const allLogs: LogEntry[] = []
  for (const [agent, logGroup] of Object.entries(logGroups)) {
    try {
      const streams = await cwl.send(
        new DescribeLogStreamsCommand({
          logGroupName: logGroup,
          orderBy: 'LastEventTime',
          descending: true,
          limit: 2,
        })
      )
      for (const stream of (streams.logStreams || []).slice(0, 2)) {
        if (!stream.logStreamName) continue
        const events = await cwl.send(
          new GetLogEventsCommand({
            logGroupName: logGroup,
            logStreamName: stream.logStreamName,
            startTime: since,
            limit: 50,
          })
        )
        for (const event of events.events || []) {
          const msg = event.message || ''
          let level = 'INFO'
          let traceId: string | undefined
          let spanId: string | undefined
          let message = msg.trim()
          try {
            const parsed = JSON.parse(msg)
            level = parsed.levelname || parsed.level || 'INFO'
            traceId = parsed.trace_id
            spanId = parsed.span_id
            message = parsed.message || msg
          } catch {
            if (msg.includes('ERROR')) level = 'ERROR'
            else if (msg.includes('WARNING')) level = 'WARNING'
          }
          allLogs.push({
            agent: agent.replace(/_/g, '-'),
            timestamp: event.timestamp || 0,
            message,
            level,
            traceId,
            spanId,
          })
        }
      }
    } catch {
      /* skip a log group that can't be read */
    }
  }

  allLogs.sort((a, b) => a.timestamp - b.timestamp)
  return allLogs
}
