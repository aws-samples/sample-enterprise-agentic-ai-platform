# ADR-013: Amazon ECR for Agent Container Images

**Status:** Accepted
**Date:** 2026-03-13

**Context:** AgentCore Runtime supports deploying agents as OCI-compliant container images or code packages (zip archives). For the container path, need a container registry. Options considered: Amazon ECR, self-hosted (Harbor), third-party (Docker Hub, GitHub Container Registry).

**Decision:** Use Amazon ECR as the container registry. ECR repositories provisioned per App_Team or per Domain by Platform_Admin via the `eap-platform` repo.

**Architecture:**

```
App_Team builds agent container
    → CodePipeline build stage pushes to team's ECR repo
    → Runtime module references ECR image URI
    → CodePipeline apply stage deploys to AgentCore Runtime
    → AgentCore Runtime pulls image from ECR at deployment time
```

**ECR repository structure:**
- `{account-id}.dkr.ecr.{region}.amazonaws.com/eap/{domain}/{team}/{agent-name}`
- Platform_Admin provisions ECR repos and lifecycle policies
- App_Team has push access; AgentCore Runtime has pull access
- Image scanning on push via Amazon Inspector
- Lifecycle policies for image retention (configurable per domain)

**Rationale:**
- AWS-native — no additional infrastructure, aligns with "keep it close to AWS" principle
- IAM-native access control — push/pull permissions scoped via IAM policies, integrates with Domain isolation model
- Image scanning via Amazon Inspector — findings flow to Security Hub alongside other compliance findings
- Cross-account pull support — shared base images in central platform account pullable by domain accounts
- ECR lifecycle policies handle image retention automatically

**Consequences:**
- Platform_Admin provisions ECR repos as part of domain/team onboarding (in `eap-platform` repo)
- CodePipeline for App_Teams includes container build stage before Terraform plan stage
- AWS Config Rules enforce image scanning and lifecycle policy compliance on all ECR repos
- Runtime module accepts ECR image URI as input variable for container-based deployments
