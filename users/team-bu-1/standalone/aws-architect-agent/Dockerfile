ARG BASE_IMAGE_URI=eap-base-strands:latest
FROM ${BASE_IMAGE_URI}

COPY main.py /app/agent/main.py
COPY prompts.py /app/agent/prompts.py
COPY file_writer.py /app/agent/file_writer.py
COPY agent-card.yaml /app/agent-card.yaml

ENV AGENT_MODULE=agent.main
