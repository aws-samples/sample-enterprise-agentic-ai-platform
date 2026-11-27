/**
 * sanitize.ts — strip AWS internals from error messages before returning them
 * to console callers (pure, AWS-free).
 *
 * Ported verbatim (behavior-preserving) from `invoke-proxy/src/index.ts`
 * (`sanitizeErrorMessage`). Used on every error path of the Deep_Link_Service
 * and Telemetry_API_Service (design Error Handling: STS/federation/CloudWatch/
 * X-Ray failures return sanitized 502/503 messages).
 */

/**
 * Sanitize an error message to strip AWS internals before sending to clients.
 * Removes ARNs, account IDs, stack traces, request IDs, and file paths. Pure
 * and deterministic.
 */
export function sanitizeErrorMessage(raw: string): string {
  let sanitized = typeof raw === 'string' ? raw : String(raw);
  // Strip AWS ARNs.
  sanitized = sanitized.replace(
    /arn:aws[a-zA-Z-]*:[a-zA-Z0-9-]+:[a-zA-Z0-9-]*:\d{12}:[^\s,)}\]"']*/g,
    '[REDACTED_ARN]',
  );
  // Strip AWS account IDs (12-digit).
  sanitized = sanitized.replace(/\b\d{12}\b/g, '[REDACTED_ACCOUNT]');
  // Strip stack traces (lines starting with "at ").
  sanitized = sanitized.replace(/\n?\s*at\s+.+/g, '');
  // Strip request IDs (UUID-like patterns in error context).
  sanitized = sanitized.replace(
    /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/gi,
    '[REDACTED_REQUEST_ID]',
  );
  // Strip file paths.
  sanitized = sanitized.replace(/\/[^\s:]+\.(js|ts|mjs):\d+:\d+/g, '[REDACTED_PATH]');
  return sanitized.trim();
}
