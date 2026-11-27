# ADR-020: Multi-Agent Orchestration — Step Functions + A2A Mesh

**Status**: Confirmed
**Date**: 2026-04-13

---

## Context

The Enterprise Agentic AI Platform supports five agent architecture patterns (Standalone, Sequential Workflow, Router, Parallel, Supervisor) plus Swarm. Multi-agent patterns require orchestration — deciding which agent runs when, how data flows between them, and how results are aggregated.

The platform must be **framework-agnostic**. Customers run Strands SDK, Claude SDK, LangGraph, LangChain, CrewAI, or custom frameworks. The orchestration layer cannot depend on any specific agent framework.

## Problem

How should the platform orchestrate multi-agent applications across isolated AgentCore Runtimes without coupling to a specific agent framework?

## Alternatives Explored

### Option 1: Framework-Native Orchestration (Rejected)

Each framework has its own multi-agent orchestration:
- Strands SDK: Agents-as-Tools, Swarms, Graphs, Workflows
- LangGraph: Graph-based state machines
- CrewAI: Crews with role-based delegation

**Pros:**
- Rich, framework-specific features (handoffs, shared scratchpads, graph state)
- All agents run in one process — low latency
- Mature patterns with good documentation

**Cons:**
- Framework lock-in — platform mandates one framework for multi-agent
- Breaks the platform's interoperability principle (A2A, MCP, HTTP — any framework)
- A Strands orchestrator can't coordinate a LangGraph specialist
- Studio would need framework-specific code generation per pattern
- Violates the "no higher-level abstractions" design principle

**Decision**: Rejected. Framework-native orchestration is available to developers who choose it, but the platform doesn't own or mandate it.

### Option 2: Custom Orchestrator Agent (Rejected)

Build a platform-owned orchestrator agent that coordinates other agents via A2A. The orchestrator reads `application.yaml`, provisions itself as a runtime, and uses its LLM to decide which agents to call.

**Pros:**
- Framework-agnostic (orchestrator calls agents via A2A)
- LLM-driven — can handle dynamic delegation

**Cons:**
- Adds an extra LLM call for every orchestration decision (cost + latency)
- The orchestrator itself needs a framework (which one?)
- Complex to build and maintain — essentially building a meta-agent
- Debugging is hard — orchestration decisions are opaque (LLM reasoning)
- Overkill for simple patterns (sequential, parallel) that don't need LLM reasoning

**Decision**: Rejected. Using an LLM to decide "call Agent B then Agent C in parallel" is wasteful when the topology is known at deploy time.

### Option 3: AWS Step Functions (Selected for Structured Patterns)

Use AWS Step Functions as the framework-agnostic orchestration layer for patterns with predefined topology.

**Pros:**
- Framework-agnostic — calls AgentCore Runtime invocation endpoints via SigV4. Doesn't know or care what framework is inside the container.
- Declarative — topology defined in Amazon States Language (ASL/JSON), generated from `application.yaml`
- Native support for: Parallel (fan-out/fan-in), Sequential (chain), Choice (router), Map (dynamic fan-out), Retry/Catch (error handling)
- Visual execution history — see exactly where a run failed, what each agent returned
- Durable state — survives agent crashes, supports long-running workflows
- Studio-friendly — ASL can be generated from a visual topology builder
- Cost-effective — pay per state transition, not per compute second
- Built-in timeout handling per state (specialist timeout: 8s)

**Cons:**
- Latency overhead: ~50-100ms per state transition (acceptable for most patterns)
- Cannot handle emergent/dynamic flows (swarm pattern — see Option 4)
- Adds an AWS service dependency (Step Functions)
- ASL is verbose — but generated, not hand-written

**Decision**: Selected for Sequential Workflow, Parallel, Supervisor, and Router patterns.

### Option 4: A2A Mesh via application.yaml (Selected for Swarm Pattern)

For patterns where agents control the flow (swarm, dynamic supervisor), the platform wires an A2A mesh — each agent knows its peers and calls them directly via A2A protocol.

**Pros:**
- Framework-agnostic — A2A protocol works across any framework
- Supports emergent behavior — agents decide who to call next (LLM-driven)
- No external orchestrator — agents are peers
- Low latency — direct runtime-to-runtime calls
- Simple platform implementation — just inject peer runtime names as env vars

**Cons:**
- No centralized execution history (rely on OTel traces for observability)
- No built-in retry/timeout at the orchestration level (agents handle it)
- Harder to debug — flow is emergent, not predefined
- Not suitable for patterns that need deterministic ordering

**Decision**: Selected for Swarm pattern and any pattern where the flow is LLM-driven rather than topology-driven.

## Decision

Use **two complementary orchestration modes**, selected based on the pattern:

| Pattern | Orchestration Mode | Who Decides Next Step | Generated From |
|---------|-------------------|----------------------|----------------|
| Standalone | None (single agent) | N/A | `agent.yaml` |
| Sequential Workflow | Step Functions | State machine (predefined) | `application.yaml` → ASL |
| Parallel | Step Functions | State machine (predefined) | `application.yaml` → ASL |
| Supervisor | Step Functions | State machine (predefined) | `application.yaml` → ASL |
| Router | Step Functions | State machine (Choice state) | `application.yaml` → ASL |
| Swarm | A2A Mesh | Agent LLM (emergent) | `application.yaml` → env vars |

