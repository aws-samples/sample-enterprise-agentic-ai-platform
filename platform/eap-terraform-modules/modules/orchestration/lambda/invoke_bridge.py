"""AgentCore Runtime Invoke Bridge — Temporary Lambda
Bridges Step Functions → AgentCore Runtime by consuming the streaming
response from invokeAgentRuntime and returning a complete JSON payload.

TEMPORARY: This Lambda exists because AgentCore invokeAgentRuntime is
streaming-only and Step Functions doesn't support streaming SDK integrations.
Remove this when AWS adds a native SFN optimized integration for AgentCore,
or when invokeAgentRuntime supports a synchronous response mode.

Deployed once per domain, shared by all Step Functions state machines.
"""
import json
import boto3

client = boto3.client("bedrock-agentcore")


def handler(event, context):
    """Invoke an AgentCore Runtime agent and return the complete response.

    Expected input from Step Functions:
        {
            "AgentRuntimeEndpointArn": "arn:aws:...",
            "Payload": { ... }  # optional, forwarded to the agent
        }

    Returns:
        {
            "statusCode": 200,
            "runtimeSessionId": "...",
            "response": "..."  # complete agent response text
        }
    """
    endpoint_arn = event["AgentRuntimeEndpointArn"]
    payload = event.get("Payload", {})

    # Wrap payload in A2A JSON-RPC format — AgentCore runtimes expect this protocol
    msg_id = f"sfn-{context.aws_request_id}" if context else "sfn-bridge"
    a2a_payload = {
        "jsonrpc": "2.0",
        "method": "message/send",
        "id": msg_id,
        "params": {
            "message": {
                "role": "user",
                "parts": [{"kind": "text", "text": json.dumps(payload)}],
                "messageId": msg_id,
            }
        },
    }

    # The endpoint ARN may be a full runtime-endpoint ARN:
    #   arn:aws:bedrock-agentcore:REGION:ACCOUNT:runtime/RUNTIME_ID/runtime-endpoint/QUALIFIER
    # The invoke_agent_runtime API expects the runtime ARN and qualifier separately.
    invoke_kwargs = {"payload": json.dumps(a2a_payload).encode("utf-8")}

    if "/runtime-endpoint/" in endpoint_arn:
        parts = endpoint_arn.split("/runtime-endpoint/")
        invoke_kwargs["agentRuntimeArn"] = parts[0]
        invoke_kwargs["qualifier"] = parts[1]
    else:
        invoke_kwargs["agentRuntimeArn"] = endpoint_arn

    response = client.invoke_agent_runtime(**invoke_kwargs)

    # Collect streaming response chunks
    chunks = []
    body = response.get("response", response.get("body"))
    if hasattr(body, "__iter__"):
        for chunk in body:
            if isinstance(chunk, dict):
                data = chunk.get("PayloadPart", {}).get("bytes", b"")
                chunks.append(data.decode("utf-8") if isinstance(data, bytes) else str(data))
            elif isinstance(chunk, bytes):
                chunks.append(chunk.decode("utf-8"))

    # Parse the A2A response to extract the agent's text output
    raw = "".join(chunks)
    try:
        a2a_result = json.loads(raw)
        # Extract text from A2A result artifacts or message parts
        result = a2a_result.get("result", {})
        artifacts = result.get("artifacts", [])
        if artifacts:
            texts = [p["text"] for p in artifacts[0].get("parts", []) if p.get("kind") == "text" or p.get("type") == "text"]
            if texts:
                raw = "\n".join(texts)
        elif result.get("message", {}).get("parts"):
            texts = [p["text"] for p in result["message"]["parts"] if p.get("kind") == "text" or p.get("type") == "text"]
            if texts:
                raw = "\n".join(texts)
    except (json.JSONDecodeError, KeyError):
        pass  # Return raw response if not valid A2A

    # Try to parse the agent's text as JSON (agents return structured data)
    try:
        parsed = json.loads(raw)
        return parsed
    except (json.JSONDecodeError, TypeError):
        return {
            "statusCode": response.get("httpStatusCode", 200),
            "runtimeSessionId": response.get("runtimeSessionId", ""),
            "response": raw,
        }
