# Terraform-snapshot test — runtime third-party observability injection (task 11.2)
#
# Asserts the runtime module's rendered plan correctly wires the ADDITIVE
# third-party telemetry leg (agentcore-observability) into the AgentCore agent
# runtime's `environment_variables`, and — critically — that this feature's
# third-party wiring NEVER sets or overrides OTEL_EXPORTER_OTLP_ENDPOINT (the
# AWS-native leg stays exactly as AgentCore auto-configures it).
#
#   - collector_endpoint set        => EAP_OTEL_COLLECTOR_ENDPOINT set   (R9.2, R12.4, R17.2, R17.3)
#   - collector_auth_secret_arn set => EAP_OTEL_COLLECTOR_HEADERS set    (R17.3, secret ARN by reference)
#   - third-party wiring            => OTEL_EXPORTER_OTLP_ENDPOINT NOT set      (R17.5 — two-leg invariant)
#
# REQUIRES: Terraform >= 1.6 (the `.tftest.hcl` / `run` test format). The repo's
# currently-pinned Terraform 1.5.x uses the legacy experimental test framework
# and will report "No tests defined" for this file — run it with Terraform 1.6+.
# All assertions are on plan-known, offline-computable values (env vars derived
# purely from inputs), so no AWS-returned data is required, though the provider
# still needs a region (set AWS_REGION=us-east-1) to resolve `data.aws_region`.
#
# Requirements: R17.2, R17.3, R17.5

variables {
  name       = "obs_test_agent"
  domain     = "team-bu-1"
  framework  = "strands"
  role_arn   = "arn:aws:iam::111122223333:role/obs-test-runtime-role"
  # A container image so the runtime artifact block renders during plan.
  container_image = "111122223333.dkr.ecr.us-east-1.amazonaws.com/obs-test:latest"
}

# ---------------------------------------------------------------------------
# Third-party leg wired: collector endpoint + per-BU credential secret ref set,
# otel_endpoint left at its default ("") — the day-one third-party posture.
# ---------------------------------------------------------------------------
run "thirdparty_wiring_sets_collector_env_and_never_sets_otel_exporter" {
  command = plan

  variables {
    observability_config = {
      collector_endpoint        = "http://otel-collector.eap.internal:4318/v1/traces"
      collector_auth_secret_arn = "arn:aws:secretsmanager:us-east-1:111122223333:secret:eap/otel/team-bu-1-AbCdEf"
    }
  }

  # EAP_OTEL_COLLECTOR_ENDPOINT is injected with exactly the configured endpoint.
  assert {
    condition = (
      contains(keys(aws_bedrockagentcore_agent_runtime.this.environment_variables), "EAP_OTEL_COLLECTOR_ENDPOINT")
      && aws_bedrockagentcore_agent_runtime.this.environment_variables["EAP_OTEL_COLLECTOR_ENDPOINT"] == "http://otel-collector.eap.internal:4318/v1/traces"
    )
    error_message = "Expected EAP_OTEL_COLLECTOR_ENDPOINT to equal the configured collector_endpoint."
  }

  # The per-BU third-party credential is injected by reference (secret ARN) as
  # EAP_OTEL_COLLECTOR_HEADERS (AgentCore runtime has no secret valueFrom).
  assert {
    condition = (
      contains(keys(aws_bedrockagentcore_agent_runtime.this.environment_variables), "EAP_OTEL_COLLECTOR_HEADERS")
      && aws_bedrockagentcore_agent_runtime.this.environment_variables["EAP_OTEL_COLLECTOR_HEADERS"] == "arn:aws:secretsmanager:us-east-1:111122223333:secret:eap/otel/team-bu-1-AbCdEf"
    )
    error_message = "Expected EAP_OTEL_COLLECTOR_HEADERS to carry the per-BU auth secret ARN by reference."
  }

  # CRITICAL two-leg invariant: this feature's third-party wiring MUST NOT set
  # OTEL_EXPORTER_OTLP_ENDPOINT — AgentCore's AWS-native export stays intact.
  assert {
    condition     = !contains(keys(aws_bedrockagentcore_agent_runtime.this.environment_variables), "OTEL_EXPORTER_OTLP_ENDPOINT")
    error_message = "Third-party wiring must NOT set OTEL_EXPORTER_OTLP_ENDPOINT (AWS-native leg must remain AgentCore-auto-configured)."
  }
}

# ---------------------------------------------------------------------------
# Default posture: no collector configured => no third-party env vars injected,
# and still no OTEL_EXPORTER_OTLP_ENDPOINT override.
# ---------------------------------------------------------------------------
run "default_posture_injects_no_thirdparty_and_no_otel_exporter_override" {
  command = plan

  assert {
    condition     = !contains(keys(aws_bedrockagentcore_agent_runtime.this.environment_variables), "EAP_OTEL_COLLECTOR_ENDPOINT")
    error_message = "With no collector_endpoint, EAP_OTEL_COLLECTOR_ENDPOINT must not be injected."
  }

  assert {
    condition     = !contains(keys(aws_bedrockagentcore_agent_runtime.this.environment_variables), "EAP_OTEL_COLLECTOR_HEADERS")
    error_message = "With no collector_auth_secret_arn, EAP_OTEL_COLLECTOR_HEADERS must not be injected."
  }

  # Default observability_config leaves otel_endpoint = "" => not injected,
  # so AgentCore's auto-configured AWS-native endpoint is never shadowed.
  assert {
    condition     = !contains(keys(aws_bedrockagentcore_agent_runtime.this.environment_variables), "OTEL_EXPORTER_OTLP_ENDPOINT")
    error_message = "Default posture must not inject OTEL_EXPORTER_OTLP_ENDPOINT."
  }
}

# ---------------------------------------------------------------------------
# Backward-compat: an explicit non-empty otel_endpoint is still honored (opt-in),
# independent of the third-party collector wiring.
# ---------------------------------------------------------------------------
run "explicit_otel_endpoint_still_honored_independently" {
  command = plan

  variables {
    observability_config = {
      otel_endpoint      = "http://legacy-otel.example.internal:4318"
      collector_endpoint = "http://otel-collector.eap.internal:4318/v1/traces"
    }
  }

  assert {
    condition     = aws_bedrockagentcore_agent_runtime.this.environment_variables["OTEL_EXPORTER_OTLP_ENDPOINT"] == "http://legacy-otel.example.internal:4318"
    error_message = "An explicit otel_endpoint should still be injected when supplied."
  }

  # The third-party collector endpoint is a SEPARATE var, never routed through OTEL_EXPORTER_OTLP_ENDPOINT.
  assert {
    condition = (
      aws_bedrockagentcore_agent_runtime.this.environment_variables["EAP_OTEL_COLLECTOR_ENDPOINT"] == "http://otel-collector.eap.internal:4318/v1/traces"
      && aws_bedrockagentcore_agent_runtime.this.environment_variables["OTEL_EXPORTER_OTLP_ENDPOINT"] != aws_bedrockagentcore_agent_runtime.this.environment_variables["EAP_OTEL_COLLECTOR_ENDPOINT"]
    )
    error_message = "Collector endpoint must be carried only by EAP_OTEL_COLLECTOR_ENDPOINT, never routed through OTEL_EXPORTER_OTLP_ENDPOINT."
  }
}
