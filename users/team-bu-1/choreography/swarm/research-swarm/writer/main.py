"""Writer Agent — synthesizes findings into coherent responses.

Swarm peer. The platform auto-injects call_researcher and call_analyst tools.
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
        "You are a writer agent in a collaborative swarm. "
        "Your job is to synthesize research findings and analysis into coherent, "
        "well-structured responses. You can hand off to the researcher for more data "
        "or the analyst for deeper analysis. "
        "Use the call_researcher or call_analyst tools when you need their expertise."
    ),
)
