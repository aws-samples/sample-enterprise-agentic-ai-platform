# Enricher Agent — Step 2 of orchestrated flow
# Enriches extracted facts with context and classification.

ARG BASE_IMAGE_URI=eap-base-strands:latest
FROM ${BASE_IMAGE_URI}

COPY main.py /app/agent/main.py
COPY agent-card.yaml /app/agent-card.yaml

ENV AGENT_MODULE=agent.main
