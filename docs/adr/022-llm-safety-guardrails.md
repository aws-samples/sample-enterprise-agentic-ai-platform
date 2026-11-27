# ADR-022: LLM Safety and Guardrails — OWASP Top 10 for LLMs

**Status**: Approved
**Date**: 2026-04-30
**Decision Makers**: Platform Engineering, AI Governance & Risk

## Context

AI agents operating in regulated industries are susceptible to prompt injection attacks, data exfiltration, and other LLM-specific vulnerabilities cataloged in the OWASP Top 10 for Large Language Models. The platform must provide defense-in-depth so that individual agents inherit safety by default, without requiring each app team to implement their own protections.

## Decision

Implement a four-layer defense model using AWS-native services. Each layer operates independently — if one layer is bypassed, the next catches the threat.

### Layer 1: Amazon Bedrock Guardrails (Input/Output Filtering)

Sits between the user and the LLM. Filters both prompts and responses before they reach the model.

- Prompt attack detection — jailbreaks, prompt injection, prompt leakage
- Content filters — blocks harmful content (misconduct, violence, sexual, insult, hate)
- Denied topics — custom restrictions per BU (e.g., "never discuss competitor products")
- PII filters — detects and masks sensitive data in inputs and outputs
- Contextual grounding checks — validates responses are grounded in provided context

Implementation: the platform creates a default Bedrock Guardrail per BU. AI Governance customizes thresholds. Guardrails are associated with agents via the deploy template.

Reference: [Bedrock Guardrails - Prompt Attack Detection](https://docs.aws.amazon.com/bedrock/latest/userguide/guardrails-prompt-attack.html)

### Layer 2: AgentCore Policy (Cedar — Tool Authorization)

Sits between the agent and its tools. Deterministic enforcement, not probabilistic.

- Cedar policies define which tools an agent can call, under what conditions, for which users
- Default deny — agents cannot call tools unless explicitly permitted by policy
- Natural language authoring — AI Governance writes policies in plain English, auto-converted to Cedar
- Audit logging — every policy decision is logged for compliance

Even if prompt injection tricks the LLM into requesting a tool call, the Cedar policy layer blocks unauthorized actions deterministically.

Reference: [AgentCore Policy](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/policy.html), [Securing Bedrock Agents against Indirect Prompt Injection](https://aws.amazon.com/blogs/machine-learning/securing-amazon-bedrock-agents-a-guide-to-safeguarding-against-indirect-prompt-injections/)

### Layer 3: AgentCore Evaluations (Continuous Monitoring)

Runs after responses are generated. Catches quality and safety drift over time.

- Built-in evaluators — correctness, helpfulness, safety scored on every response
- Custom evaluators — business-specific checks (e.g., "response must not include policy numbers")
- CloudWatch alerts — trigger when safety scores drop below thresholds
- Real-time dashboards — AI Governance monitors all agents from one pane

Reference: [AgentCore Evaluations](https://aws.amazon.com/blogs/aws/amazon-bedrock-agentcore-adds-quality-evaluations-and-policy-controls-for-deploying-trusted-ai-agents/)

### Layer 4: Platform Base Image Defenses (Zero App Code)

Injected by the platform transparently. No app team code changes needed.

- Input sanitization — strip known injection patterns before they reach the LLM
- System prompt isolation — Bedrock Guardrails input tags separate user input from system prompt
- Session isolation — AgentCore Runtime provides complete separation between user sessions
- Least-privilege IAM — agents can only invoke Bedrock models and tools they are authorized for
- Multi-layered input validation — application-level sanitization + Guardrails + Cedar policies

Reference: [AWS Prescriptive Guidance - Input Validation for Agentic AI](https://docs.aws.amazon.com/prescriptive-guidance/latest/agentic-ai-security/best-practices-input-validation.html)

## OWASP Top 10 for LLMs — Platform Mapping

| OWASP Risk | Platform Mitigation |
|------------|-------------------|
| LLM01: Prompt Injection | Bedrock Guardrails prompt attack filter + Cedar policy (tool auth) |
| LLM02: Insecure Output | Bedrock Guardrails output filters + content filters |
| LLM03: Training Data Poisoning | AWS-managed models via Bedrock (no custom training) |
| LLM04: Model DoS | AgentCore Runtime auto-scaling + session isolation |
| LLM05: Supply Chain | Platform base image (controlled), ECR image scanning |
| LLM06: Sensitive Info Disclosure | PII filters + Cedar data entitlements (3LO) |
| LLM07: Insecure Plugin Design | Cedar policies on Gateway tools (default deny) |
| LLM08: Excessive Agency | Cedar policies limit tool access + user confirmation |
| LLM09: Overreliance | Evaluations (correctness scoring) + grounding checks |
| LLM10: Model Theft | Bedrock managed models (no model access), VPC endpoints |

## Implementation Phases

### Phase 1 (POC — Current)
- AgentCore Evaluations via agent.yaml (correctness, helpfulness, safety)
- Least-privilege IAM on runtime roles
- Session isolation via AgentCore Runtime

### Phase 2 (Post-POC)
- Bedrock Guardrails per BU (prompt attack filter, content filters, PII)
- Cedar policies on AgentCore Gateway (tool authorization)
- Input sanitization in base image entrypoint

### Phase 3 (Production)
- Custom evaluators for business-specific safety checks
- Automated red-teaming test suites
- Real-time safety dashboards for AI Governance
- Cedar policy versioning and audit trail

## Consequences

- Every agent inherits safety by default — no app team code changes needed
- AI Governance has centralized visibility and policy enforcement
- Defense-in-depth: prompt injection must bypass Guardrails AND Cedar AND Evaluations
- Cedar policies are deterministic — not dependent on LLM behavior
- Compliance audit trail via CloudTrail + Cedar audit logs + Evaluation scores

## References

- [Bedrock Prompt Injection Security](https://docs.aws.amazon.com/bedrock/latest/userguide/prompt-injection.html)
- [Securing Bedrock Agents against Indirect Prompt Injection](https://aws.amazon.com/blogs/machine-learning/securing-amazon-bedrock-agents-a-guide-to-safeguarding-against-indirect-prompt-injections/)
- [AgentCore Policy (Cedar)](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/policy.html)
- [AWS Prescriptive Guidance - Agentic AI Security](https://docs.aws.amazon.com/prescriptive-guidance/latest/agentic-ai-security/best-practices-input-validation.html)
- [OWASP Top 10 for LLMs](https://owasp.org/www-project-top-10-for-large-language-model-applications/)
