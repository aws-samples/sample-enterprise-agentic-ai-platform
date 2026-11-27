"""A2A relationship resolver — adjacency graph, cycle detection, topological sort.

Requirements: R24.1–R24.6, R28.2–R28.3, R29.4
"""

from __future__ import annotations

from collections import defaultdict, deque
from dataclasses import dataclass, field


@dataclass
class ResolvedAgent:
    """An agent with resolved A2A wiring references."""

    name: str
    config: dict
    cognito_client_ref: str
    allowed_client_refs: list[str] = field(default_factory=list)
    callee_endpoint_refs: dict[str, str] = field(default_factory=dict)
    deploy_order: int = 0


@dataclass
class ResolutionResult:
    """Result of A2A relationship resolution."""

    agents: list[ResolvedAgent]
    warnings: list[str] = field(default_factory=list)


def resolve(yaml_data: dict) -> ResolutionResult:
    """Resolve A2A relationships, compute dependency order, generate HCL references."""
    agents_map = yaml_data.get("agents", {})
    domain = yaml_data.get("domain", "")
    warnings: list[str] = []

    # Build adjacency graph: caller -> [callees]
    graph: dict[str, list[str]] = defaultdict(list)
    reverse_graph: dict[str, list[str]] = defaultdict(list)
    all_names = list(agents_map.keys())

    for name, block in agents_map.items():
        for callee in block.get("calls", []):
            graph[name].append(callee)
            reverse_graph[callee].append(name)

    # Detect cycles (warn, don't fail — bidirectional A2A is valid)
    cycles = _find_cycles(graph, all_names)
    for cycle in cycles:
        path = " -> ".join(cycle)
        warnings.append(f"Cyclic A2A relationship detected: {path}")

    # Check asymmetric relationships
    for name, block in agents_map.items():
        for callee in block.get("calls", []):
            callee_block = agents_map.get(callee, {})
            allowed = callee_block.get("allowed_callers")
            # Asymmetric if callee has allowed_callers defined (even empty) and caller not in it,
            # OR if callee has no allowed_callers at all (implicit deny)
            if allowed is None or name not in (allowed or []):
                warnings.append(
                    f"Agent '{name}' calls '{callee}' but '{callee}' does not list '{name}' in allowed_callers"
                )

    # Topological sort (Kahn's algorithm) — callees before callers
    order = _topological_sort(graph, all_names)

    # Build resolved agents
    resolved: list[ResolvedAgent] = []
    for idx, name in enumerate(order):
        block = agents_map[name]
        client_ref = f"aws_cognito_user_pool_client.{name}.id"

        # Collect allowed caller client refs
        allowed_client_refs: list[str] = []
        for caller_name in block.get("allowed_callers", []):
            allowed_client_refs.append(f"aws_cognito_user_pool_client.{caller_name}.id")

        # Collect callee endpoint refs (for env var injection)
        callee_refs: dict[str, str] = {}
        for callee_name in block.get("calls", []):
            env_key = f"{callee_name.upper()}_A2A_ENDPOINT"
            callee_refs[env_key] = f"module.runtime_{callee_name}.endpoint_arn"

        resolved.append(
            ResolvedAgent(
                name=name,
                config=block,
                cognito_client_ref=client_ref,
                allowed_client_refs=allowed_client_refs,
                callee_endpoint_refs=callee_refs,
                deploy_order=idx,
            )
        )

    return ResolutionResult(agents=resolved, warnings=warnings)


def _find_cycles(graph: dict[str, list[str]], all_names: list[str]) -> list[list[str]]:
    """Find all cycles in the directed graph using DFS."""
    cycles: list[list[str]] = []
    visited: set[str] = set()
    rec_stack: set[str] = set()
    path: list[str] = []

    def dfs(node: str) -> None:
        visited.add(node)
        rec_stack.add(node)
        path.append(node)

        for neighbor in graph.get(node, []):
            if neighbor not in visited:
                dfs(neighbor)
            elif neighbor in rec_stack:
                # Found a cycle — extract it
                cycle_start = path.index(neighbor)
                cycle = path[cycle_start:] + [neighbor]
                cycles.append(cycle)

        path.pop()
        rec_stack.discard(node)

    for name in all_names:
        if name not in visited:
            dfs(name)

    return cycles


def _topological_sort(graph: dict[str, list[str]], all_names: list[str]) -> list[str]:
    """Topological sort using Kahn's algorithm. Callees come before callers.

    If cycles exist, remaining nodes are appended in original order.
    """
    in_degree: dict[str, int] = {n: 0 for n in all_names}
    for node in all_names:
        for neighbor in graph.get(node, []):
            if neighbor in in_degree:
                in_degree[neighbor] = in_degree.get(neighbor, 0)

    # In our graph, edges go caller -> callee.
    # We want callees first, so we reverse: callee depends on nothing,
    # caller depends on callee. Build reverse in-degree.
    rev_in_degree: dict[str, int] = {n: 0 for n in all_names}
    for caller in all_names:
        for callee in graph.get(caller, []):
            if callee in rev_in_degree:
                rev_in_degree[caller] = rev_in_degree.get(caller, 0) + 1

    queue: deque[str] = deque()
    for n in all_names:
        if rev_in_degree[n] == 0:
            queue.append(n)

    result: list[str] = []
    while queue:
        node = queue.popleft()
        result.append(node)
        # node is a callee — callers that depend on it get their in-degree reduced
        for caller in all_names:
            if node in graph.get(caller, []):
                rev_in_degree[caller] -= 1
                if rev_in_degree[caller] == 0:
                    queue.append(caller)

    # Append any remaining nodes (cycles) in original order
    remaining = [n for n in all_names if n not in result]
    result.extend(remaining)

    return result
