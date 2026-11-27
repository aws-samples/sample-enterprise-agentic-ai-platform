#!/usr/bin/env python3
"""EAP Base Image Entrypoint

Uses strands A2AServer (the AWS-documented approach) to serve agents
over the A2A protocol on port 9000.

Reference: https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/runtime-a2a.html
"""

import importlib
import json
import logging
import os
import signal
import sys
import uuid

import boto3
import yaml
import uvicorn
from fastapi import FastAPI
from strands import Agent, tool
from strands.multiagent.a2a import A2AServer

from logging_config import setup_logging

AGENT_CARD_PATH = os.environ.get("AGENT_CARD_PATH", "/app/agent-card.yaml")

# ---------------------------------------------------------------------------
# Env var contract — injected by the runtime module at deploy time
# ---------------------------------------------------------------------------
AGENT_MODULE = os.environ.get("AGENT_MODULE", "agent.main")
DOMAIN = os.environ.get("EAP_DOMAIN", "unknown")
AGENT_NAME = os.environ.get("EAP_AGENT_NAME", "unknown")
LOG_LEVEL = os.environ.get("LOG_LEVEL", "INFO")

# Injected by AgentCore runtime environment (not by our Terraform)
RUNTIME_URL = os.environ.get("AGENTCORE_RUNTIME_URL", "http://127.0.0.1:9000/")

logger = logging.getLogger("eap.entrypoint")


def load_agent_card() -> dict:
    """Load agent-card.yaml metadata (name, description, capabilities)."""
    if os.path.isfile(AGENT_CARD_PATH):
        try:
            with open(AGENT_CARD_PATH) as f:
                card = yaml.safe_load(f) or {}
            logger.info("Loaded agent card", extra={"path": AGENT_CARD_PATH})
            return card
        except Exception as e:
            logger.warning("Failed to parse agent card", extra={"path": AGENT_CARD_PATH, "error": str(e)})
    return {}


def load_agent() -> Agent:
    """Load the app team's agent module and return the Agent instance.

    If the agent is missing name or description, hydrate them from
    agent-card.yaml so the A2AServer can build a valid agent card.
    """
    try:
        module = importlib.import_module(AGENT_MODULE)
        agent = getattr(module, "agent", None)
        if agent is None:
            logger.error("Agent module has no 'agent' attribute", extra={"agent_module": AGENT_MODULE})
            sys.exit(1)

        # Hydrate name/description from agent-card.yaml if not set in code
        card = load_agent_card()
        if not getattr(agent, "name", None):
            agent.name = card.get("name") or AGENT_NAME
        if not getattr(agent, "description", None):
            agent.description = card.get("description") or f"EAP agent: {agent.name}"

        logger.info("Loaded agent", extra={"agent_module": AGENT_MODULE})
        return agent
    except ImportError as e:
        logger.error("Failed to import agent module", extra={"agent_module": AGENT_MODULE, "error": str(e)})
        sys.exit(1)


def discover_peers() -> dict[str, str]:
    """Discover A2A peer agents from *_RUNTIME_NAME env vars.

    PROTOCOL DISTINCTION — MCP vs A2A Tools:
    ─────────────────────────────────────────
    MCP Tools (via AgentCore Gateway):
      Agent → MCP Server → Enterprise systems (databases, APIs, SaaS)
      Declared in agent.yaml under gateway_refs.
      Purpose: Enterprise integration — connect agents to external services.

    A2A Tools (auto-injected by this entrypoint):
      Agent → A2A message/send → Peer agent (another LLM with its own tools)
      Declared in application.yaml under can_call.
      Purpose: Agent-to-agent collaboration — delegate work to peer agents.

    Both appear as callable tools to the LLM, but MCP tools invoke
    deterministic services while A2A tools invoke other reasoning systems.
    ─────────────────────────────────────────

    The deploy template injects env vars like:
        ANALYST_RUNTIME_NAME=team_bu_1_research_swarm_analyst
        WRITER_RUNTIME_NAME=team_bu_1_research_swarm_writer

    Returns a dict of {peer_name: runtime_name}, e.g.:
        {"analyst": "team_bu_1_research_swarm_analyst"}
    """
    peers = {}
    for key, value in os.environ.items():
        if key.endswith("_RUNTIME_NAME") and key not in ("EAP_AGENT_NAME",):
            peer_name = key.replace("_RUNTIME_NAME", "").lower().replace("_", "-")
            peers[peer_name] = value
    return peers


