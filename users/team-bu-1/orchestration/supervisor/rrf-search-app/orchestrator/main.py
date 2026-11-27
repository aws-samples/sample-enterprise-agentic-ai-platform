"""RRF Orchestrator Agent — dispatch queries and fuse results.

In the Step Functions supervisor pattern, this agent is invoked twice:
1. orchestrator_dispatch: receives user query, returns it as-is for parallel fan-out
2. orchestrator_aggregate: receives array of retriever results, applies RRF fusion

The rrf_fuse tool is registered on the Strands Agent so the LLM calls it
deterministically rather than reimplementing fusion in prose.
"""
import json
import os
from strands import Agent, tool
from strands.models.bedrock import BedrockModel

K = 60  # Standard RRF constant


@tool
def rrf_fuse(retriever_results_json: str) -> str:
    """Apply Reciprocal Rank Fusion across multiple ranked result lists.

    Call this tool whenever you receive ranked search results from retrievers.
    Pass the full JSON array of retriever results as a single string.

    Each retriever result should have a "results" key containing a list of
    documents with id, title, snippet, and score fields.

    Returns a JSON object with fused_results (top 10) and total_fused count.

    Args:
        retriever_results_json: JSON string of the array of retriever results.
    """
    try:
        retriever_results = json.loads(retriever_results_json)
    except (json.JSONDecodeError, TypeError):
        return json.dumps({"error": "Invalid JSON input", "fused_results": [], "total_fused": 0})

    if not isinstance(retriever_results, list):
        retriever_results = [retriever_results]

    scores: dict[str, float] = {}
    docs: dict[str, dict] = {}

    for retriever in retriever_results:
        results = retriever.get("results", []) if isinstance(retriever, dict) else []
        for rank, doc in enumerate(results, start=1):
            doc_id = doc.get("id", doc.get("title", str(rank)))
            scores[doc_id] = scores.get(doc_id, 0.0) + 1.0 / (K + rank)
            if doc_id not in docs:
                docs[doc_id] = doc

    fused = sorted(scores.items(), key=lambda x: x[1], reverse=True)
    fused_results = [
        {**docs[doc_id], "rrf_score": round(score, 6)}
        for doc_id, score in fused
    ]

    return json.dumps({
        "fused_results": fused_results[:10],
        "total_fused": len(fused_results),
    })


model = BedrockModel(
    model_id=os.environ.get("MODEL_ID", "us.anthropic.claude-sonnet-5"),
)

agent = Agent(
    model=model,
    system_prompt=(
        "You are an RRF search orchestrator. "
        "When you receive search results from retrievers, you MUST call the rrf_fuse tool "
        "with the complete JSON array of retriever results. "
        "Do NOT attempt to compute RRF scores yourself — always use the tool. "
        "After calling the tool, you MUST output the tool's JSON result as your final response verbatim. "
        "Do not add any commentary, explanation, or markdown formatting — just the raw JSON from the tool."
    ),
    tools=[rrf_fuse],
)
