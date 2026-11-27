# Dockerfile — Platform-Compliant Agent Container
# Owner: App Team
#
# Uses the platform base image which includes:
#   - Protocol handlers (A2A, MCP, AGUI, HTTP)
#   - OTel auto-instrumentation
#   - Credential helper
#   - Structured logging
#   - Non-root security
#
# App teams only add their agent code on top.

ARG BASE_IMAGE_URI=eap-base-strands:latest
FROM ${BASE_IMAGE_URI}

# Copy agent code
COPY main.py /app/agent/main.py
COPY agent-card.yaml /app/agent-card.yaml

# Set the agent module entrypoint
ENV AGENT_MODULE=agent.main