def create_peer_tool(peer_name: str, runtime_name: str):
    """Create a Strands tool function that invokes a peer agent via A2A.

    The tool uses the AgentCore invoke_agent_runtime API, wrapping the
    message in A2A JSON-RPC format — same as the invoke bridge Lambda.
    Resolves the full runtime ARN at startup by listing runtimes.
    """
    region = os.environ.get("AWS_REGION", os.environ.get("AWS_DEFAULT_REGION", "us-east-1"))
    client = boto3.client("bedrock-agentcore", region_name=region)

    # Resolve full runtime ARN and endpoint qualifier by listing runtimes.
    # AgentCore appends a random suffix to runtime names: {name}-{randomId}
    # We match exactly on name or name followed by hyphen+suffix to avoid
    # collisions (e.g., "analyst" matching "analyst_v2").
    runtime_arn = None
    endpoint_qualifier = f"{runtime_name}_endpoint"
    try:
        paginator = client.get_paginator("list_agent_runtimes")
        for page in paginator.paginate():
            for rt in page.get("agentRuntimeSummaries", []):
                rt_name = rt.get("agentRuntimeName", "")
                if rt_name == runtime_name or rt_name.startswith(f"{runtime_name}-"):
                    runtime_arn = rt["agentRuntimeArn"]
                    break
            if runtime_arn:
                break
    except Exception as e:
        logger.warning("Failed to resolve runtime ARN for peer",
                       extra={"peer": peer_name, "runtime_name": runtime_name, "error": str(e)})

    if not runtime_arn:
        logger.warning("Could not find runtime ARN for peer — tool will fail at invocation time",
                       extra={"peer": peer_name, "runtime_name": runtime_name})
        # Fallback: construct a best-guess ARN (will fail if wrong)
        account_id = os.environ.get("AWS_ACCOUNT_ID", "")
        if not account_id:
            try:
                sts = boto3.client("sts", region_name=region)
                account_id = sts.get_caller_identity()["Account"]
            except Exception:
                account_id = "unknown"
        runtime_arn = f"arn:aws:bedrock-agentcore:{region}:{account_id}:runtime/{runtime_name}"

    def peer_tool(message: str) -> str:
        """Send a message to a peer agent and return its response."""
        msg_id = f"peer-{uuid.uuid4().hex[:8]}"
        a2a_payload = {
            "jsonrpc": "2.0",
            "method": "message/send",
            "id": msg_id,
            "params": {
                "message": {
                    "role": "user",
                    "parts": [{"kind": "text", "text": message}],
                    "messageId": msg_id,
                }
            },
        }

        try:
            invoke_kwargs = {
                "agentRuntimeArn": runtime_arn,
                "payload": json.dumps(a2a_payload).encode("utf-8"),
            }
            if endpoint_qualifier:
                invoke_kwargs["qualifier"] = endpoint_qualifier

            response = client.invoke_agent_runtime(**invoke_kwargs)

            # Collect streaming response
            chunks = []
            body = response.get("response", response.get("body"))
            if hasattr(body, "__iter__"):
                for chunk in body:
                    if isinstance(chunk, dict):
                        data = chunk.get("PayloadPart", {}).get("bytes", b"")
                        chunks.append(data.decode("utf-8") if isinstance(data, bytes) else str(data))
                    elif isinstance(chunk, bytes):
                        chunks.append(chunk.decode("utf-8"))

            raw = "".join(chunks)

            # Extract text from A2A response
            try:
                a2a_result = json.loads(raw)
                result = a2a_result.get("result", {})
                artifacts = result.get("artifacts", [])
                if artifacts:
                    texts = [p["text"] for p in artifacts[0].get("parts", []) if p.get("kind") == "text"]
                    if texts:
                        return "\n".join(texts)
                parts = result.get("message", {}).get("parts", [])
                if parts:
                    texts = [p["text"] for p in parts if p.get("kind") == "text"]
                    if texts:
                        return "\n".join(texts)
            except (json.JSONDecodeError, KeyError):
                pass

            return raw or "(empty response)"
        except Exception as e:
            return f"Error calling {peer_name}: {e}"

    # Set function metadata for Strands tool registration
    peer_tool.__name__ = f"call_{peer_name.replace('-', '_')}"
    peer_tool.__doc__ = (
        f"Send a message to the {peer_name} peer agent and get its response. "
        f"Use this to hand off work to {peer_name} when their expertise is needed. "
        f"Args: message — the text message to send to {peer_name}."
    )

    return tool(peer_tool)


def register_peer_tools(agent: Agent) -> None:
    """Auto-register A2A peer-calling tools on the agent.

    Scans for *_RUNTIME_NAME env vars and creates a tool for each peer.
    This enables the swarm/choreography pattern where agents call each
    other directly — no Step Functions orchestration needed.
    """
    peers = discover_peers()
    if not peers:
        logger.info("No A2A peers discovered — skipping peer tool registration",
                     extra={"env_keys_checked": [k for k in os.environ if "RUNTIME" in k]})
        return

    for peer_name, runtime_name in peers.items():
        peer_tool = create_peer_tool(peer_name, runtime_name)
        # Add tool to agent's tool list
        if hasattr(agent, "tool_registry") and agent.tool_registry:
            agent.tool_registry.register_tool(peer_tool)
        elif hasattr(agent, "tools"):
            if agent.tools is None:
                agent.tools = []
            agent.tools.append(peer_tool)

        logger.info(
            "Registered peer tool",
            extra={"peer": peer_name, "runtime": runtime_name, "tool": f"call_{peer_name.replace('-', '_')}"},
        )


