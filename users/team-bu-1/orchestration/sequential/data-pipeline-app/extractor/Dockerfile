# Extractor Agent — Step 1 of orchestrated flow
# Extracts structured facts from raw text.

ARG BASE_IMAGE_URI=eap-base-strands:latest
FROM ${BASE_IMAGE_URI}

COPY main.py /app/agent/main.py
COPY agent-card.yaml /app/agent-card.yaml

ENV AGENT_MODULE=agent.main
