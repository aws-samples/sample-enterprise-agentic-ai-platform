"""Summarizer Agent — Step 3 of orchestrated flow.

Receives enriched facts via A2A, produces a human-readable summary
using Claude Sonnet 5. Final step in the orchestrated pipeline.
Called by an external controller (Step Functions).

Environment variables (injected by EAP runtime module):
  MODEL_ID — Bedrock foundation model ID
"""

import logging
import os

from strands import Agent
from strands.models.bedrock import BedrockModel

logger = logging.getLogger("eap.agent.summarizer")

MODEL_ID = os.environ.get("MODEL_ID", "anthropic.claude-sonnet-5")

model = BedrockModel(model_id=MODEL_ID)
agent = Agent(
    model=model,
    system_prompt=(
        "You are a summarization agent. Given enriched facts with categories "
        "and relevance scores, produce a clear, concise executive summary. "
        "Prioritize high-relevance facts. Use bullet points for key findings "
        "and a brief conclusion paragraph."
    ),
)


async def handle_request(query: str) -> dict:
    """Produce a human-readable summary from enriched facts."""
    logger.info("Summarizing enriched facts", extra={"length": len(query)})

    try:
        result = agent(f"Summarize these enriched facts into an executive summary:\n\n{query}")
        summary = str(result)

        return {
            "summary": summary,
            "model": MODEL_ID,
            "status": "completed",
        }
    except Exception as e:
        logger.error("Summarization failed", extra={"error": str(e)})
        return {"summary": f"Error: {e}", "model": MODEL_ID, "status": "error"}
