"""Researcher Agent — gathers information and identifies sources.

In the swarm pattern, peers communicate via A2A. The platform's base image
auto-injects call_analyst and call_writer tools from can_call env vars.
No peer-calling code needed here.
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
        "You are a research agent in a collaborative swarm. "
        "Your job is to gather initial information on the topic. "
        "You MUST always hand off to the analyst using call_analyst to get deeper analysis, "
        "and then hand off to the writer using call_writer to get a polished final response. "
        "Never provide a final answer yourself — always delegate to your peers. "
        "First call call_analyst with your research findings, then call call_writer with the analysis."
    ),
)
