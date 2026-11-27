"""Analyst Agent — analyzes data and critiques findings.

Swarm peer. The platform auto-injects call_researcher and call_writer tools.
"""
import os
from strands import Agent
from strands.models.bedrock import BedrockModel

model = BedrockModel(
    model_id=os.environ.get("MODEL_ID", "us.anthropic.claude-sonnet-5"),
)

agent = Agent(
    model=model,
    system_prompt=(
        "You are an analyst agent in a collaborative swarm. "
        "Your job is to analyze data, identify patterns, and critique research findings. "
        "You can hand off to the researcher for more data or the writer for synthesis. "
        "Use the call_researcher or call_writer tools when you need their expertise."
    ),
)
