# ADR-025: Agent Observability — AWS-Native (AgentCore Observability) with Pluggable OTLP Backends

**Status**: Superseded by ADR-030
**Date**: 2026-07-22

> **Superseded by [ADR-030](030-observability-private-pluggable.md)** (2026-09-02):
> the third-party leg is now private (OTel collector always-on; Langfuse an
> optional private internal-HTTP backend, no public/CloudFront/ACM) with an
> external OTLP backend override and BYO-VPC-or-create. The AWS-native leg
> described below is unchanged. The pluggable-OTLP principle here still holds;
> only the third-party hosting/exposure model changed.

---

## Context

Every agent on the platform must be observable — traces, spans, token usage,
latency, and errors — without app teams writing instrumentation code (tenet
T5: Unified Observability). Two questions came up as the platform matured:

1. **How do agents emit telemetry, and where does it land?** The Strands base
   image historically shipped the *vanilla* OpenTelemetry distro
   (`opentelemetry-distro` + `opentelemetry-exporter-otlp`) and ran
   `opentelemetry-instrument`. That works, but it is the generic OSS path and
   does not, by itself, route GenAI spans into the AWS-native observability
   surface (CloudWatch GenAI Observability).

2. **Should we self-host a dedicated LLM-observability product (e.g. Langfuse)?**
   Langfuse offers a rich trace/prompt/eval UI, but self-hosting it means
   operating a 4-datastore stateful stack (ECS + Aurora + ClickHouse + Redis),
   which cuts against the platform tenets of AWS-native, no extra abstractions,
   and clear blast radius.

A key realization framed the decision: **OpenTelemetry is an emission standard,
not a destination.** Langfuse, Datadog, Fiddler, and CloudWatch are all
*backends* that consume OTLP. AgentCore itself emits OTEL and integrates with
any of them. So the real choice is "which backend is the default," not "OTel vs
Langfuse."

A second realization about AgentCore Runtime: for runtime-hosted agents,
observability is **auto-enabled** — the runtime instruments the agent with OTEL
automatically. The only in-image requirement to land GenAI spans in CloudWatch
GenAI Observability is the **AWS Distro for OpenTelemetry (ADOT)**
(`aws-opentelemetry-distro`), which bundles the OTLP exporter plus the AWS
configurator. The generic distro does not.

## Decision

**AWS-native AgentCore Observability is the default. Third-party OTLP backends
(Langfuse, Datadog, Fiddler, …) are optional, pluggable sinks — never the
default and never required.**

Concretely:

1. **Base image uses ADOT.** The Strands base image (`base-images/strands`)
   depends on `aws-opentelemetry-distro>=0.10.0` (which bundles the OTLP
   exporter + AWS configurator) instead of the vanilla
   `opentelemetry-distro` / `opentelemetry-exporter-otlp` packages. The
   `opentelemetry-instrument` entrypoint is unchanged. On AgentCore Runtime the
   export pipeline is auto-configured by the runtime — no `OTEL_EXPORTER_OTLP_*`
   wiring in our Terraform.

2. **Telemetry lands in CloudWatch GenAI Observability + X-Ray Transaction
   Search.** These AWS-managed surfaces provide traces, session count, latency,
   duration, token usage, and error rate with per-step span drill-down — the
   ~90% of Langfuse's value that most teams need, with zero self-hosted
   infrastructure.

3. **Transaction Search is enabled at deploy time via Terraform.** It is an
   account+region-wide singleton, so it lives once per platform instance in
   `eap-platform` as `aws_cloudformation_stack.transaction_search`
   wrapping the `AWS::XRay::TransactionSearchConfig` CloudFormation resource
   (no new provider required). Gated by `enable_transaction_search` (default
   `true`) with `transaction_search_indexing_percentage` (default `5`).

4. **Indexing percentage default is 5%, not 100%.** Ingestion is billed on all
   spans regardless of this value and is what provides full end-to-end trace
   visibility; the percentage only controls how many spans are indexed as
   *queryable trace summaries* (the first 1% is free). 5% gives
   attribute-search headroom at near-zero extra cost and scales sanely when
   vended to enterprise-volume BUs. Teams needing high-volume span-attribute
   search override per instance.

