# ADR-024: Agent Evaluation Separation of Concerns

## Status

Accepted

## Date

2026-05-29

## Context

The Agent School graduation pipeline requires an Evaluate stage that scores deployed agents on safety, correctness, helpfulness, and grounding before the Gate stage decides pass/fail. The key design question is: who provides the test inputs (prompts/scenarios) used during evaluation?

An earlier design had app teams providing their own test data alongside agent code. This violates separation of concerns — app teams could craft test cases that their agent trivially passes, gaming the graduation gate. The evaluation must be independent of the team being evaluated.

## Decision

We adopt a two-layer evaluation model with strict persona separation:

### Layer 1: AgentCore Simulation Mode (Primary)

The platform configures AgentCore Evaluations in **simulation mode** for every agent deployment. In this mode, the service autonomously generates synthetic interactions against the deployed agent runtime — no human-authored prompts required. Built-in evaluators (`Builtin.Safety`, `Builtin.Correctness`, `Builtin.Helpfulness`) score the simulated sessions using LLM-as-a-Judge.

This provides a baseline quality gate that no persona can influence.

### Layer 2: GenAI Testers Persona (Supplementary)

A dedicated **GenAI Testers** persona — organizationally separate from app development teams — curates domain-specific test cases for targeted evaluation. These testers:

- Are independent QA professionals with GenAI domain expertise
- Author test scenarios stored in a governance-controlled S3 bucket (`s3://{governance-bucket}/test-cases/{domain}/`)
- Cannot modify agent code, pipeline infrastructure, or graduation thresholds
- Can author ground-truth datasets for reference-based scoring
- Operate under the governance org, not under app team management

### Persona Responsibilities

| Persona | Owns | Cannot Touch |
|---------|------|--------------|
| App Team | Agent code, `agent.yaml`, business logic | Test cases, thresholds, evaluation config, scoring rubrics |
| Platform Team | Pipeline infra, simulation config, evaluation wiring, built-in evaluator selection | Test case content, agent business logic, thresholds |
| GenAI Testers | Domain test cases, ground-truth datasets, scenario design | Agent code, pipeline infra, graduation thresholds |
| Governance | Graduation policy, red-team prompts, threshold values, custom evaluator definitions | Agent code, test case authoring, pipeline infra |

### Evaluation Flow in Pipeline

```
Deploy → Verify → Evaluate → Gate
                      │
                      ├─ 1. Trigger AgentCore Simulation (platform-configured)
                      ├─ 2. Run GenAI Tester scenarios from governance bucket (if present)
                      ├─ 3. Run red-team suite from governance bucket (qa/prod only)
                      └─ 4. Aggregate scores → evaluation-scores.json
```

### Access Control

- GenAI Testers have write access ONLY to `s3://{governance-bucket}/test-cases/`
- GenAI Testers have NO access to app team repos, pipeline definitions, or graduation policy
- App teams have NO access to the test-cases bucket
- Platform team configures simulation parameters but does not author test content
- Governance reviews and approves GenAI Tester additions via PR to a test-cases repo

## Consequences

### Positive

- App teams cannot game evaluations — they have zero influence on test inputs or scoring
- Simulation mode provides coverage without human effort for every deployment
- GenAI Testers bring domain expertise without code access conflicts
- Clear audit trail: who authored which test case, when, approved by whom
- Scales across domains — each domain gets its own test-case prefix in S3

### Negative

- Requires hiring/assigning GenAI Tester personnel (new role)
- Simulation mode quality depends on AgentCore's synthetic generation capabilities
- Additional S3 bucket management and access policy complexity
- GenAI Testers need domain knowledge without being embedded in app teams (organizational challenge)

### Risks

- If AgentCore simulation mode produces low-quality synthetic interactions, baseline scores may not be meaningful → mitigated by GenAI Tester supplementary cases
- GenAI Testers could become a bottleneck if every agent needs custom scenarios → mitigated by simulation mode handling the baseline

## Alternatives Considered

### 1. App teams provide their own test data

Rejected. Violates separation of concerns. Teams can write tests their agent trivially passes.

### 2. Platform team authors all test cases

Rejected. Platform team lacks domain expertise for each business domain They own infrastructure, not business logic validation.

### 3. Online evaluation only (score live traffic)

Partially adopted (for production monitoring), but insufficient for pre-promotion gating — you need to evaluate BEFORE the agent handles real users, not after.

### 4. Fully automated (simulation only, no human test cases)

Considered but insufficient. Simulation covers generic quality but may miss domain-specific failure modes (e.g., "does the UW agent correctly refuse to bind coverage above authority limits?"). GenAI Testers fill this gap.
