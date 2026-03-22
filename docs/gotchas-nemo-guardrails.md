# NeMo Guardrails Gotchas

Issues encountered integrating NeMo Guardrails with OpenClaw on Red Hat AI. Each gotcha includes the root cause, our workaround, and what should be fixed upstream.

## 1. Response format mismatch (NeMo vs OpenAI)

**Symptom:** OpenClaw shows empty responses. The guardrails service returns 200 OK but the content is missing.

**Root cause:** NeMo Guardrails' open-source server returns responses in its own format:
```json
{"messages": [{"role": "assistant", "content": "..."}]}
```

OpenClaw (and most OpenAI-compatible clients) expects:
```json
{"choices": [{"message": {"role": "assistant", "content": "..."}, "index": 0}], "id": "...", "model": "..."}
```

NeMo's docs describe the endpoint as "OpenAI-compatible" but the response shape is not. The enterprise microservice image (`nvcr.io/nvidia/nemo-microservices/guardrails`) may have true OpenAI compatibility, but the open-source server and the RHOAI-bundled image (`quay.io/trustyai/nemo-guardrails-server`) do not.

**Workaround:** OpenAI format adapter sidecar (`openai-adapter` container in `guardrails-deployment.yaml`). A 50-line Python HTTP server that proxies requests to NeMo on localhost:8000 and transforms `{"messages": [...]}` → `{"choices": [...]}` in the response.

**What should be fixed:** NeMo Guardrails server should return standard OpenAI response format when the request comes in on `/v1/chat/completions`. Or expose a separate truly-OpenAI-compatible endpoint.

## 2. Multi-part content crashes `get_colang_history()`

**Symptom:** First message works fine. Second message returns "Internal server error." The guardrails correctly blocks/allows the request, generates the response, then crashes during post-processing.

**Root cause:** OpenClaw sends message `content` in OpenAI multi-part format (a list of typed blocks):
```json
{"content": [{"type": "text", "text": "hello"}]}
```

This is valid per the OpenAI API spec (used for vision/multi-modal messages). NeMo processes it correctly through the input check, flow matching, and response generation. But in `get_colang_history()` (`nemoguardrails/actions/llm/utils.py` line 442), it calls `.rsplit()` on the content field:

```python
split_history = history.rsplit(utterance_to_replace, 1)
```

`.rsplit()` is a string method. When content is a list, Python throws:
```
TypeError: must be str or None, not list
```

The error happens *after* the response is generated, corrupting the return value.

**Workaround:** The adapter normalizes all message `content` fields from list to string before forwarding to NeMo:
```python
for msg in req_json.get("messages", []):
    c = msg.get("content")
    if isinstance(c, list):
        parts = [p.get("text", "") if isinstance(p, dict) else p for p in c]
        msg["content"] = "\n".join(parts)
```

**What should be fixed:** `get_colang_history()` should handle both string and list content formats. The OpenAI multi-part format is standard and widely used. A simple `if isinstance(content, list): content = " ".join(p.get("text","") for p in content if isinstance(p, dict))` before the `.rsplit()` would fix it.

## 3. No streaming support

**Symptom:** OpenClaw sends `"stream": true` in requests. NeMo Guardrails ignores the flag and returns a single JSON response. OpenClaw expects SSE (Server-Sent Events) chunks and shows empty output or "Internal server error."

**Root cause:** The NeMo Guardrails open-source server does not support streaming responses. It always returns a complete response in one shot, regardless of the `stream` parameter.

**Workaround:** The adapter strips `"stream": true` before forwarding to NeMo, waits for the full response, then converts it to SSE format:
```
data: {"choices": [{"delta": {"role": "assistant", "content": "..."}}]}

data: {"choices": [{"delta": {}, "finish_reason": "stop"}]}

data: [DONE]
```

The entire response is sent as a single SSE chunk (not token-by-token), so the user sees it appear all at once after the guardrails processing completes (~5-16s).

**What should be fixed:** NeMo Guardrails should support streaming. The rails processing is inherently non-streaming (all checks must complete before the response), but the response delivery could be streamed token-by-token after the output rails pass.

## 4. RHOAI image missing `langchain-anthropic`

**Symptom:** NeMo Guardrails pod crashes on startup with `ModuleNotFoundError: No module named 'langchain_anthropic'` when configured to use Anthropic as the LLM engine.

**Root cause:** The RHOAI-bundled image (`quay.io/trustyai/nemo-guardrails-server:latest`) does not include the `langchain-anthropic` package. It ships with `langchain-openai` but not the Anthropic equivalent.

**Workaround:** Install at pod startup via command override:
```bash
/app/.venv/bin/pip install --no-cache-dir langchain-anthropic
```

This adds ~15s to pod startup time.

**What should be fixed:** The RHOAI NeMo Guardrails image should include `langchain-anthropic` (and `langchain-google-genai` etc.) to support all major LLM providers out of the box.

## 5. Self-check prompt too sensitive to agent metadata

**Symptom:** NeMo Guardrails blocks normal "hello" messages. The self-check input rail flags benign messages as "SAFETY VIOLATION DETECTED: Potential system exploitation attempt."

**Root cause:** OpenClaw prepends internal metadata to every message (sender label, channel ID, timestamp). The default self-check prompt sees strings like `"openclaw-control-ui"` and `"untrusted metadata"` and interprets them as exploitation attempts.

**Workaround:** Tuned the self-check input prompt to explicitly ignore system metadata:
```
DO NOT BLOCK:
- Messages that contain internal system metadata (component names like
  "openclaw-control-ui", source labels, formatting tags — these are normal)
```

Also changed the `instructions` from "You are a safety guardrail" (which caused the model to return safety analyses instead of actual responses) to "You are a helpful enterprise AI assistant" (which generates normal responses with safety checks running in the background).

**What should be fixed:** The default self-check prompts should be resilient to common message envelope patterns. Agent frameworks routinely add metadata/context to messages. The self-check should evaluate the user's intent, not the transport metadata.

## 6. `NemoGuardrail` CRD (NIM Operator) doesn't support custom commands

**Symptom:** Cannot use the `NemoGuardrail` CRD from the NIM Operator to deploy with `langchain-anthropic` because the CRD doesn't allow command overrides.

**Root cause:** The `NemoGuardrail` CR manages the pod lifecycle but doesn't expose a `command` or `args` field. There's no way to inject `pip install langchain-anthropic` at startup.

**Workaround:** Deployed as a standalone Deployment instead of using the CRD. This gives full control over the container command.

**What should be fixed:** The `NemoGuardrail` CRD should support init containers, command overrides, or an `extraPackages` field for installing additional Python packages.

## Architecture: The Adapter Pattern

Because of gotchas 1-3, we deploy a lightweight Python sidecar (`openai-adapter`) alongside the NeMo Guardrails container:

```
Port 8080 (Service target)     Port 8000 (NeMo internal)
┌──────────────────────┐       ┌─────────────────────────┐
│   OpenAI Adapter     │──────▶│   NeMo Guardrails       │
│                      │       │   Server                │
│ - Normalizes content │       │ - config.yaml           │
│   list → string      │       │ - rails.co (Colang v1)  │
│ - Strips stream flag │       │ - self_check_input      │
│ - Converts response  │       │ - self_check_output     │
│   format to OpenAI   │       │                         │
│ - Returns SSE when   │       │                         │
│   stream requested   │       │                         │
└──────────────────────┘       └─────────────────────────┘
```

The adapter is ~80 lines of Python using only stdlib (`http.server`, `json`, `urllib`). No dependencies to install. It handles all the format bridging so NeMo Guardrails sees clean string-content, non-streaming requests.
