"""Code Scaffolder tool — generates main.py and Dockerfile for each agent.

Generated main.py follows the researcher/main.py pattern:
- Strands Agent + BedrockModel + system prompt from description
- Gateway refs references when MCP tools specified
- Peer tool awareness comments for orchestrator/worker/peer roles

Generated Dockerfile follows docs/templates/agent/Dockerfile pattern:
- ARG BASE_IMAGE_URI
- COPY main.py to /app/agent/main.py
- COPY agent-card.yaml to /app/agent-card.yaml
- ENV AGENT_MODULE=agent.main
"""

from strands import tool

# ---------------------------------------------------------------------------
# Dockerfile template — matches docs/templates/agent/Dockerfile
# ---------------------------------------------------------------------------

_DOCKERFILE_TEMPLATE = (
    "ARG BASE_IMAGE_URI=eap-base-strands:latest\n"
    "FROM ${BASE_IMAGE_URI}\n"
    "\n"
    "COPY main.py /app/agent/main.py\n"
    "COPY agent-card.yaml /app/agent-card.yaml\n"
    "\n"
    "ENV AGENT_MODULE=agent.main\n"
)

# ---------------------------------------------------------------------------
# Role-specific comments injected into generated main.py
# ---------------------------------------------------------------------------

_ROLE_COMMENTS: dict[str, str] = {
    "orchestrator": (
        "# Role: orchestrator\n"
        "# This agent delegates subtasks to worker agents.\n"
        "# The platform base image auto-injects call_<worker> tools from the\n"
        "# 'calls' list in agent.yaml. No manual peer-calling code needed.\n"
    ),
    "worker": (
        "# Role: worker\n"
        "# This agent is called by a supervisor/orchestrator.\n"
        "# The platform base image auto-injects peer awareness from the\n"
        "# 'called_by' list in agent.yaml.\n"
    ),
    "peer": (
        "# Role: peer\n"
        "# This agent collaborates with other peers in a swarm.\n"
        "# The platform base image auto-injects call_<peer> tools from the\n"
        "# 'can_call' list in agent.yaml. No manual peer-calling code needed.\n"
    ),
}


# ---------------------------------------------------------------------------
# main.py generation
# ---------------------------------------------------------------------------

def _build_system_prompt(agent_description: str, role: str, calls: list[str]) -> str:
    """Build a system prompt string from the agent description and role context."""
    prompt = agent_description

    # Add delegation instructions for orchestrator roles
    if role == "orchestrator" and calls:
        call_tools = ", ".join(f"call_{name}" for name in calls)
        prompt += (
            f"\n\nYou coordinate work by delegating to your workers using "
            f"these tools: {call_tools}. "
            "Always delegate subtasks to the appropriate worker rather than "
            "attempting to do everything yourself."
        )

    # Add peer collaboration instructions for swarm peers
    if role == "peer" and calls:
        call_tools = ", ".join(f"call_{name}" for name in calls)
        prompt += (
            f"\n\nYou collaborate with peers using these tools: {call_tools}. "
            "Hand off work to the appropriate peer when their expertise is needed."
        )

    return prompt


def _generate_main_py(
    agent_name: str,
    agent_description: str,
    model_id: str,
    gateway_refs: list[dict],
    role: str,
    calls: list[str],
) -> str:
    """Generate main.py content following the researcher/main.py pattern."""
    lines: list[str] = []

    # Module docstring
    lines.append(f'"""Agent: {agent_name}')
    lines.append("")
    lines.append(f"{agent_description}")
    lines.append('"""')

    # Role-specific comment block
    role_comment = _ROLE_COMMENTS.get(role, "")
    if role_comment:
        lines.append(role_comment.rstrip())

    # Imports
    lines.append("import os")
    lines.append("from strands import Agent")
    lines.append("from strands.models.bedrock import BedrockModel")

    # Gateway refs — add comment about MCP tools available via gateway
    if gateway_refs:
        mcp_servers: list[str] = []
        for ref in gateway_refs:
            servers = ref.get("mcp_servers", [])
            mcp_servers.extend(servers)
        if mcp_servers:
            lines.append("")
            lines.append("# MCP tools available via AgentCore Gateway:")
            for server in mcp_servers:
                lines.append(f"#   - {server}")
            lines.append("# These are auto-injected by the platform base image from gateway_refs in agent.yaml.")

    # Model configuration
    lines.append("")
    lines.append("model = BedrockModel(")
    lines.append(f'    model_id=os.environ.get("MODEL_ID", "{model_id}"),')
    lines.append(")")

    # System prompt
    system_prompt = _build_system_prompt(agent_description, role, calls)

    lines.append("")
    lines.append("agent = Agent(")
    lines.append("    model=model,")
    lines.append("    system_prompt=(")

    # Split system prompt into lines for readability
    prompt_lines = system_prompt.split("\n")
    for i, pline in enumerate(prompt_lines):
        escaped = pline.replace("\\", "\\\\").replace('"', '\\"')
        if i < len(prompt_lines) - 1:
            lines.append(f'        "{escaped}\\n"')
        else:
            lines.append(f'        "{escaped}"')

    lines.append("    ),")
    lines.append(")")
    lines.append("")

    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Main tool
# ---------------------------------------------------------------------------

@tool
def code_scaffolder(
    agent_name: str,
    agent_description: str,
    model_id: str,
    gateway_refs: list[dict],
    role: str,
    calls: list[str],
) -> dict:
    """Generate main.py and Dockerfile for an agent.

    Args:
        agent_name: Kebab-case agent name (e.g., "my-support-agent").
        agent_description: Plain-language description of what the agent does. Used as the system prompt.
        model_id: Bedrock model ID (e.g., "us.anthropic.claude-sonnet-5").
        gateway_refs: List of gateway reference dicts, each with "mcp_servers" key listing MCP server names.
        role: Agent role — one of: standalone, orchestrator, worker, peer, classifier, handler.
        calls: List of agent names this agent calls (for orchestrator/peer roles).

    Returns:
        Dict with "main_py" (complete main.py content) and "dockerfile" (complete Dockerfile content).
    """
    main_py = _generate_main_py(
        agent_name=agent_name,
        agent_description=agent_description,
        model_id=model_id,
        gateway_refs=gateway_refs or [],
        role=role or "standalone",
        calls=calls or [],
    )

    dockerfile = _DOCKERFILE_TEMPLATE

    return {
        "main_py": main_py,
        "dockerfile": dockerfile,
    }
