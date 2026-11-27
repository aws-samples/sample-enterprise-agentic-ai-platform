# ADR-045: Teardown Destroys Each App Through Its Own State Before the Platform
**Status:** Proposed
**Date:** 2026-11-13

## Context
EAP keeps Terraform state in two layers:

- **Platform state** (`eap-platform-state-<ACCOUNT_ID>`, key
  `platform/terraform.tfstate`): the VPC, pipelines, console, Langfuse, the
  OTel collector and the Agent Deployment Engineer (ADE).
- **Per-app state**: each agent pipeline's Deploy stage runs its own
  `terraform apply` (`modules/pipeline/buildspecs/deploy.yaml`) and stores
  state in that pipeline's artifacts bucket under `_tfstate/deploy.tfstate`.
  This owns every pipeline-deployed resource: agent runtimes and endpoints,
  runtime roles, memories, workload identities, invoke-bridge Lambdas, Step
  Functions state machines and their log groups.

The separation is deliberate: ADR-018 gives each repo "one owner, one purpose,
one deployment scope", so each app deploys on its own with its own blast
radius. ADR-026 calls Terraform state the provisioning ledger but describes it
as a single platform state; this ADR records that the ledger is in fact split
across the platform and every app. The test-bed teardown does not account for
that split:

1. The platform `terraform destroy` cannot see per-app resources, and it
   **deletes the pipeline artifacts buckets**, so the per-app state files are
   destroyed with them. After that, nothing can destroy the apps with
   Terraform.
2. To compensate, `98-predestroy.sh` deletes resources by **guessing names**
   with the AWS CLI. That guess is incomplete and silently lossy:
   - It matches only the `team_bu_1_` runtime prefix, so Studio-built
     `nocode_user_*` agents are never deleted.
   - It deletes only runtimes and empties ECR. It does not touch runtime
     roles, memories, invoke-bridge Lambdas, Step Functions state machines or
     their log groups.
   - When an endpoint delete times out it prints "re-run 98", skips that
     runtime, and carries on.
3. `99-teardown.sh` treats a failed platform destroy as a warning and still
   prints "Teardown complete."
4. AgentCore releases a VPC runtime's `agentic_ai` ENIs asynchronously, up to
   8 hours after the runtime is deleted. Until then the agents security group,
   subnets and VPC cannot be deleted, and the destroy hangs, then fails with
   `DependencyViolation`.

During the Declarant → EAP cutover (ADR-044) this produced:

- 13 agent runtimes still running after the destroy, holding the VPC's ENIs.
- 2 invoke-bridge Lambdas left behind.
- 32 orphaned resources (9 IAM roles, 5 state machines and their log groups,
  12 memories, 1 Lambda) whose names do not contain the platform name. They
  collided with the next deploy and failed its pipeline with
  `EntityAlreadyExists`.
- A teardown that reported success while ~420 platform resources still
  existed.

Two smaller defects were found in the same scripts:

- `98-predestroy.sh` empties the ADE ECR repo, but the platform destroy still
  reads that image (`data.aws_ecr_image.studio`), so every destroy fails at
  refresh unless run with `-refresh=false`.
- The post-destroy secret purge deletes every secret whose name starts with
  the platform prefix, not only the ones the destroy scheduled for deletion.

## Decision
We will make teardown follow the state layout, in this order:

1. **Destroy every app through its own state, first.** For each pipeline
   artifacts bucket, download `_tfstate/deploy.tfstate` and run
   `terraform destroy` against it, using the same deploy template the
   pipeline used, while the bucket still exists. Apps are discovered from the
   platform's pipeline outputs, not from resource-name prefixes. This covers
   team-bu-1 apps, Studio (`nocode-user`) apps, and any future BU.
2. **Wait for AgentCore ENIs to be released.** Poll the agents security group
   until no `agentic_ai` ENIs remain, with a bounded wait and a clear message
   if the bound is hit. Nothing is force-deleted; AWS does not allow it.
3. **Destroy the platform.** Run the platform destroy only after steps 1–2
   succeed. Order ECR cleanup so that images the destroy still reads are
   removed after it, or not read at destroy time.
4. **Run a name-based sweep only as a safety net.** After both destroys,
   list any remaining resources that match platform or app prefixes. Report
   them and **exit non-zero**; delete only what is provably orphaned (its
   owning state is gone).
5. **Fail loudly.** Any failed step stops the teardown with a non-zero exit.
   "Teardown complete" is printed only when every step succeeded.
6. **Purge only what was scheduled.** Force-purge only secrets that are
   already pending deletion.

This applies to both test beds (`test/demo-testbed`, `test/enterprise-testbed`)
and to the teardown steps in `platform/DEPLOY-RUNBOOK.md`.

## Consequences
- Terraform, not name guessing, removes every resource it created. New
  resource types added to the deploy templates are cleaned up automatically.
- A teardown that exits 0 means the account is actually clean, so a fresh
  deploy cannot collide with leftovers.
- Teardown takes longer: per-app destroys run first, and the ENI wait can add
  up to several hours in the worst case.
- The teardown needs the deploy templates and Terraform locally to run the
  per-app destroys, the same toolchain the deploy already needs.
- If an app's state is already lost (as in the ADR-044 cutover), step 4 is
  the only remedy. It reports those resources rather than silently ignoring
  them.

## Alternatives Considered
- **Keep name-based cleanup and widen the prefixes.** Cheapest change, but
  every new resource type or BU needs a script update, and it fails silently
  when one is missed. This is the approach that failed here.
- **Move app resources into platform state.** One destroy removes
  everything, but it couples every app deploy to the platform state and lock,
  which breaks ADR-018's one-deployment-scope-per-repo model.
- **Keep pipeline state somewhere the platform destroy does not delete**
  (for example, a retained bucket). Preserves the state, but still needs a
  per-app destroy step, and leaves state outliving the resources if teardown
  is skipped. Can be combined with this decision later.
- **Tag everything and delete by tag** (Resource Groups Tagging API). Useful
  as the safety net in step 4, but not every resource type supports tags or
  tag-based lookup, and it bypasses Terraform's dependency ordering.
