"""Extractor Agent — Step 1 of orchestrated flow.

Receives raw text via A2A, extracts structured facts using Claude Sonnet 5.
Called by an external controller (Step Functions), not by another agent.

Environment variables (injected by EAP runtime module):
  MODEL_ID — Bedrock foundation model ID
"""

import json
import logging
import os

from strands import Agent
from strands.models.bedrock import BedrockModel

logger = logging.getLogger("eap.agent.extractor")

MODEL_ID = os.environ.get("MODEL_ID", "anthropic.claude-sonnet-5")

model = BedrockModel(model_id=MODEL_ID)
agent = Agent(
    model=model,
    system_prompt=(
        "You are a fact extraction agent. Given raw text, extract key facts, "
        "entities, numbers, and data points. Return ONLY valid JSON with this "
        "structure: {\"facts\": [{\"key\": \"...\", \"value\": \"...\", "
        "\"confidence\": 0.0-1.0}]}. No prose, no markdown — just JSON."
    ),
)


async def handle_request(query: str) -> dict:
    """Extract structured facts from raw text."""
    logger.info("Extracting facts from input", extra={"length": len(query)})

    try:
        result = agent(f"Extract facts from this text:\n\n{query}")
        response_text = str(result)

        # Try to parse as JSON, fall back to wrapping in structure
        try:
            parsed = json.loads(response_text)
            facts = parsed.get("facts", [])
        except json.JSONDecodeError:
            facts = [{"key": "raw_extraction", "value": response_text, "confidence": 0.8}]

        return {
            "facts": facts,
            "model": MODEL_ID,
            "status": "completed",
        }
    except Exception as e:
        logger.error("Extraction failed", extra={"error": str(e)})
        return {"facts": [], "model": MODEL_ID, "status": "error", "error": str(e)}
