"""Web Retriever Agent — searches external web sources.

Returns ranked results from web search, documentation sites, etc.
In production, this would call search APIs. For the demo, returns
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
        "You are a web retrieval agent. "
        "Given a search query, return ranked results from web sources. "
        "Return results as a JSON list with id, title, snippet, and score fields."
    ),
)


def handler(event, context=None):
    payload = event if isinstance(event, dict) else json.loads(event)
    query = payload.get("query", str(payload))

    # Stub: in production, call web search APIs
    return {
        "source": "web-search",
        "query": query,
        "results": [
            {"id": "web-001", "title": "AWS Documentation", "snippet": f"Web result for: {query}", "score": 0.91},
            {"id": "web-002", "title": "Stack Overflow Answer", "snippet": f"Web result for: {query}", "score": 0.84},
            {"id": "web-003", "title": "Blog Post", "snippet": f"Web result for: {query}", "score": 0.68},
        ],
    }
