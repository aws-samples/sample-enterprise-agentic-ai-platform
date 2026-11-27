# ADR-036: Two Deployment Presets — `demo` and `enterprise`

**Status:** Accepted
**Date:** 2026-09-14

## Context

The platform shipped **three** deployment presets under
`platform/eap-platform/configs/`: `demo`, `poc`, and `pilot`. Each is a
`.tfvars` file that sets the platform's existing input variables to a posture.

In practice the three were not three distinct architectures — they were **two
postures plus a maturity slider**:

- `demo` — public console, agents on AgentCore-managed **public** endpoints,
  platform-created Cognito + VPC (observability-only) + all IAM roles,
  self-hosted Langfuse on. The "show it works in 20 minutes" mode.
- `poc` — **no public console**, agents **in-VPC**, externalized standalone IAM
  roles, Cognito reference IdP used as-is, Langfuse on. Hardened shape, but using
  the platform's *reference* components pending Enterprise Architecture approval.
- `pilot` — the same hardened shape as `poc`, but with the reference components
  **swapped for the customer's own**: external OIDC IdP (no Cognito), external
  OTLP backend (Langfuse off), customer-managed KMS key, pre-created IAM roles.

The decisive observation: `poc` and `pilot` share one architecture (console-off,
in-VPC, externalized roles). Their only difference is *how many enterprise
components have been brought in yet* — which is a set of independent input
overrides (`oidc_discovery_url`, `otel_backend_endpoint`, `kms_key_arn`,
`vpc_id`, `*_role_arn`), not a different platform shape. As soon as small,
independently-desirable tweaks were applied (turn Langfuse off in `poc`; run
agents in-VPC by default because the audience is enterprises), `poc` collapsed
toward `pilot` and the three presets smeared into each other.

Maintaining three presets therefore cost documentation, test beds (one per
preset), and ADR cross-references without expressing three real decisions.

## Decision

**We will ship exactly two deployment presets: `demo` and `enterprise`.**
"POC" and "Pilot" are no longer presets — they are **maturity stages of the
`enterprise` preset**, reached by progressively filling in independent override
blocks.

1. **`configs/demo.tfvars`** — unchanged. Public console, PUBLIC agents, Cognito,
   self-hosted Langfuse, platform-created VPC + IAM roles. The self-contained
   "show it works" path; a bare `terraform apply` with no `-var-file` produces
   the same result.

2. **`configs/enterprise.tfvars`** — the hardened base:
   `deploy_console = false`, `agent_network_mode = "VPC"`,
   `deploy_langfuse = false` (AWS-native CloudWatch/X-Ray only unless overridden),
   `enable_transaction_search = false`. It is **self-contained by default** — with
   `vpc_id` empty the platform *creates* the VPC and runs agents in it, and IAM
   roles are platform-created — so it is runnable in our own account with **no
   bring-your-own inputs** (the former "POC" stage). It carries commented
   **OVERRIDE blocks** to advance to the former "Pilot" stage: import a VPC
   (`vpc_id` + subnets), external OIDC IdP (`oidc_discovery_url` → skips Cognito),
   external OTLP backend (`otel_backend_endpoint`), customer-managed KMS key
   (`kms_key_arn`), and externalized standalone roles (the five `*_role_arn`;
   ADR-033 keeps the 10 pipeline roles platform-created).

3. **`configs/poc.tfvars` and `configs/pilot.tfvars` are deleted.**

4. **Test beds** collapse the same way: the former `poc-testbed` becomes
   `enterprise-testbed` (self-contained: creates its VPC + IAM fixtures, with the
   BYO-overrides path folded in), and the `pilot-testbed` is removed. The
   `demo-testbed` is unchanged.

This preserves the single most valuable property of the old `poc` preset — an
enterprise-shaped deployment that is **runnable in our own account with no
external dependencies** — while expressing the `pilot` distinction as overrides
rather than a separate artifact.

## Consequences

- **Simpler, honest model.** Two presets map to the two real audiences:
  throwaway demo vs hardened enterprise. The demo-vs-enterprise choice is a
  preset; the POC-vs-Pilot progression is documented overrides.
- **Enterprise-default observability changes.** `enterprise` defaults to
  **AWS-native observability only** (Langfuse off). Operators opt into a private
  Langfuse (`deploy_langfuse = true`) or an external OTLP backend
  (`otel_backend_endpoint`). Turning Langfuse off is gated cleanly — the module
  is `count`-gated, so nothing Langfuse-related is created (ADR-030).
- **Docs/test-bed churn (one-time).** ADR-033 and ADR-035 preset references, the
  DEPLOY-RUNBOOK preset line, the test beds, and `.gitignore` (the generated
  resolved tfvars name) are updated to the two-preset vocabulary. This ADR
  supersedes the earlier three-preset (`poc`/`pilot`/`demo`) framing going
  forward.
- **No platform *code* change.** The collapse is entirely at the preset/tfvars
  and tooling layer. Every knob was already an independent platform variable;
  `enterprise` just chooses defaults and documents the overrides. The
  `agent_vpc_enabled = agent_network_mode == "VPC" && local.vpc_id != ""` gate
  (ADR-031) already resolves a platform-created VPC, so `enterprise` runs agents
  in-VPC without an imported VPC.
- **Cost note.** `enterprise` in its self-contained default creates a VPC + NAT +
  interface endpoints (standing hourly cost, per ADR-031/032) — this is the
  enterprise-shaped cost, unlike `demo` which is public/cheap.

## Alternatives Considered

- **Keep three presets.** Rejected: `poc` and `pilot` are one architecture at two
  maturity points; three files cost docs/tests/ADR cross-refs without expressing
  three decisions, and small intended tweaks collapse them anyway.
- **One preset + all overrides (no `demo`).** Rejected: `demo`'s public,
  self-contained, cheap posture is genuinely distinct and is the fastest path to
  "see it work"; folding it into overrides would lose that.
- **A single `mode` variable (`demo|poc|pilot`) inside one tfvars.** Rejected:
  reintroduces the three-way smear as an enum and hides the real independence of
  the override knobs; the preset-file + override-block approach keeps each knob
  explicit.

## References

- Supersedes the three-preset model documented across ADR-033 (IAM roles) and
  ADR-035 (KMS) preset wiring; those ADRs' *decisions* are unchanged — only their
  preset **names** are updated to `demo`/`enterprise`.
- ADR-030 (private, pluggable observability — Langfuse optional / external OTLP).
- ADR-031 (agents in-VPC by default) and ADR-032 (platform Lambdas in-VPC).
- ADR-034 (`deploy_console` optional).
