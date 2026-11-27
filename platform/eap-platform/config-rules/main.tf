# AWS Config Rules — Resource Compliance (R18.1–R18.6)
#
# Planned rules:
# - runtime-has-observability: Every runtime deployment includes observability config
# - runtime-has-identity: Every runtime deployment includes identity provider ref
# - ecr-scan-enabled: ECR repos have scan-on-push via Amazon Inspector
# - ecr-lifecycle-policy: ECR repos have lifecycle policies configured
# - resource-tagging: All AgentCore resources have required tags (domain, team, environment, cost-center)
# - code-interpreter-domain: Code interpreter usage restricted to authorized Domains
# - browser-domain: Browser usage restricted to authorized Domains
# - gateway-access-scope: Gateway MCP server access scoped to authorized Domains
# - runtime-protocol-compliance: Declared protocols match actual endpoint availability
#
# Auto-remediation via SSM Automation for ECR rules.
# Implementation in later tasks (Task 10).
