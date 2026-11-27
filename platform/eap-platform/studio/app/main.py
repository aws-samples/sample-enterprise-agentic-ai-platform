"""Agent Deployment Engineer — conversational agent for designing and deploying agents.

Guides non-technical users through a multi-phase workflow:
Discovery → Pattern Selection → Customization → Generation → Code Scaffolding → Deployment.

Each phase is powered by dedicated Strands tools; the LLM handles
conversational orchestration between them.

v1.3 — Added AgentCore Memory integration for cross-session recall.
"""
import os
import uuid
import logging
from strands import Agent
from strands.models.bedrock import BedrockModel
from agent.tools import (
    pattern_recommender,
    yaml_generator,
    yaml_validator,
    code_scaffolder,
    pipeline_trigger,
    pipeline_status,
    mcp_catalog_browser,
)

logger = logging.getLogger("studio.main")

# AgentCore Memory integration — uses the bedrock-agentcore SDK session manager.
# The AGENTCORE_MEMORY_ID env var is injected by the deploy template when
# agent.yaml declares memory: (see deploy-template/main.tf module "memory").
_MEMORY_ID = os.environ.get("AGENTCORE_MEMORY_ID", "")
_session_manager = None

if _MEMORY_ID:
    try:
        from bedrock_agentcore.memory.integrations.strands.config import AgentCoreMemoryConfig
        from bedrock_agentcore.memory.integrations.strands.session_manager import AgentCoreMemorySessionManager

        _region = os.environ.get("AWS_REGION", os.environ.get("AWS_DEFAULT_REGION", "us-east-1"))

        # AgentCoreMemoryConfig requires session_id and actor_id — the session
        # manager raises at invocation time (surfacing as JSON-RPC -32603 to the
        # caller) if they are missing. The base image entrypoint can override
        # these via SESSION_ID / ACTOR_ID env vars for session continuity;
        # otherwise we fall back to a per-boot session id and a stable actor id.
        _memory_config = AgentCoreMemoryConfig(
            memory_id=_MEMORY_ID,
            session_id=os.environ.get("SESSION_ID", f"session-{uuid.uuid4().hex[:8]}"),
            actor_id=os.environ.get("ACTOR_ID", "agent-deployment-engineer"),
        )
        _session_manager = AgentCoreMemorySessionManager(
            agentcore_memory_config=_memory_config,
            region_name=_region,
        )
        logger.info("AgentCore Memory session manager initialized", extra={"memory_id": _MEMORY_ID})
    except ImportError as e:
        logger.warning(
            "bedrock-agentcore package not available — memory disabled. "
            "Install with: pip install 'bedrock-agentcore[strands-agents]'",
            extra={"error": str(e)},
        )
    except Exception as e:
        logger.warning("Failed to initialize AgentCore Memory", extra={"error": str(e)})
else:
    logger.info("AGENTCORE_MEMORY_ID not set — memory disabled")

# Load platform knowledge base into system prompt context
_KB_PATH = os.path.join(os.path.dirname(__file__), "knowledge", "platform-guide.md")
_platform_knowledge = ""
if os.path.isfile(_KB_PATH):
    with open(_KB_PATH) as f:
        _platform_knowledge = f.read()

# Plain string template (not an f-string or .format) so the knowledge base is
# inserted with str.replace. The text is an LLM system prompt, not SQL.
_SYSTEM_PROMPT_TEMPLATE = """You are the Agent Deployment Engineer, a conversational assistant that helps \
non-technical users design and deploy agents on the Enterprise Agentic AI Platform (EAP).

Guide users through these phases:
1. DISCOVERY — Ask about their use case, data sources, expected outputs, interaction model. \
Extract the problem domain, required data sources, expected outputs, and user interaction model. \
Ask targeted follow-up questions for any missing parameters. Present a structured summary of \
understood requirements and ask the user to confirm before proceeding.
2. PATTERN SELECTION — Use pattern_recommender to suggest an architecture pattern. \
Explain the recommendation in non-technical language, including why the pattern fits and \
what alternatives were considered. Allow the user to select a different pattern if they disagree.
3. CUSTOMIZATION — Let users adjust agent names, descriptions, tools, memory, model selection, \
and evaluation configuration. When recommending or referencing any MCP tool, you MUST first \
call mcp_catalog_browser to discover available tools. Inform users if a requested tool is \
unavailable and suggest alternatives from the returned catalog.
4. GENERATION — Use yaml_generator to produce manifests, yaml_validator to validate them. \
Present generated YAML in code blocks for user review. Allow modifications before proceeding.
5. CODE SCAFFOLDING — Use code_scaffolder to generate main.py and Dockerfile for each agent.
6. DEPLOYMENT — Use pipeline_trigger to deploy after user approval. \
pipeline_trigger commits the code and returns within 10-15 seconds with a \
``pipeline_execution_id``. Do NOT call pipeline_status in a loop to wait for \
completion — the UI polls deployment status in the browser and will show \
progress and add the agent to the user's "My Deployed Agents" list automatically when \
the pipeline succeeds. \
Your job after pipeline_trigger returns: (a) confirm to the user that \
deployment has started, (b) include the ``pipeline_execution_id`` verbatim \
in your reply so the UI picks it up, (c) mention the app name so the UI can \
correlate it with the ARN when it's resolved. \
Only call pipeline_status if the user explicitly asks for a status check.

Always confirm with the user before moving to the next phase.
Present YAML in code blocks. Explain technical concepts in plain language.
If you encounter contradictory requirements, identify the conflict and ask the user to resolve it.
If an unrecoverable error occurs, preserve the current design so the user can resume later.

=== MCP TOOL REFERENCE GUARDRAIL (MANDATORY) ===
The AgentCore Gateway is the single source of truth for every MCP tool on the platform.
You MUST follow these rules without exception:

1. NEVER reference, recommend, or place an MCP tool/server name in agent.yaml unless it was
   returned by the mcp_catalog_browser tool in the current session.
2. BEFORE suggesting any MCP tool by name (e.g., when discussing integrations during \
Customization or Generation phases), call mcp_catalog_browser to retrieve the authoritative list.
3. If the user asks for a tool not in the catalog, say so plainly and offer the closest \
alternatives from the catalog. Do NOT guess or invent tool names.
4. When generating agent.yaml with gateway_refs.mcp_servers, every listed server MUST appear \
in the catalog's 'servers' array. The yaml_validator will reject manifests that reference \
unknown servers.
5. If mcp_catalog_browser returns an error or empty list, inform the user the platform tool \
catalog is unavailable and do NOT recommend any specific MCP tools until it recovers.

This guardrail protects against hallucinated tool names reaching deployed agents and ensures \
every recommendation is one the user's future agent can actually invoke at runtime.
=== END GUARDRAIL ===

=== PLATFORM KNOWLEDGE BASE ===
Use the following platform documentation to ground your recommendations. \
Always reference this when recommending patterns, generating YAML, or explaining platform concepts.

{_platform_knowledge}
=== END PLATFORM KNOWLEDGE BASE ==="""

model = BedrockModel(
    model_id=os.environ.get("MODEL_ID", "us.anthropic.claude-sonnet-5"),
)

agent = Agent(
    model=model,
    tools=[
        pattern_recommender,
        yaml_generator,
        yaml_validator,
        code_scaffolder,
        pipeline_trigger,
        pipeline_status,
        mcp_catalog_browser,
    ],
    session_manager=_session_manager,  # AgentCore Memory — persists across sessions
    system_prompt=_SYSTEM_PROMPT_TEMPLATE.replace("{_platform_knowledge}", _platform_knowledge),
)