### How Step Functions Orchestration Works

1. Developer writes `application.yaml` defining agents and topology
2. Deploy-template reads `application.yaml` and generates:
   - One AgentCore Runtime per agent
   - One Step Functions state machine defining the orchestration flow
   - IAM role for Step Functions to invoke runtimes (SigV4)
3. User request → Step Functions execution starts
4. Step Functions invokes agent runtimes via AgentCore Runtime API (SigV4)
5. Each agent processes its task (in whatever framework) and returns results
6. Step Functions routes results to next state (parallel fan-in, sequential chain, etc.)
7. Final state returns aggregated result to caller

### How A2A Mesh Orchestration Works

1. Developer writes `application.yaml` with `can_call` declarations
2. Deploy-template reads `application.yaml` and generates:
   - One AgentCore Runtime per agent
   - Peer runtime names injected as env vars into each agent
3. User request → first agent receives it
4. Agent's LLM decides to hand off to a peer → calls peer via A2A protocol
5. Peer processes and may hand off to another peer
6. Flow continues until an agent decides to return the final result
7. OTel traces capture the full peer-to-peer flow

### Example: KB Search as Step Functions

```json
{
  "StartAt": "KBMetadataLookup",
  "States": {
    "KBMetadataLookup": {
      "Type": "Task",
      "Resource": "arn:aws:states:::bedrock-agentcore:invokeRuntime",
      "Parameters": {
        "RuntimeArn": "${OrchestratorRuntimeArn}",
        "Payload": { "action": "kb_lookup", "query.$": "$.query" }
      },
      "Next": "ConfidenceCheck"
    },
    "ConfidenceCheck": {
      "Type": "Choice",
      "Choices": [{
        "Variable": "$.confidence",
        "NumericGreaterThanEquals": 0.85,
        "Next": "ParallelSpecialists"
      }],
      "Default": "IntentClassify"
    },
    "IntentClassify": {
      "Type": "Task",
      "Resource": "arn:aws:states:::bedrock-agentcore:invokeRuntime",
      "Next": "ParallelSpecialists"
    },
    "ParallelSpecialists": {
      "Type": "Parallel",
      "Branches": [
        { "StartAt": "Specialist1", "States": { "Specialist1": { "Type": "Task", "End": true } } },
        { "StartAt": "Specialist2", "States": { "Specialist2": { "Type": "Task", "End": true } } },
        { "StartAt": "Specialist3", "States": { "Specialist3": { "Type": "Task", "End": true } } },
        { "StartAt": "Specialist4", "States": { "Specialist4": { "Type": "Task", "End": true } } }
      ],
      "Next": "RRFFusion"
    },
    "RRFFusion": {
      "Type": "Task",
      "Resource": "arn:aws:states:::bedrock-agentcore:invokeRuntime",
      "Next": "Validate"
    },
    "Validate": {
      "Type": "Task",
      "Resource": "arn:aws:states:::bedrock-agentcore:invokeRuntime",
      "End": true
    }
  }
}
```

### Studio Implications

The studio generates both modes from the same UI:
- User picks a structured pattern (sequential, parallel, supervisor, router) → studio generates `application.yaml` + Step Functions ASL → deploy
- User picks swarm → studio generates `application.yaml` with `can_call` mesh → deploy (no Step Functions)
- Each agent in any pattern: system prompt + tools + model (no custom code needed for orchestration)

Step Functions makes the studio viable for multi-agent patterns without requiring developers to write orchestration code. The state machine IS the orchestration. The agent code is just system prompt + tools.

## Consequences

- Step Functions adds ~$0.025 per 1000 state transitions — negligible for agent workloads
- Platform needs a Step Functions module in `eap-terraform-modules`
- Deploy-template needs ASL generation logic from `application.yaml`
- Swarm pattern works today with just env var injection (no new infrastructure)
- Both modes are framework-agnostic — any framework inside the runtime
- OTel traces cover both modes (Step Functions has native X-Ray integration)

## References

- [AWS Prescriptive Guidance: Workflow for Orchestration](https://docs.aws.amazon.com/prescriptive-guidance/latest/agentic-ai-patterns/workflow-for-orchestration.html)
- [Multi-Agent Collaboration Patterns with Strands Agents](https://aws.amazon.com/blogs/machine-learning/multi-agent-collaboration-patterns-with-strands-agents-and-amazon-nova/)
- [A2A Protocol Support in AgentCore Runtime](https://aws.amazon.com/blogs/machine-learning/introducing-agent-to-agent-protocol-support-in-amazon-bedrock-agentcore-runtime/)
- [AWS Prescriptive Guidance: Design for Composability](https://docs.aws.amazon.com/prescriptive-guidance/latest/strategy-operationalizing-agentic-ai/focus-areas-composability-collaboration.html)
- [Agent Builder — GAAB Workflow Builder](https://docs.aws.amazon.com/solutions/latest/generative-ai-application-builder-on-aws/agent-builder-1.html)
- `018-platform-vending-model.md` — Architecture patterns and hierarchy
- `017-identity-architecture.md` — A2A communication via Gateway