# --- Additive third-party span export (platform-owned; base-image only) ---
# AgentCore-managed ADOT auto-instrumentation already installed a global tracer
# provider that exports the AWS-native leg DIRECTLY to CloudWatch/X-Ray. We do
# NOT touch that exporter and we do NOT override OTEL_EXPORTER_OTLP_ENDPOINT.
# We ONLY ADD a second processor so a COPY of the same spans also goes to the
# platform OTel_Collector for third-party (Langfuse/alternate) delivery.

# Fixed SSM parameter path the platform publishes the OTel_Collector's stable
# OTLP endpoint to. This is a HARDCODED platform constant (not injected via an
# env var) — the deploy paths grant scoped ssm:GetParameter on exactly this ARN.
DEFAULT_COLLECTOR_ENDPOINT_SSM_PARAM = "/eap/observability/collector-endpoint"


def _resolve_collector_endpoint() -> str | None:
    """Resolve the third-party OTel_Collector endpoint for the additional exporter.

    Precedence:
      1. EAP_OTEL_COLLECTOR_ENDPOINT set/non-empty -> use it verbatim
         (explicit deploy-time override; original task-6.1 behavior).
      2. Else -> read the endpoint VALUE from SSM Parameter Store at container
         boot from the fixed constant path DEFAULT_COLLECTOR_ENDPOINT_SSM_PARAM,
         so a changed endpoint takes effect on an agent restart with NO Terraform
         apply and NO new AgentCore runtime version (the param NAME is a stable
         constant baked into this image).
      3. On any SSM failure/empty -> None (third-party leg off), unchanged today.

    Fail-safe: ANY SSM failure (missing param, AccessDenied, network/SSM error,
    boto3 unavailable) is swallowed with a warning and returns None — it never
    raises, so neither the agent nor the AWS-native leg is disturbed.
    """
    explicit = os.environ.get("EAP_OTEL_COLLECTOR_ENDPOINT")
    if explicit:
        return explicit

    ssm_param = DEFAULT_COLLECTOR_ENDPOINT_SSM_PARAM
    try:
        # Region from the standard AWS env; let boto3 default it when unset.
        region = os.environ.get("AWS_REGION", os.environ.get("AWS_DEFAULT_REGION"))
        ssm = boto3.client("ssm", region_name=region) if region else boto3.client("ssm")
        resp = ssm.get_parameter(Name=ssm_param, WithDecryption=False)
        value = (resp.get("Parameter", {}) or {}).get("Value") or None
        if value:
            logger.info("Resolved third-party collector endpoint from SSM",
                        extra={"ssm_param": ssm_param})
        else:
            logger.warning("SSM parameter resolved to an empty endpoint — skipping additional exporter",
                           extra={"ssm_param": ssm_param})
        return value
    except Exception as e:
        # No-op + warn: a failed SSM lookup must never break the agent or the
        # AWS-native leg. Third-party leg simply stays off this boot.
        logger.warning("Failed to resolve collector endpoint from SSM — skipping additional exporter",
                       extra={"ssm_param": ssm_param, "error": str(e)})
        return None