5. **UI exposure is AWS-native.** The console cannot iframe the AWS console
   (`X-Frame-Options: DENY`). Exposure to the EAP UI is therefore:
   (a) a **federated "View in CloudWatch" deep-link** (STS AssumeRole → console
   sign-in URL, scoped read-only, pre-filtered to the agent) as the day-one
   path, and (b) **native panels** in an `ObservabilityWorkspace` that read
   X-Ray (`GetTraceSummaries`/`BatchGetTraces`) + CloudWatch metrics/Logs
   Insights and render on-brand. Both hang off the same OTEL emission layer.

6. **Langfuse (and other backends) are optional add-ons.** Because agents are
   already OTEL/ADOT-instrumented, adding a third-party backend later is just an
   additional OTLP exporter target (best done via an OTel Collector fan-out so
   CloudWatch/X-Ray export is preserved), not a rip-and-replace. We do **not**
   stand up Langfuse by default.

## Consequences

**Positive**
- Zero self-hosted observability infrastructure; fully AWS-managed, aligned with
  tenets (AWS-native, no extra abstractions, clear blast radius).
- Observability works out-of-the-box at deploy time (Transaction Search enabled
  by Terraform; runtime auto-instruments).
- Cost is volume-driven and controlled by a single indexing knob; the default
  is inexpensive and scales.
- No lock-in: any OTLP backend can be added later without touching agent code.

**Negative / trade-offs**
- CloudWatch GenAI Observability's trace UI is less specialized than Langfuse's
  for prompt iteration; teams wanting that must opt into a pluggable backend.
- Prompt-versioning and per-agent cost attribution are addressed by the
  separate platform features (a governed prompt library, LLM Gateway metering)
  rather than a third-party tool.
- Transaction Search is account/region-wide (singleton), so it is a
  platform-instance concern, not per-agent — enabling/disabling affects all
  agents in that account.

## Notes / History

- 2026-07-22 (later): **Partially superseded.** The stance "Langfuse is optional and never the
  default" was revised by the `agentcore-observability` spec. The platform now deploys a
  self-hosted Langfuse stack as the **default** third-party OTLP backend (embedded in the
  console), while AWS-native AgentCore Observability remains the always-on primary leg. Agent
  telemetry reaches the third-party backend via an **additive** in-process OTLP exporter → a
  platform OTel Collector (third-party leg only); the AWS-native leg stays on AgentCore's own
  auto-instrumentation and is never routed through a collector. The third-party backend is
  configurable (Langfuse by default; Fiddler/Datadog/etc. as alternates). The
  Langfuse pattern is adapted from AVA (Apache-2.0) — see Attribution above.
- 2026-07-22: Base image swapped vanilla OTel → `aws-opentelemetry-distro`.
  Transaction Search added to `eap-platform` as a Terraform-managed
  CloudFormation stack (`eap-xray-transaction-search`, `CREATE_COMPLETE`),
  destination `CloudWatchLogs`/`ACTIVE`, indexing default 5%. The account had
  Transaction Search previously enabled out-of-band at 1%; it is now
  Terraform-owned.

## Attribution

The self-hosted Langfuse observability pattern adopted by the follow-on decision (see the
supersession note below) is adapted from the AWS-samples **Agentic Value Accelerator (AVA)**
project, used under the Apache License 2.0.

- Source: https://github.com/aws-samples/sample-agentic-value-accelerator
- License: Apache License 2.0

## References

- AgentCore Observability: https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/observability-configure.html
- CloudWatch Transaction Search: https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/CloudWatch-Transaction-Search.html
- `AWS::XRay::TransactionSearchConfig`: https://docs.aws.amazon.com/AWSCloudFormation/latest/TemplateReference/aws-resource-xray-transactionsearchconfig.html
- Key tenet T5 (Unified Observability): `docs/key-tenets.md`
- Agentic Value Accelerator (AVA), Apache-2.0: https://github.com/aws-samples/sample-agentic-value-accelerator
