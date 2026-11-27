# ADR-011: PV/PVC Pattern Not Needed for AgentCore Memory

**Status:** Accepted (applies to both tracks)
**Date:** 2026-03-13

**Context:** AgentCore Memory is fully managed by AWS. There is no "backing store" to provision.

**Decision:** Remove the PV/PVC pattern. App teams declare memory needs directly via the memory module. No separate claim/binding step.

**Consequences:** Terraform track uses `modules/memory` directly — app team specifies memory type and AgentCore provisions it. Cross-agent memory sharing via same memory resource ID reference.
