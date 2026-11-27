import { describe, it, expect } from 'vitest';
import { authorizeAgentForBu, DenyReason } from './ownership';
import type { AgentOwnership, CallerClaims } from './types';

function claims(bu: string, personas: string[] = ['Developer']): CallerClaims {
  return {
    sub: 'user-1',
    bu,
    personas,
    exp: 9_999_999_999,
    iss: 'https://cognito-idp.us-east-1.amazonaws.com/us-east-1_test',
  };
}

function ownership(bu: string): AgentOwnership {
  return {
    runtime_arn: 'arn:aws:bedrock-agentcore:us-east-1:123456789012:runtime/agent-Ab12Cd34Ef',
    agent_name: 'agent',
    bu,
    endpoint_qualifier: 'agent_endpoint',
  };
}

describe('authorizeAgentForBu', () => {
  it('allows when the owning BU matches the caller BU', () => {
    const decision = authorizeAgentForBu(claims('team-bu-1'), ownership('team-bu-1'));
    expect(decision.allowed).toBe(true);
    expect(decision.reason).toBeUndefined();
  });

  it('denies (cross-BU) when the owning BU differs from the caller BU', () => {
    const decision = authorizeAgentForBu(claims('team-bu-1'), ownership('team-bu-2'));
    expect(decision.allowed).toBe(false);
    expect(decision.reason).toBe(DenyReason.CROSS_BU);
  });

  it('denies when the caller BU is empty', () => {
    const decision = authorizeAgentForBu(claims(''), ownership('team-bu-1'));
    expect(decision.allowed).toBe(false);
    expect(decision.reason).toBe(DenyReason.UNRESOLVED_CALLER_BU);
  });

  it('denies when the caller BU is only whitespace', () => {
    const decision = authorizeAgentForBu(claims('   '), ownership('team-bu-1'));
    expect(decision.allowed).toBe(false);
    expect(decision.reason).toBe(DenyReason.UNRESOLVED_CALLER_BU);
  });

  it('denies (ownership not found) when ownership is null', () => {
    const decision = authorizeAgentForBu(claims('team-bu-1'), null);
    expect(decision.allowed).toBe(false);
    expect(decision.reason).toBe(DenyReason.OWNERSHIP_NOT_FOUND);
  });

  it('denies (ownership not found) when ownership is undefined', () => {
    const decision = authorizeAgentForBu(claims('team-bu-1'), undefined);
    expect(decision.allowed).toBe(false);
    expect(decision.reason).toBe(DenyReason.OWNERSHIP_NOT_FOUND);
  });

  it('denies when the owning BU is empty', () => {
    const decision = authorizeAgentForBu(claims('team-bu-1'), ownership(''));
    expect(decision.allowed).toBe(false);
    expect(decision.reason).toBe(DenyReason.OWNERSHIP_BU_UNRESOLVED);
  });

  it('denies when claims are null (fail closed)', () => {
    const decision = authorizeAgentForBu(null, ownership('team-bu-1'));
    expect(decision.allowed).toBe(false);
    expect(decision.reason).toBe(DenyReason.UNRESOLVED_CALLER_BU);
  });

  it('ignores surrounding whitespace when comparing BUs', () => {
    const decision = authorizeAgentForBu(claims(' team-bu-1 '), ownership('team-bu-1'));
    expect(decision.allowed).toBe(true);
  });

  it('is case-sensitive on the BU comparison (distinct BUs deny)', () => {
    const decision = authorizeAgentForBu(claims('Team-BU-1'), ownership('team-bu-1'));
    expect(decision.allowed).toBe(false);
    expect(decision.reason).toBe(DenyReason.CROSS_BU);
  });

  it('allows regardless of persona (persona never widens tenant scope)', () => {
    for (const persona of ['Platform_Operator', 'AI_Governance_Risk', 'Developer']) {
      const decision = authorizeAgentForBu(claims('team-bu-1', [persona]), ownership('team-bu-1'));
      expect(decision.allowed).toBe(true);
    }
  });

  it('denies cross-BU regardless of persona', () => {
    for (const persona of ['Platform_Operator', 'AI_Governance_Risk', 'Developer']) {
      const decision = authorizeAgentForBu(claims('team-bu-1', [persona]), ownership('team-bu-2'));
      expect(decision.allowed).toBe(false);
    }
  });
});
