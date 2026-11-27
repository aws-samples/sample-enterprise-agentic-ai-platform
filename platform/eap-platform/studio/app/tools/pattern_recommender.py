"""Pattern Recommender tool — analyzes requirements and recommends an architecture pattern.

Decision logic:
- Single task, no delegation → standalone (no orchestration)
- Subtask delegation to specialists → supervisor + step-functions
- Linear processing chain → sequential-workflow + step-functions
- Input classification routing → router + step-functions
- Iterative peer collaboration → swarm + a2a
"""

from strands import tool

# Canonical template paths for each pattern
TEMPLATE_REFERENCES = {
    "standalone": "docs/templates/composition/standalone-agent.yaml",
    "supervisor": "docs/templates/composition/supervisor.yaml",
    "sequential-workflow": "docs/templates/composition/application.yaml",
    "router": "docs/templates/composition/application.yaml",
    "swarm": "docs/templates/composition/swarm.yaml",
}

# Pattern metadata used for reasoning and alternatives
PATTERN_INFO = {
    "standalone": {
        "orchestration_mode": "none",
        "description": (
            "A single agent that handles the entire task independently. "
            "Best for focused use cases that don't require breaking work "
            "into subtasks or collaborating with other agents."
        ),
        "pros": "Simple to deploy and maintain; lowest latency; no coordination overhead.",
        "cons": "Limited to what a single agent can handle; no specialization.",
    },
    "supervisor": {
        "orchestration_mode": "step-functions",
        "description": (
            "A supervisor agent delegates subtasks to specialist workers. "
            "The supervisor decides which worker to call and aggregates results."
        ),
        "pros": "Clear delegation hierarchy; specialists can be optimized independently; reliable via Step Functions.",
        "cons": "More complex to configure; supervisor is a single point of coordination.",
    },
    "sequential-workflow": {
        "orchestration_mode": "step-functions",
        "description": (
            "Agents execute in a linear chain where each step's output feeds "
            "the next. Orchestrated by Step Functions for reliability."
        ),
        "pros": "Predictable execution order; easy to reason about data flow; built-in retry/error handling.",
        "cons": "No parallelism; total latency is sum of all steps.",
    },
    "router": {
        "orchestration_mode": "step-functions",
        "description": (
            "A classifier agent routes incoming requests to specialized "
            "handler agents based on input classification."
        ),
        "pros": "Efficient routing to specialists; each handler optimized for its category.",
        "cons": "Requires a reliable classifier; adding new categories means adding new handlers.",
    },
    "swarm": {
        "orchestration_mode": "a2a",
        "description": (
            "Peer agents collaborate iteratively via A2A handoffs with no "
            "central coordinator. Each agent's LLM decides who to call next."
        ),
        "pros": "Emergent collaboration; flexible and adaptive; no single point of control.",
        "cons": "Harder to predict execution flow; potential for loops; higher latency.",
    },
}


def _build_alternatives(recommended: str) -> list[dict]:
    """Build a ranked list of alternative patterns excluding the recommended one."""
    # Priority order for alternatives (most common to least)
    priority = ["standalone", "supervisor", "sequential-workflow", "router", "swarm"]
    alternatives = []
    for pattern in priority:
        if pattern == recommended:
            continue
        info = PATTERN_INFO[pattern]
        alternatives.append(
            {
                "pattern": pattern,
                "orchestration_mode": info["orchestration_mode"],
                "description": info["description"],
                "pros": info["pros"],
                "cons": info["cons"],
            }
        )
    return alternatives


def _build_reasoning(
    recommended: str,
    problem_domain: str,
    requires_delegation: bool,
    requires_sequential_steps: bool,
    requires_routing: bool,
    requires_peer_collaboration: bool,
) -> str:
    """Build a plain-language explanation of why the pattern was recommended."""
    info = PATTERN_INFO[recommended]

    if recommended == "standalone":
        return (
            f"For your {problem_domain} use case, a standalone agent is the best fit. "
            "Your requirements describe a focused task that a single agent can handle "
            "without needing to delegate to other agents or coordinate a multi-step pipeline. "
            f"{info['description']}"
        )
    if recommended == "supervisor":
        return (
            f"For your {problem_domain} use case, a supervisor pattern is recommended "
            "because your requirements involve delegating subtasks to specialized agents. "
            "A supervisor agent will coordinate the work, deciding which specialist to "
            f"invoke and aggregating their results. {info['description']}"
        )
    if recommended == "sequential-workflow":
        return (
            f"For your {problem_domain} use case, a sequential workflow is recommended "
            "because your requirements describe a linear chain of processing steps where "
            f"each step feeds into the next. {info['description']}"
        )
    if recommended == "router":
        return (
            f"For your {problem_domain} use case, a router pattern is recommended "
            "because your requirements involve classifying incoming requests and routing "
            f"them to different specialized handlers. {info['description']}"
        )
    # swarm
    return (
        f"For your {problem_domain} use case, a swarm pattern is recommended "
        "because your requirements involve peer agents collaborating iteratively "
        f"without a central coordinator. {info['description']}"
    )


@tool
def pattern_recommender(
    problem_domain: str,
    data_sources: list[str],
    expected_outputs: str,
    interaction_model: str,
    requires_delegation: bool,
    requires_sequential_steps: bool,
    requires_routing: bool,
    requires_peer_collaboration: bool,
) -> dict:
    """Analyze requirements and recommend an architecture pattern.

    Args:
        problem_domain: The domain or area the agent will operate in (e.g., "customer support", "data processing").
        data_sources: List of data sources the agent needs access to (e.g., ["knowledge base", "database"]).
        expected_outputs: Description of what the agent should produce (e.g., "summarized reports").
        interaction_model: How users will interact with the agent (e.g., "chat", "API", "batch").
        requires_delegation: True if the use case involves delegating subtasks to specialist agents.
        requires_sequential_steps: True if the use case involves a linear chain of processing steps.
        requires_routing: True if the use case involves routing requests to different handlers based on classification.
        requires_peer_collaboration: True if the use case involves peer agents collaborating iteratively.

    Returns:
        Dict with recommended_pattern, orchestration_mode, reasoning, alternatives, and template_reference.
    """
    # Decision logic — evaluate flags in priority order.
    # Peer collaboration (swarm) takes highest priority because it's the most
    # architecturally distinct pattern. Then routing, sequential, delegation.
    # If no multi-agent flag is set, default to standalone.
    if requires_peer_collaboration:
        recommended = "swarm"
    elif requires_routing:
        recommended = "router"
    elif requires_sequential_steps:
        recommended = "sequential-workflow"
    elif requires_delegation:
        recommended = "supervisor"
    else:
        recommended = "standalone"

    info = PATTERN_INFO[recommended]

    return {
        "recommended_pattern": recommended,
        "orchestration_mode": info["orchestration_mode"],
        "reasoning": _build_reasoning(
            recommended,
            problem_domain,
            requires_delegation,
            requires_sequential_steps,
            requires_routing,
            requires_peer_collaboration,
        ),
        "alternatives": _build_alternatives(recommended),
        "template_reference": TEMPLATE_REFERENCES[recommended],
    }
