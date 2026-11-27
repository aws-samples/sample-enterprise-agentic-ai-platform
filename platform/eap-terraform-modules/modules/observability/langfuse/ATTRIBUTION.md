# Attribution — Langfuse_Stack Module

This module's self-hosted Langfuse observability pattern is **derived from** the
AWS-samples **Agentic Value Accelerator (AVA)**.

- **Source:** Agentic Value Accelerator (AVA), AWS-samples
- **URL:** https://github.com/aws-samples/sample-agentic-value-accelerator
- **License:** Apache License, Version 2.0
- **Copyright:** Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.

## License

This derived work is used under the Apache License, Version 2.0 (the "License");
you may not use these files except in compliance with the License. You may obtain
a copy of the License at:

    https://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software distributed
under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
CONDITIONS OF ANY KIND, either express or implied. See the License for the
specific language governing permissions and limitations under the License.

## What is derived

The following aspects of this module are adapted from the AVA self-hosted
Langfuse reference pattern:

- The **self-hosted Langfuse deployment topology** on AWS: ECS Fargate Langfuse
  **web** and **worker** services, **Aurora PostgreSQL Serverless v2** as the
  transactional datastore, **ClickHouse** as the analytical datastore,
  **ElastiCache Redis** as the cache/queue, and an edge of
  **CloudFront → Application Load Balancer (Langfuse_ALB) → web service**.
- The **dual-observability approach** that pairs AWS-native telemetry with an
  **embedded, self-hosted Langfuse** experience for LLM/agent trace, prompt, and
  evaluation views.

## Modifications

This module adapts the pattern to the Enterprise Agentic AI Platform (powered by
Amazon Bedrock AgentCore). Notable platform-specific changes include:

- Integration with the platform's Terraform module conventions
  (`eap_module` / `eap_domain` tags, VPC/subnets as variables).
- Positioning Langfuse strictly as a **third-party OTLP backend** on a leg that
  is structurally independent of the always-on AWS-native leg (AgentCore
  auto-instrumentation → CloudWatch/X-Ray).
- Per-Business-Unit tenant scoping (per-BU Langfuse projects) and Cognito
  single sign-on via the shared platform user pool at the ALB.
- Platform security posture: private-subnet datastores, at-rest/in-transit
  encryption, Secrets Manager-injected credentials, and HTTPS-only edge.