def register_additional_span_exporter() -> None:
    collector_endpoint = _resolve_collector_endpoint()
    if not collector_endpoint:
        logger.info("No third-party collector endpoint set — skipping additional exporter")
        return
    try:
        from opentelemetry import trace
        from opentelemetry.sdk.trace import TracerProvider
        from opentelemetry.sdk.trace.export import BatchSpanProcessor
        from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter

        provider = trace.get_tracer_provider()
        if not isinstance(provider, TracerProvider):
            # AgentCore owns the provider; if it isn't an SDK provider we can add to,
            # do nothing rather than risk disturbing the AWS-native leg.
            logger.warning("Tracer provider is not an SDK TracerProvider — additional exporter skipped")
            return

        # Per-BU credentials (Basic auth for the collector→Langfuse hop are applied
        # at the collector; here we only carry any headers the collector requires).
        headers = {}
        token = os.environ.get("EAP_OTEL_COLLECTOR_HEADERS")  # optional, secret-injected
        if token:
            headers = dict(h.split("=", 1) for h in token.split(",") if "=" in h)

        # OTLP/HTTP path normalization. The OTLPSpanExporter `endpoint=` kwarg is
        # used VERBATIM as the POST target — unlike the OTEL_EXPORTER_OTLP_ENDPOINT
        # env var, the kwarg does NOT auto-append the `/v1/traces` signal path. The
        # platform publishes the collector endpoint as a BARE receiver base URL
        # (e.g. http://otel-collector.otel.eap.internal:4318), so posting to
        # it directly hits the collector's root and returns 404/400. Append the
        # standard traces path when it is not already present so spans land on the
        # OTLP/HTTP traces receiver.
        traces_endpoint = collector_endpoint.rstrip("/")
        if not traces_endpoint.endswith("/v1/traces"):
            traces_endpoint = f"{traces_endpoint}/v1/traces"

        # Telemetry MUST be best-effort and MUST NOT stall the user turn. If the
        # collector is slow or unreachable, the OTLP/HTTP exporter defaults to a
        # 10s timeout AND retries with exponential backoff up to 6 times — the
        # whole cycle runs ~30s. Because the batch is flushed when the turn's
        # root span ends, that retry cycle blocks turn completion: the agent
        # finishes generating but the terminal A2A frame is delayed ~30s, which
        # locks the chat input for that long. (Root-caused Sept 2026: the ADE
        # runtime could not resolve the collector's Cloud Map DNS, so every turn
        # paid the full retry cost.)
        #
        # Fix: cap the exporter `timeout` to 3s. In this OTel version (1.44) the
        # exporter's `timeout` is the TOTAL budget for the export INCLUDING all
        # retries — it computes `deadline = time() + timeout` and stops retrying
        # once the next backoff would exceed the deadline (see the OTLP/HTTP
        # exporter `export()`), NOT a per-attempt timeout. So 3s bounds the
        # entire export+retry cycle: a dead collector drops the batch within ~3s
        # and the turn (and chat input) completes normally. Telemetry is
        # best-effort — never on the user's critical path.
        #
        # NOTE: BatchSpanProcessor's `export_timeout_millis` is NOT used to bound
        # a single export in this SDK version (the SDK marks it "no way to pass
        # timeout to export"), so the exporter `timeout` is the real guard.
        additional = OTLPSpanExporter(endpoint=traces_endpoint, headers=headers or None, timeout=3)
        # ADD (do not replace) — AgentCore's own processor/exporter stays active.
        provider.add_span_processor(BatchSpanProcessor(additional))
        logger.info("Registered ADDITIONAL span exporter (third-party leg)",
                    extra={"collector_endpoint": collector_endpoint, "traces_endpoint": traces_endpoint})
    except Exception as e:
        # Never let third-party wiring break the agent or the AWS-native leg.
        logger.warning("Failed to register additional span exporter", extra={"error": str(e)})


def ping() -> dict:
    """Health check — required by the AgentCore runtime (GET /ping)."""
    return {"status": "healthy"}


def create_app(agent: Agent) -> FastAPI:
    """Create FastAPI app with A2AServer mounted at root.

    Follows the exact pattern from AWS docs:
    https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/runtime-a2a.html
    """
    logging.info(f"Runtime URL: {RUNTIME_URL}")

    # A2AServer wraps the strands Agent for A2A protocol compatibility
    a2a_server = A2AServer(
        agent=agent,
        http_url=RUNTIME_URL,
        serve_at_root=True,
        enable_a2a_compliant_streaming=True,
    )

    app = FastAPI()

    # Health check — required by AgentCore runtime. Registered before the root
    # mount so /ping is matched first.
    app.add_api_route("/ping", ping, methods=["GET"])

    # Mount A2A app at root — handles POST / (JSON-RPC) and GET /.well-known/agent-card.json
    app.mount("/", a2a_server.to_fastapi_app())

    return app


def main():
    """Main entrypoint — load agent, start A2A server."""
    setup_logging(LOG_LEVEL, DOMAIN, AGENT_NAME)

    logger.info(
        "EAP agent starting",
        extra={
            "domain": DOMAIN,
            "agent_name": AGENT_NAME,
            "agent_module": AGENT_MODULE,
            "runtime_url": RUNTIME_URL,
        },
    )

    agent = load_agent()
    register_peer_tools(agent)
    register_additional_span_exporter()
    app = create_app(agent)

    # Graceful shutdown on SIGTERM/SIGINT
    def handle_signal(signum, frame):
        logger.info("Shutdown signal received")
        sys.exit(0)

    signal.signal(signal.SIGTERM, handle_signal)
    signal.signal(signal.SIGINT, handle_signal)

    uvicorn.run(app, host="0.0.0.0", port=9000, log_level=LOG_LEVEL.lower())  # nosec B104 - binding all interfaces is required inside the container so the ALB/target group can reach it.


if __name__ == "__main__":
    main()
