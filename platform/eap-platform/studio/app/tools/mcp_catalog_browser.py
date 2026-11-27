"""MCP Catalog Browser — discover available MCP tools from the AgentCore Gateway.

This is the single authoritative source for Studio to learn what MCP tools exist
on the platform. Studio must call this tool before recommending any tool in
`agent.yaml.gateway_refs.mcp_servers`. Never hardcode or hallucinate tool names.

Scoping — see docs/adr/023-studio-mcp-catalog-scoping.md:
  The caller's Cognito JWT is forwarded to the Gateway so the returned catalog
  reflects only what the user is entitled to invoke. If no user token is present
  (e.g., backend invocation), Studio falls back to its own workload identity.

Output structure:
  {
    "servers": [
      {"name": "snowflake-warehouse", "tool_count": 5, "description": "..."}
    ],
    "tools": [
      {
        "name": "snowflake_query",
        "server": "snowflake-warehouse",
        "description": "Run a SQL query against Snowflake",
        "input_schema_summary": "sql: string, database: string"
      }
    ],
    "fetched_at": ISO8601 timestamp,
    "source": "user-scoped" | "workload-identity"
  }

The agent uses this to:
  1. Suggest relevant tools during customization phase
  2. Validate that every tool named in generated YAML exists in the catalog
  3. Inform the user if a requested tool is unavailable and offer alternatives
"""

import json
import logging
import os
import time
import urllib.parse
import urllib.request
from typing import Any

import boto3
from strands import tool

logger = logging.getLogger("studio.mcp_catalog")

# Gateway endpoint — the platform's shared AgentCore Gateway URL, injected by
# the Studio Terraform module at deploy time. No default: each deployment uses
# its own gateway.
GATEWAY_URL = os.environ.get("PLATFORM_GATEWAY_URL", "")

# Cache TTL — how long to hold the catalog before re-fetching from Gateway.
# 10 minutes balances freshness (new MCPs appear quickly) against Gateway load.
CACHE_TTL_SECONDS = 600

# Per-container cache keyed by user-sub-or-"platform". Survives across calls
# within the same agent session/container.
_catalog_cache: dict[str, dict] = {}


def _get_workload_token(user_token: str = "") -> str | None:  # nosec B107 - empty-string default for an optional JWT arg, not a hardcoded password.
    """Exchange the caller's user JWT for a user+agent-scoped workload token.

    AgentCore intentionally forbids a runtime-managed agent identity from
    self-minting a workload token: calling the bare GetWorkloadAccessToken from
    inside a runtime fails with "Workload Identity does not belong to caller
    account". The supported path is GetWorkloadAccessTokenForJWT, which
    exchanges a validated end-user JWT for a token bound to (user, agent). See
    the AgentCore "Get workload access token" guide, Pattern 1.

    Without a user JWT there is no valid self-service path for a runtime-managed
    identity, so we return None and let the catalog degrade gracefully rather
    than emitting a misleading AccessDenied error.
    """
    if not user_token:
        logger.info(
            "No user JWT available; skipping workload-token exchange "
            "(a user-scoped token is required to query the Gateway catalog)"
        )
        return None
    try:
        region = os.environ.get("AWS_REGION", os.environ.get("AWS_DEFAULT_REGION", "us-east-1"))
        client = boto3.client("bedrock-agentcore", region_name=region)
        workload_name = os.environ.get("EAP_AGENT_NAME", "agent-deployment-engineer")
        resp = client.get_workload_access_token_for_jwt(
            workloadName=workload_name,
            userToken=user_token,
        )
        return resp.get("workloadAccessToken")
    except Exception as e:
        logger.warning("Failed to exchange user JWT for workload token", extra={"error": str(e)})
        return None


def _fetch_catalog(auth_token: str) -> dict:
    """Call the Gateway's MCP tools/list JSON-RPC method with the given token."""
    # Only HTTPS: the request carries a bearer token, and urlopen would also
    # accept file:// or custom schemes from a misconfigured env var.
    if not GATEWAY_URL:
        raise ValueError("PLATFORM_GATEWAY_URL is not set")
    if urllib.parse.urlparse(GATEWAY_URL).scheme != "https":
        raise ValueError("PLATFORM_GATEWAY_URL must be an https:// URL")
    payload = json.dumps({
        "jsonrpc": "2.0",
        "method": "tools/list",
        "id": f"studio-catalog-{int(time.time())}",
        "params": {},
    }).encode("utf-8")

    req = urllib.request.Request(
        GATEWAY_URL,
        data=payload,
        method="POST",
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {auth_token}",
        },
    )

    # Scheme is validated as https above.
    with urllib.request.urlopen(req, timeout=10) as resp:  # nosec B310
        return json.loads(resp.read().decode("utf-8"))


