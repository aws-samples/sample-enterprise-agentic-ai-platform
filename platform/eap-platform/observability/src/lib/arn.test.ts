import { describe, it, expect } from 'vitest';
import { isValidRuntimeArn } from './arn';

describe('isValidRuntimeArn', () => {
  it('accepts a well-formed AgentCore runtime ARN', () => {
    expect(
      isValidRuntimeArn('arn:aws:bedrock-agentcore:us-east-1:123456789012:runtime/my-agent-Ab12Cd34Ef'),
    ).toBe(true);
  });

  it('accepts alternate partitions', () => {
    expect(
      isValidRuntimeArn('arn:aws-us-gov:bedrock-agentcore:us-gov-west-1:123456789012:runtime/agent_1'),
    ).toBe(true);
  });

  it('rejects malformed ARNs', () => {
    expect(isValidRuntimeArn('')).toBe(false);
    expect(isValidRuntimeArn('not-an-arn')).toBe(false);
    expect(isValidRuntimeArn('arn:aws:s3:::bucket/key')).toBe(false);
    // wrong account length
    expect(isValidRuntimeArn('arn:aws:bedrock-agentcore:us-east-1:12345:runtime/agent')).toBe(false);
    // missing runtime segment
    expect(isValidRuntimeArn('arn:aws:bedrock-agentcore:us-east-1:123456789012:agent/x')).toBe(false);
  });

  it('rejects non-string inputs', () => {
    // @ts-expect-error exercising defensive runtime behavior
    expect(isValidRuntimeArn(null)).toBe(false);
    // @ts-expect-error exercising defensive runtime behavior
    expect(isValidRuntimeArn(42)).toBe(false);
  });
});
