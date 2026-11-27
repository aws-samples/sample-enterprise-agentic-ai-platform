# ADR-048: Manual Approval Before Deploying ADE-Generated Agents

**Status:** Accepted
**Date:** 2026-11-24

## Context

The Agent Deployment Engineer (ADE) turns a chat request into agent YAML and
code, commits it to the `nocode-user` CodeCommit repository and starts the
`nocode-user` deploy pipeline (`studio/app/tools/pipeline_trigger.py`). The
pipeline runs Source → Build → Deploy → Verify → Evaluate → Gate. The
Evaluate and Gate stages run after Deploy, so they report on an agent that is
already running rather than stopping it.

That made the ADE a path from untrusted text to running code. A user who steers
the ADE with prompt injection, or content the ADE reads, could get attacker-
chosen code deployed as an AgentCore runtime with the runtime role's
permissions, with no person looking at it first. The threat model records this
as T-007 (High).

Team pipelines are different: their commits come from people pushing to Git,
where the team's own review process applies.

## Decision

We will add an optional `Approve` stage (CodePipeline manual approval action,
`ReviewChange`) between Build and Deploy in the pipeline module, controlled by
`require_manual_approval` (default `false`). The `nocode-user-deploy` entry in
`agent_pipelines` sets it to `true`, so every ADE-generated change waits for a
reviewer to approve it in the CodePipeline console before Terraform deploys it.

The ADE's tool response tells the user the deploy is waiting for approval. The
console's deployment tracker already shows the current stage, so it shows
`Approve` while the execution waits.

## Consequences

- No ADE-generated code runs until a person approves it. A rejected or expired
  approval fails the execution.
- The ADE demo flow has a manual step: someone with CodePipeline access must
  approve each build. Unapproved executions time out after 7 days (CodePipeline
  default).
- Team pipelines are unchanged; deployers can set `require_manual_approval =
  true` on any entry in `agent_pipelines`.
- The approval action needs no extra IAM on the pipeline role. Reviewers need
  `codepipeline:PutApprovalResult` on the pipeline.
- Moving Evaluate and Gate before Deploy (so a failing evaluation blocks the
  deploy) remains a production recommendation in the threat model; it needs a
  pre-deploy evaluation environment.

## Alternatives Considered

- **Move the evaluation gate before Deploy.** Better automation, but
  evaluations need a running agent, so this needs a separate staging runtime.
  Larger change, and it still trusts model-generated code to pass automated
  checks only.
- **Have the ADE open a review request instead of committing to the branch.**
  CodeCommit pull requests would need a merge step outside the ADE flow and a
  second pipeline trigger. More moving parts than an approval stage.
- **Document the risk and accept it for the sample.** The ADE is a headline
  feature and the repository is public, so the default should be safe.