def _normalize_tools(raw_tools: list) -> tuple[list[dict], list[dict]]:
    """Convert Gateway tool list to Studio's (servers, tools) structure.

    Gateway tool names follow convention `{server}___{toolname}` (triple underscore)
    or similar server-prefixed naming. This parses server from tool name.
    """
    servers: dict[str, dict] = {}
    tools: list[dict] = []

    for t in raw_tools or []:
        name = t.get("name", "")
        if not name:
            continue

        # Heuristic: server name is prefix before first triple-underscore or dot.
        # Fall back to "default" if no server prefix is detectable.
        if "___" in name:
            server_name = name.split("___", 1)[0]
            tool_base = name.split("___", 1)[1]
        elif "." in name:
            server_name, tool_base = name.split(".", 1)
        else:
            server_name, tool_base = "default", name

        server_name = server_name.replace("_", "-")

        description = t.get("description", "") or ""
        schema = t.get("inputSchema") or t.get("input_schema") or {}
        schema_props = schema.get("properties", {}) if isinstance(schema, dict) else {}
        schema_summary = ", ".join(
            f"{k}: {v.get('type', 'any') if isinstance(v, dict) else 'any'}"
            for k, v in list(schema_props.items())[:6]  # Cap summary to avoid huge output
        )

        tools.append({
            "name": name,
            "tool_base": tool_base,
            "server": server_name,
            "description": description.strip()[:250],
            "input_schema_summary": schema_summary,
        })

        if server_name not in servers:
            servers[server_name] = {
                "name": server_name,
                "tool_count": 0,
                "description": "",
            }
        servers[server_name]["tool_count"] += 1

    return list(servers.values()), tools


@tool
def mcp_catalog_browser(user_token: str = "") -> dict:  # nosec B107 - empty-string default for an optional JWT arg, not a hardcoded password.
    """List every MCP tool available on the platform for the current user.

    This is the ONLY authorized way for Studio to discover MCP tools. The LLM
    must call this tool whenever it needs to reference a tool name in a
    recommendation, YAML manifest, or conversational response. Never use tool
    names not returned here.

    Args:
        user_token: The calling user's Cognito JWT (passed through from the UI).
                    If empty, Studio falls back to its own workload identity
                    and returns the full platform catalog.

    Returns:
        A dict with:
          - servers: list of {name, tool_count, description}
          - tools: list of {name, server, description, input_schema_summary}
          - fetched_at: timestamp the catalog was fetched
          - source: "user-scoped" or "workload-identity"
          - count: total tool count
          - note: additional advisory text for the LLM

    Guardrail: if this tool fails or returns zero tools, Studio must inform the
    user that the platform tool catalog is unavailable and refuse to recommend
    any specific MCP tools. Never invent tool names.
    """
    # Cache key: user token sub or "platform" for workload fallback
    cache_key = "platform"
    source = "workload-identity"
    token = user_token.strip() if user_token else ""

    if token:
        # Use user token; cache keyed by the token itself (short-lived, so fine)
        cache_key = f"user-{hash(token) & 0xFFFFFFFF:08x}"
        source = "user-scoped"
    else:
        # No user JWT reached the tool. A runtime-managed identity cannot
        # self-mint a workload token (AgentCore forbids it), so there is no
        # valid way to query the Gateway catalog here. Degrade gracefully — the
        # agent designs with standard capabilities and tells the user the
        # catalog is unavailable, rather than surfacing an AccessDenied error.
        logger.info("No user JWT forwarded to the catalog tool; returning unavailable (graceful degrade)")
        return {
            "servers": [],
            "tools": [],
            "count": 0,
            "source": "unavailable",
            "fetched_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "error": "No user token available; the Gateway catalog is user-scoped and cannot be fetched without one",
            "note": "GUARDRAIL: Inform the user the tool catalog is unavailable. Do not recommend specific MCP tools by name.",
        }

    # Check cache
    now = time.time()
    cached = _catalog_cache.get(cache_key)
    if cached and (now - cached["_cached_at"]) < CACHE_TTL_SECONDS:
        logger.info("Returning cached catalog", extra={"cache_key": cache_key[:20]})
        return {k: v for k, v in cached.items() if not k.startswith("_")}

    # Fetch fresh catalog
    try:
        resp = _fetch_catalog(token)
    except Exception as e:
        logger.warning("Gateway tools/list failed", extra={"error": str(e)})
        return {
            "servers": [],
            "tools": [],
            "count": 0,
            "source": source,
            "fetched_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "error": f"Gateway unreachable: {e}",
            "note": "GUARDRAIL: Gateway is unavailable. Inform the user and do not recommend specific MCP tools by name.",
        }

    if "error" in resp:
        logger.warning("Gateway returned JSON-RPC error", extra={"error": resp["error"]})
        return {
            "servers": [],
            "tools": [],
            "count": 0,
            "source": source,
            "fetched_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "error": str(resp["error"]),
            "note": "GUARDRAIL: Gateway returned an error. Inform the user and do not recommend specific MCP tools by name.",
        }

    raw_tools = (resp.get("result") or {}).get("tools", [])
    servers, tools = _normalize_tools(raw_tools)

    result = {
        "servers": servers,
        "tools": tools,
        "count": len(tools),
        "source": source,
        "fetched_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "note": (
            "GUARDRAIL: This is the only authoritative list of MCP tools on the platform. "
            "When referencing an MCP tool in recommendations or in agent.yaml gateway_refs, "
            "use ONLY server names from the 'servers' array. Never invent tool or server names. "
            "If the user asks for a tool not in this list, inform them it is not available and "
            "offer the closest alternatives from the catalog."
        ),
    }

    # Cache it
    _catalog_cache[cache_key] = {**result, "_cached_at": now}
    return result
