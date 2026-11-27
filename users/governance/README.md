# EAP Governance

Governance-owned configuration for the Enterprise Agentic AI Platform (EAP).

**Owner**: AI Governance & Risk

**Purpose**: Defines evaluation thresholds, graduation policies, red-team test suites, and Cedar policy definitions that govern agent lifecycle progression. Changes here take effect immediately on the next agent pipeline execution — no platform deployment required.

## Contents

| File | Purpose |
|------|---------|
| `graduation-policy.yaml` | Evaluation thresholds per environment and domain. Agents must meet these to graduate. |
| `red-team-suites/` | Adversarial prompt sets for QA certification (future) |
| `cedar-policies/` | Cedar policy definitions for tool authorization (future) |

## How It Works

1. AI Governance edits `graduation-policy.yaml` (PR reviewed by governance team)
2. On merge, a lightweight pipeline validates the YAML against the schema and uploads to S3
3. The agent pipeline's gate stage reads the latest policy from S3 at execution time
4. No platform deployment needed — policy changes are live immediately

## Ownership

- **AI Governance & Risk**: Writes and maintains policies
- **Domain Admins**: Can submit PRs for domain-specific overrides (must be stricter than platform defaults)
- **Platform Engineering**: Owns the pipeline that validates and uploads (in `eap-terraform-modules`)
- **Developers**: Cannot modify this repo — read-only access

## Schema

The graduation-policy.yaml is validated against the JSON Schema at:
`eap-terraform-modules/modules/pipeline/buildspecs/graduation-policy-schema.json`
