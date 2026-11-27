# EAP Base Image — Strands Framework
# ARM64 base with modular protocol layers, AWS-native observability (ADOT), credential helper, structured logging
# MVP focus: A2A protocol layer (port 9000)
# Requirements: R20.9, R20.10, R20.11, R19.9, R19.10, R19.11, R15.14

# Upstream base image. Defaults to the official python:3.12-slim image on Amazon
# ECR Public (the Docker Official Images mirror), so no Docker Hub pull is needed;
# override with `--build-arg BASE_IMAGE=<your-approved-image>` to build on your
# organization-approved (golden) base — e.g. from an internal registry — for a
# locked-down / no-egress account. No public image is then pulled at build time.
ARG BASE_IMAGE=public.ecr.aws/docker/library/python:3.12-slim
FROM --platform=linux/arm64 ${BASE_IMAGE} AS base

# Security baseline: non-root user (Component 6)
RUN groupadd -r appuser && useradd -r -g appuser -d /app -s /sbin/nologin appuser

# OS dependencies: CA certs, curl for health checks
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Component 1: Framework runtime — Strands SDK
COPY requirements-base.txt /app/
RUN pip install --no-cache-dir -r /app/requirements-base.txt

# Component 2: A2A protocol — handled by strands A2AServer (no custom handler needed)

# Component 3: AWS-native AgentCore Observability (ADOT)
# aws-opentelemetry-distro auto-configures export to CloudWatch GenAI Observability
# + X-Ray Transaction Search. On AgentCore Runtime the export pipeline is enabled by
# the runtime automatically; no OTEL_EXPORTER_OTLP_ENDPOINT wiring required.
# For non-runtime hosts, set AGENT_OBSERVABILITY_ENABLED=true, OTEL_PYTHON_DISTRO=aws_distro,
# OTEL_PYTHON_CONFIGURATOR=aws_configurator (see modules/runtime).

# Component 4: Identity credential helper
COPY credential_helper.py /app/

# Component 5: Structured JSON logging
COPY logging_config.py /app/

# Component 7: Entrypoint — reads env var contract, starts protocol listeners
COPY entrypoint.py /app/

# Default env vars (overridden by runtime module at deploy time)
ENV EAP_PROTOCOLS="a2a" \
    LOG_LEVEL="INFO" \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

# Expose A2A port
EXPOSE 9000

# Security: run as non-root
USER appuser

ENTRYPOINT ["opentelemetry-instrument", "python", "/app/entrypoint.py"]
