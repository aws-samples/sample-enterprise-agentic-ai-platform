"""KB Retriever Agent — searches internal knowledge bases.

Returns ranked results from Bedrock Knowledge Bases, OpenSearch, or similar.
In production, this would call the actual KB APIs. For the demo, returns
stub results to validate the RRF pipeline infrastructure.
"""
import json
import os
from strands import Agent
from strands.models.bedrock import BedrockModel

model = BedrockModel(
    model_id=os.environ.get("MODEL_ID", "us.anthropic.claude-sonnet-5"),
)

agent = Agent(
    model=model,
    system_prompt=(
        "You are a knowledge base retrieval agent. "
        "Given a search query, return ranked results from internal knowledge bases. "
        "Return results as a JSON list with id, title, snippet, and score fields."
    ),
)


def handler(event, context=None):
    payload = event if isinstance(event, dict) else json.loads(event)
    query = payload.get("query", str(payload))

    # Stub: in production, call Bedrock KB / OpenSearch / etc.
    return {
        "source": "knowledge-base",
        "query": query,
        "results": [
            {"id": "kb-001", "title": "Internal Policy Doc", "snippet": f"KB result for: {query}", "score": 0.95},
            {"id": "kb-002", "title": "Architecture Guide", "snippet": f"KB result for: {query}", "score": 0.87},
            {"id": "kb-003", "title": "Runbook Entry", "snippet": f"KB result for: {query}", "score": 0.72},
        ],
    }
