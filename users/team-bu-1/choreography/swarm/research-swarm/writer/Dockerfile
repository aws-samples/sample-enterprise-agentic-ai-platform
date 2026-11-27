ARG BASE_IMAGE_URI
FROM ${BASE_IMAGE_URI}

COPY agent-card.yaml /app/agent-card.yaml
COPY main.py /app/agent/main.py

ENV AGENT_MODULE=agent.main
