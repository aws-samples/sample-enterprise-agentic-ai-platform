/**
 * arn.ts — AgentCore runtime ARN validation (pure, AWS-free).
 *
 * Ported from `studio-read/src/runtimeAllowList.ts` (`isValidRuntimeArn`) so
 * the observability backend rejects malformed `agentArn` values with a 400
 * before any ownership check or AWS call (mirrors the invoke-proxy pattern;
 * design Error Handling — malformed `agentArn`).
 */

/**
 * Bedrock AgentCore runtime ARN syntax:
 *   arn:aws<partition?>:bedrock-agentcore:<region>:<account>:runtime/<runtimeId>
 */
const RUNTIME_ARN_RE =
  /^arn:aws[a-z-]*:bedrock-agentcore:[a-z0-9-]+:\d{12}:runtime\/[A-Za-z0-9_.-]+$/;

/**
 * Whether a string is a syntactically valid AgentCore runtime ARN. Pure and
 * deterministic; malformed ARNs are rejected before any membership/ownership
 * check or invocation.
 */
export function isValidRuntimeArn(arn: string): boolean {
  return typeof arn === 'string' && RUNTIME_ARN_RE.test(arn);
}
