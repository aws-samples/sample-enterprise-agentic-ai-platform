"""AWS Architect Agent — Standalone agent pattern.

Designs comprehensive, Well-Architected AWS solutions through collaborative
conversation. Generates architecture diagrams, cost analysis, and
Well-Architected Framework assessments.

MCP tools (aws-knowledge) are provided by the AgentCore Gateway — declared
in agent.yaml under gateway_refs. Diagram generation uses the public
awslabs.aws-diagram-mcp-server. Native tool: write_file for deterministic
file output.
"""

import logging
import os
import uuid

from strands import Agent
from strands.models.bedrock import BedrockModel

from agent.prompts import SYSTEM_INSTRUCTIONS
from agent.file_writer import write_file

logger = logging.getLogger("aws-architect-agent")

model = BedrockModel(
    model_id=os.environ.get("MODEL_ID", "us.anthropic.claude-sonnet-5"),
)

# --- AgentCore Memory Integration ---
# AGENTCORE_MEMORY_ID is injected by the deploy-template when agent.yaml declares memory:
memory_id = os.environ.get("AGENTCORE_MEMORY_ID")
session_manager = None

if memory_id:
    try:
        from bedrock_agentcore.memory.integrations.strands.config import AgentCoreMemoryConfig
        from bedrock_agentcore.memory.integrations.strands.session_manager import AgentCoreMemorySessionManager

        region = os.environ.get("AWS_REGION", os.environ.get("AWS_DEFAULT_REGION", "us-east-1"))

        agentcore_memory_config = AgentCoreMemoryConfig(
            memory_id=memory_id,
            session_id=os.environ.get("SESSION_ID", f"session-{uuid.uuid4().hex[:8]}"),
            actor_id=os.environ.get("ACTOR_ID", "aws-architect-agent"),
        )

        session_manager = AgentCoreMemorySessionManager(
            agentcore_memory_config=agentcore_memory_config,
            region_name=region,
        )
        logger.info("AgentCore Memory enabled: memory_id=%s", memory_id)
    except Exception:
        logger.exception("Failed to initialize AgentCore Memory — running without memory")
        session_manager = None
else:
    logger.info("No AGENTCORE_MEMORY_ID set — running without memory")

agent = Agent(
    name="aws-architect-agent",
    description=(
        "GenAI AWS Solutions Architect agent. Designs comprehensive, "
        "Well-Architected AWS solutions through collaborative conversation."
    ),
    model=model,
    system_prompt=SYSTEM_INSTRUCTIONS,
    tools=[write_file],
    session_manager=session_manager,
    callback_handler=None,
)
