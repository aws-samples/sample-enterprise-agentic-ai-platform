"""Enricher Agent — Step 2 of orchestrated flow.

Receives extracted facts via A2A, enriches them with categories,
context, and relevance scores using Claude Sonnet 5.
Called by an external controller (Step Functions).

Environment variables (injected by EAP runtime module):
  MODEL_ID — Bedrock foundation model ID
"""

import json
import logging
import os

from strands import Agent
from strands.models.bedrock import BedrockModel

logger = logging.getLogger("eap.agent.enricher")

MODEL_ID = os.environ.get("MODEL_ID", "anthropic.claude-sonnet-5")

model = BedrockModel(model_id=MODEL_ID)
agent = Agent(
    model=model,
    system_prompt=(
        "You are a fact enrichment agent. Given extracted facts as JSON, "
        "add category labels, relevance scores (0-1), and brief context "
        "for each fact. Return ONLY valid JSON with this structure: "
        "{\"enriched_facts\": [{\"key\": \"...\", \"value\": \"...\", "
        "\"category\": \"...\", \"relevance\": 0.0-1.0, "
        "\"context\": \"...\"}]}. No prose — just JSON."
    ),
)


async def handle_request(query: str) -> dict:
    """Enrich extracted facts with categories and context."""
    logger.info("Enriching facts", extra={"length": len(query)})

    try:
        result = agent(f"Enrich these extracted facts:\n\n{query}")
        response_text = str(result)

        try:
            parsed = json.loads(response_text)
            enriched = parsed.get("enriched_facts", [])
        except json.JSONDecodeError:
            enriched = [{"raw": response_text, "category": "unknown", "relevance": 0.5}]

        return {
            "enriched_facts": enriched,
            "model": MODEL_ID,
            "status": "completed",
        }
    except Exception as e:
        logger.error("Enrichment failed", extra={"error": str(e)})
        return {"enriched_facts": [], "model": MODEL_ID, "status": "error", "error": str(e)}
