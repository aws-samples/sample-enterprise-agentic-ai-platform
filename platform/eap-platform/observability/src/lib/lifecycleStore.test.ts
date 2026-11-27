import { describe, it, expect, vi, beforeEach } from 'vitest';

// Stub the DynamoDB document client transport so we exercise the real
// resolveAgentOwnership scan/mapping logic without a live table. `send` is a
// hoisted mock we reconfigure per test.
const send = vi.fn();

vi.mock('@aws-sdk/client-dynamodb', () => ({
  DynamoDBClient: class {},
}));

vi.mock('@aws-sdk/lib-dynamodb', () => ({
  DynamoDBDocumentClient: { from: () => ({ send }) },
  // ScanCommand just captures its input so assertions can inspect it.
  ScanCommand: class {
    input: unknown;
    constructor(input: unknown) {
      this.input = input;
    }
  },
}));

// Import after mocks are registered.
import { resolveAgentOwnership } from './lifecycleStore';

const ARN = 'arn:aws:bedrock-agentcore:us-east-1:123456789012:runtime/agent-Ab12Cd34Ef';

describe('resolveAgentOwnership', () => {
  beforeEach(() => {
    send.mockReset();
  });

  it('returns null for an empty ARN without touching DynamoDB', async () => {
    const result = await resolveAgentOwnership('');
    expect(result).toBeNull();
    expect(send).not.toHaveBeenCalled();
  });

  it('maps a matching lifecycle row to AgentOwnership', async () => {
    send.mockResolvedValueOnce({
      Items: [
        {
          agent_name: 'agent',
          runtime_arn: ARN,
          endpoint_qualifier: 'agent_endpoint',
          bu: 'team-bu-1',
        },
      ],
    });

    const result = await resolveAgentOwnership(ARN);
    expect(result).toEqual({
      runtime_arn: ARN,
      agent_name: 'agent',
      bu: 'team-bu-1',
      endpoint_qualifier: 'agent_endpoint',
    });
  });

  it('returns null when no row matches the ARN', async () => {
    send.mockResolvedValueOnce({ Items: [] });
    const result = await resolveAgentOwnership(ARN);
    expect(result).toBeNull();
  });

  it('follows pagination until a match is found', async () => {
    send
      .mockResolvedValueOnce({ Items: [], LastEvaluatedKey: { agent_name: 'x' } })
      .mockResolvedValueOnce({
        Items: [{ agent_name: 'agent', runtime_arn: ARN, bu: 'team-bu-2' }],
      });

    const result = await resolveAgentOwnership(ARN);
    expect(result?.bu).toBe('team-bu-2');
    expect(send).toHaveBeenCalledTimes(2);
  });

  it('propagates DynamoDB failures (caller fails closed with 503)', async () => {
    send.mockRejectedValueOnce(new Error('ProvisionedThroughputExceeded'));
    await expect(resolveAgentOwnership(ARN)).rejects.toThrow();
  });

  it('defaults missing item fields to empty strings', async () => {
    send.mockResolvedValueOnce({ Items: [{ runtime_arn: ARN }] });
    const result = await resolveAgentOwnership(ARN);
    expect(result).toEqual({
      runtime_arn: ARN,
      agent_name: '',
      bu: '',
      endpoint_qualifier: '',
    });
  });
});
