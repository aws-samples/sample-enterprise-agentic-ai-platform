"""Hypothesis strategies for generating valid and invalid agent.yaml data."""

from hypothesis import strategies as st

# --- Atomic strategies ---
domains = st.from_regex(r"[a-z][a-z0-9-]{1,10}[a-z0-9]", fullmatch=True)
frameworks = st.sampled_from(["strands", "langgraph", "crewai", "custom"])
model_ids = st.just("anthropic.claude-sonnet-5")
protocols = st.lists(
    st.sampled_from(["a2a", "mcp", "agui", "http"]),
    min_size=1,
    max_size=4,
    unique=True,
)
roles = st.sampled_from(["orchestrator", "specialist", "worker", "router"])
memory_types = st.sampled_from(["short-term", "long-term", "episodic"])
retentions = st.from_regex(r"[1-9][0-9]{0,2}d", fullmatch=True)
evaluator_names = st.sampled_from(["correctness", "helpfulness", "safety", "goal_success_rate"])
agent_names = st.from_regex(r"[a-z][a-z0-9_]{1,12}", fullmatch=True)
module_versions = st.from_regex(r"v[0-9]\.[0-9]\.[0-9]", fullmatch=True)


# --- Composite strategies ---
@st.composite
def memory_configs(draw):
    return {
        "type": draw(memory_types),
        "retention": draw(retentions),
    }


@st.composite
def evaluations_configs(draw):
    evs = draw(st.lists(evaluator_names, min_size=1, max_size=4, unique=True))
    thresholds = {}
    for ev in evs:
        if draw(st.booleans()):
            thresholds[ev] = round(draw(st.floats(min_value=0.0, max_value=1.0)), 2)
    result = {"evaluators": evs}
    if thresholds:
        result["thresholds"] = thresholds
    return result


@st.composite
def agent_blocks(draw, available_names=None):
    """Generate a single agent block. If available_names given, refs are drawn from it."""
    block = {"protocols": draw(protocols)}
    if draw(st.booleans()):
        block["role"] = draw(roles)
    if draw(st.booleans()):
        block["memory"] = draw(memory_configs())
    if draw(st.booleans()):
        block["evaluations"] = draw(evaluations_configs())
    if draw(st.booleans()):
        block["code_interpreter"] = {"enabled": True}
    if draw(st.booleans()):
        block["browser"] = {"enabled": True}
    return block


@st.composite
def valid_yaml_data(draw, min_agents=1, max_agents=4):
    """Generate a complete valid agent.yaml dict."""
    n = draw(st.integers(min_value=min_agents, max_value=max_agents))
    names = draw(
        st.lists(agent_names, min_size=n, max_size=n, unique=True)
    )

    agents = {}
    for name in names:
        block = draw(agent_blocks())
        agents[name] = block

    # Wire up some A2A relationships (valid refs only)
    name_list = list(agents.keys())
    for name in name_list:
        other_names = [n for n in name_list if n != name]
        if other_names and draw(st.booleans()):
            calls = draw(st.lists(st.sampled_from(other_names), min_size=1, max_size=min(2, len(other_names)), unique=True))
            agents[name]["calls"] = calls
            # Wire allowed_callers on callees
            for callee in calls:
                existing = agents[callee].get("allowed_callers", [])
                if name not in existing:
                    existing.append(name)
                agents[callee]["allowed_callers"] = existing

    data = {
        "domain": draw(domains),
        "framework": draw(frameworks),
        "model_id": draw(model_ids),
        "agents": agents,
    }
    if draw(st.booleans()):
        data["module_version"] = draw(module_versions)
    return data


@st.composite
def invalid_yaml_data(draw):
    """Generate an agent.yaml dict that violates the schema."""
    violation = draw(st.sampled_from([
        "missing_domain",
        "bad_framework",
        "empty_agents",
        "bad_protocol",
        "bad_memory_type",
    ]))

    base = draw(valid_yaml_data(min_agents=1, max_agents=2))

    if violation == "missing_domain":
        del base["domain"]
    elif violation == "bad_framework":
        base["framework"] = "invalid_framework"
    elif violation == "empty_agents":
        base["agents"] = {}
    elif violation == "bad_protocol":
        first_agent = next(iter(base["agents"].values()))
        first_agent["protocols"] = ["invalid_proto"]
    elif violation == "bad_memory_type":
        first_agent = next(iter(base["agents"].values()))
        first_agent["memory"] = {"type": "invalid_type"}

    return base
