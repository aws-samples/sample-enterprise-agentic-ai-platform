# ADR-026: Platform State Architecture — Three Layers of State

**Status**: Confirmed
**Date**: 2026-07-22

---

## Context

As the platform matured we accumulated more than one thing called "state," and
it was not always clear which one was authoritative for a given fact. Concretely:

- The console's "My Deployed Agents" view and the invoke-proxy allow-list need
  to know **what is actually deployed** (runtime ARNs, entrypoint, topology,
  lifecycle stage).
- Terraform holds its own state files (`s3://eap-platform-state/…`) that
  record **what infrastructure it manages**.
- The deployable intent for every agent lives in Git (CodeCommit) as
  `agent.yaml` / `application.yaml` manifests.

The guiding instinct was "DynamoDB should be the single source of truth, like
etcd is for Kubernetes." That instinct is right in spirit but wrong if taken
literally: DynamoDB here is **not** etcd, and conflating the three kinds of
state is what led to problems such as an orphaned pipeline (managed in a stale
local Terraform state, absent from the authoritative remote state) and the
console reverse-engineering truncated runtime names.

This ADR names the three layers, assigns a single owner to each, and records the
principle that keeps them from competing.

## Decision

The platform has **three distinct layers of state**, each authoritative for one
concern. No fact is owned by more than one layer.

| Layer | Store | Owns (authoritative for) | Written by | Read by | Analogy |
|-------|-------|--------------------------|------------|---------|---------|
| **Desired state** | Git / CodeCommit — `agent.yaml`, `application.yaml` | *What should exist* — declared agents, topology, patterns, intent | Developers / ADE (Studio) commits | Deploy pipeline | Kubernetes object manifests (the declared spec) |
| **Provisioning ledger** | Terraform state (S3 backend `eap-platform-state`, key `platform/terraform.tfstate`) | *What infrastructure Terraform manages and how to change it* — resource IDs, dependencies | `terraform apply` (Platform Operator + pipelines) | Terraform only, at plan/apply time | The `terraform apply` bookkeeping — not a runtime store |
| **Observed / operational state** | DynamoDB lifecycle table (`agent-school-lifecycle-{env}`, single shared table; BU per-item) | *What is actually deployed right now* — real runtime ARNs, app grouping, entrypoint, per-app topology, lifecycle stage | Deploy pipelines (recorder in `deploy.yaml`) + one-time backfill | Console (`studio-read`), `invoke-proxy` allow-list, dashboards | A read-model / materialized projection of reality |

### Principles

1. **Git is the source of truth for intent.** The manifests are what *should*
   be deployed. Neither Terraform state nor DynamoDB is intent — they are
   consequences of applying intent.
2. **Terraform state is a provisioning ledger, never a runtime store.** The
   running platform (console, proxy) MUST NOT read Terraform state. It records
   how to reconcile a `terraform apply`, nothing more.
3. **DynamoDB is the operational read-model / single source of truth for
   observed deployed-agent facts.** It is optimized for low-latency reads,
   per-BU scoping, and cheap scans. Runtime consumers read it.
4. **One fact, one owner.** Where a fact is derivable from more than one layer
   (e.g. a runtime ARN exists in both Terraform state and could be listed from
   AgentCore), DynamoDB is the authority for the *runtime read path*, and the
   pipeline (which runs Terraform) is responsible for writing it there.
5. **The BU/domain is data, not a table name.** All BUs write to one shared
   lifecycle table with a `bu` attribute per item, so the console is naturally
   multi-BU. (See "single shared table" decision below.)

### Why DynamoDB is NOT etcd (and shouldn't try to be)

etcd's defining properties are: it holds both desired and observed state; it
offers `watch`/notify so controllers receive change events; control loops
continuously **reconcile** actual → desired; and it provides strong consistency
with leases/TTL. What we operate today is a **push-on-deploy projection**: the
pipeline writes facts when a deploy succeeds, and nothing continuously reconciles
them. Specifically, we do **not** have:

- a reconciliation loop (CodePipeline is a one-shot, commit-triggered apply, not
  a controller that keeps actual == desired);
- watch/eventing (consumers scan/poll; there is no subscribe-to-changes);
- convergence on drift (a runtime deleted out-of-band, or a half-failed deploy,
  is not automatically corrected — the row goes stale).

This is a legitimate and common **GitOps + read-model** pattern, and it is the
right fit for a deployed-agent registry. Chasing full etcd semantics on top of
DynamoDB would mean bolting on DynamoDB Streams + a controller Lambda, or —
if true declarative reconciliation is the goal — running the control plane on
Kubernetes with CRDs + controllers (tracked separately under `eap-k8s`).
We explicitly choose **not** to do that for the registry use case.

### Single shared lifecycle table

All vended pipelines write deployed-agent state to **one** shared table
(`agent-school-lifecycle-{env}`), with the owning business unit recorded as a
`bu` attribute on each item rather than encoded in the table name. `bu` is a
plain (non-key) attribute — DynamoDB is schemaless for non-key attributes and
the read path uses `Scan` with in-memory grouping, so no `bu` GSI is required.
(A `bu-index` GSI can be added later as its own isolated change if query-by-BU
becomes hot; adding a GSI to the live table must be done in isolation because
DynamoDB permits only one GSI create/delete per `UpdateTable` and the existing
`app-index` must not be disturbed.)

## Consequences

- The console and invoke-proxy have a single, authoritative place to read
  deployed-agent facts, and it is multi-BU by construction.
- Terraform state ambiguity (which root/state manages a resource) is a
  provisioning concern only; it never affects the runtime read path.
- The known gap is **drift / convergence**: because the recorder only writes on
  successful deploy, deletions and failed deploys leave stale rows. The backfill
  script is a manual, one-shot reconciler. Closing this gap with an automated
  reconciler is recorded as future work (see below).

## Future Work: State Reconciler (the missing control loop)

To gain the one etcd-like property with real operational value — **convergence /
drift detection** — add a reconciler that periodically (or via DynamoDB Streams)
compares the observed store against reality and against intent:

- **Actual vs recorded**: scan AgentCore `ListAgentRuntimes` and mark lifecycle
  rows whose runtime no longer exists as `stopped` / `missing` (catches
  out-of-band deletes and failed deploys).
- **Intent vs actual**: optionally reconcile Git manifests against deployed
  runtimes to surface "declared but not deployed" and "deployed but undeclared"
  drift.
- **Mechanism**: a scheduled Lambda (EventBridge rate rule) for the periodic
  scan, and/or DynamoDB Streams for write-side propagation. Emit metrics/alarms
  on drift.
- **Effect**: turns the push-only recorder into a self-healing, converging view,
  making the operational store trustworthy without adopting full etcd/K8s
  semantics.

This is a **future requirement**, not yet implemented. See the reconciler description above.

## References

- `018-platform-vending-model.md` — personas, repos, BU hierarchy
- `platform/eap-platform/lifecycle-store/` — the shared DynamoDB table
- `platform/eap-terraform-modules/modules/pipeline/buildspecs/deploy.yaml` — the deploy-time recorder
