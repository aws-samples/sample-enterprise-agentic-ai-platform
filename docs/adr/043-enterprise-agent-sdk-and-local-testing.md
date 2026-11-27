# ADR-043: Enterprise Agent SDK as the Single Horizontal-Injection Implementation — Base Image Dogfoods It, CI Enforces Usage, Floci Is the Local-Test Substrate

**Status:** Proposed
**Date:** 2026-09-30

## Context

The platform injects cross-cutting concerns into every agent **transparently via
the base image** (ADR-006 "no higher-level abstractions", ADR-015 "horizontal
injection via base images", ADR-016 protocols). Today `base-images/strands/`
owns the entire agent process: `entrypoint.py` wraps the app team's `agent`
object in a Strands `A2AServer` on port 9000, auto-registers A2A peer tools from
`*_RUNTIME_NAME` env vars, and adds the additive third-party OTel span exporter
(resolving the collector endpoint from the fixed SSM parameter
`/eap/observability/collector-endpoint`, per ADR-030). The app team writes
only `agent/main.py` (exposing an `agent` object) and `agent.yaml`; their
`buildspec.yml` is empty — all wiring is platform-owned.

This model has real strengths (governance is guaranteed because injection does
not depend on app code) but three gaps have surfaced:

1. **No local test loop.** The agent's observability, A2A peer resolution, and
   span export all assume a live AgentCore runtime + SSM + an in-VPC collector.
   An app team cannot run or `pytest` the full agent locally without AWS. The
   documented ~28s input-unlock stall (a blocking OTel exporter retry when the
   collector was unreachable) is a symptom of this boot-time coupling to live
   infrastructure.
2. **Framework lock-in.** The injection lives in a Strands-specific base image
   (`base-images/strands/`). The README advertises "framework and model
   agnostic", but a LangGraph/CrewAI agent cannot reuse the horizontals.
3. **Transparency/debuggability.** The `opentelemetry-instrument` entrypoint plus
   implicit SSM resolution is hard for an app author to reason about when
   telemetry misbehaves.

A proposal was raised to move the horizontals into an **importable enterprise
library** that developers add to their agent, with a **local mode** testable
against a local cloud emulator, and to **enforce the import via the CI/CD
pipeline**. Two clarifications shaped this decision:

- The library and the base image are **not mutually exclusive** — they are layers
  of one design (implementation vs. production enforcement floor).
- "Enforce the import via CI" is a **governance gate on developer code**, which
  is a *consistency/detective* control, not a *technical guarantee*. The only
  guarantee that does not depend on developer discipline is the base image
  continuing to apply the horizontals regardless of app code.

The chosen local emulator is **Floci** (https://floci.io) — an MIT-licensed,
token-free, multi-cloud (AWS/Azure/GCP/OCI) emulator (~24ms cold start, 119 AWS
services on `:4566`), same category as LocalStack. It emulates the AWS
**control plane** the platform depends on (S3, DynamoDB, SSM, Step Functions,
Lambda, Secrets Manager, CloudWatch Logs). It does **not** emulate **Bedrock
AgentCore Runtime** or **Bedrock model inference** — those are proprietary
agent-plane services outside its scope.

## Decision

**We will introduce an Enterprise Agent SDK as the single implementation of the
agent horizontals, have the base image dogfood that SDK as the production
enforcement floor, enforce SDK usage through platform-owned CI/CD gates for
consistency, and adopt Floci as the local-test substrate.** The transparent,
guaranteed-injection posture (ADR-015) is preserved — the SDK is an
*implementation and developer-facing refactor*, not a shift of governance onto
developers.

1. **Enterprise Agent SDK (the code).** A new platform-owned package under
   `platform/` (proposed `enterprise-agent-sdk/`, published to a private
   CodeArtifact/internal index) holds the real logic currently hand-rolled in
   `entrypoint.py`: A2A serve helpers, the peer-tool factory, the additive OTel
   exporter wiring, structured logging, and the credential helper. It is
   framework-aware (Strands first; a stable interface so LangGraph/CrewAI
   adapters can follow). The OTel **collector endpoint stays SSM-resolved at
   boot** — it is **never baked into the package** — so an endpoint change needs
   no library bump and no new runtime version (preserves ADR-030).

2. **Base image dogfoods the SDK (the production floor).** `entrypoint.py` stops
   re-implementing the horizontals and instead `import`s the SDK and calls its
   serve/telemetry/peer-tool helpers. The base image wraps whatever `agent`
   object it finds **regardless of whether the app team imported the SDK** — so
   telemetry and auth are on in production no matter what. One implementation,
   dogfooded; no second copy to drift.

3. **SDK `local` mode + Floci (the test loop).** The SDK exposes a `local` mode
   that stands up the A2A server (uvicorn on 9000) and points its AWS-touching
   paths (SSM collector-endpoint read, lifecycle DynamoDB, SFN, Secrets) at Floci
   via standard AWS endpoint env vars, with a local OTel collector + Langfuse
   (docker-compose) receiving spans. The model is either stubbed or pointed at
   real Bedrock. App teams get `AGENTS.md`/`CLAUDE.md` "teach-once" guidance and a
   `docker-compose.local.yml`. **Known limitation:** AgentCore Runtime and
   Bedrock inference are not emulated by Floci, so local testing covers the agent
   *A2A contract* and *everything around it*; AgentCore-specific behavior is still
   only fully exercised in a real account (the testbeds).

4. **CI/CD enforcement (consistency gate, not the guarantee).** Platform-owned
   stages in `modules/pipeline` (which app teams cannot edit) enforce SDK usage
   in layers:
   - **Dependency control:** Build resolves the SDK only from the private index;
     a step asserts the SDK is installed at an approved version range.
   - **Static usage check:** an AST/`semgrep` rule in
     `modules/pipeline/scripts/` asserts the agent imports the SDK and calls its
     initializer (survives aliasing; checks *call* presence, not just import).
   - **Runtime self-report:** the Verify stage's A2A health check additionally
     asserts the agent self-reports a compliant SDK init (version, telemetry
     registered, auth wired) — catching "imported but not initialized".
   These gates enforce *that developers built the sanctioned way*; the base-image
   floor (item 2) enforces *that production is compliant regardless*.

5. **Floci is adopted independently of the SDK.** Floci is useful against the
   **current** design today (the three Express backends, the SSM/DynamoDB/SFN/
   Secrets plumbing, pipeline scripts, and `terraform plan` dry-runs), and may be
   wired into Verify/Evaluate stages as an ephemeral per-job cloud. Its adoption
   does not depend on items 1–4.

## Consequences

- **Local test loop, finally.** App teams iterate and `pytest` the agent + its
  control-plane dependencies locally with no AWS account, no credentials, and
  zero blast radius — the main gap this ADR closes.
- **Governance guarantee preserved.** Because the base image still wraps the
  agent, telemetry/auth are not optional; the CI "must import" rule is a
  consistency/detective control, honestly scoped as such (it is bypassable by
  anyone who can edit the buildspec or deploy outside the pipeline — which the
  base-image floor backstops).
- **Framework reach.** A stable SDK interface is the path to the README's
  "framework agnostic" claim; Strands ships first, others follow as adapters.
- **Chance to fix the exporter stall.** Consolidating the exporter wiring in the
  SDK is the natural place to make span export non-blocking by design (short
  timeout), addressing the documented ~28s input-unlock issue at the source.
- **One implementation, versioned.** The horizontals become a versioned
  dependency with a release/compatibility surface the platform must manage
  (SDK ↔ base-image ↔ AgentCore ADOT provider). The base image must keep *not*
  overriding `OTEL_EXPORTER_OTLP_ENDPOINT` and *adding* (not replacing)
  AgentCore's managed tracer provider — the SDK inherits that invariant
  (ADR-030, ADR-025).
- **New CI surface.** The static-usage and self-report gates are new
  platform-owned scripts to build and maintain alongside the graduation-gate
  scripts.
- **Local ≠ full fidelity.** Floci cannot prove AgentCore/Bedrock behavior;
  teams must still run the testbeds for end-to-end validation. This must be
  stated plainly in developer docs so local green is not mistaken for
  production-ready.

## Alternatives Considered

- **Status quo (base-image injection only).** Rejected: leaves the three gaps
  (no local loop, Strands lock-in, opacity) unaddressed.
- **Pure library, remove base-image injection.** Rejected: inverts ADR-015 and
  the "YAML in, infrastructure out" thesis (ADR-029) by making governance
  depend on developer discipline — an agent could ship with telemetry/auth off.
  Also risks shadowing AgentCore's managed OTel provider if the library
  initializes its own.
- **Bake the collector endpoint / backend address into the SDK package.**
  Rejected: ADR-030 keeps the endpoint SSM-resolved so it changes with no
  rebuild; a versioned package would turn every endpoint change into a
  cross-agent library bump.
- **Keep two implementations (base image + separate dev-only lib).** Rejected as
  the end state: guaranteed drift between the production path and the tested
  path. The SDK is the single implementation; the base image consumes it.
- **Use LocalStack instead of Floci.** Same category and viable; Floci chosen
  for token-free use (LocalStack began requiring an auth token in 2026),
  faster cold start, and MIT licensing. Neither emulates AgentCore Runtime —
  that limitation is independent of the choice.
- **Rely on CI enforcement alone for the guarantee (no base-image floor).**
  Rejected: CI gates on developer-written code are bypassable and are a policy
  control, not a technical guarantee; the base-image floor is what makes the
  guarantee hold.

---
<!-- Relates to ADR-015 (horizontal injection via base images), ADR-016 (protocols),
     ADR-030 (private pluggable observability — collector endpoint via SSM),
     ADR-029 (YAML in, infrastructure out). Supersedes nothing. -->
