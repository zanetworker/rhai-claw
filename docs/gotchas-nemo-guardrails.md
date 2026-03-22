# NeMo Guardrails Gotchas

Issues encountered integrating NeMo Guardrails with OpenClaw on Red Hat AI. Each gotcha includes the root cause, our workaround, and what should be fixed upstream.

## Severity

| Rating | Icon | Meaning |
|--------|------|---------|
| **Dead end** | :no_entry: | No workaround on this path. Must change approach. |
| **Surprising** | :warning: | Not obvious from docs. Costs hours of debugging. |
| **Obvious** | :bulb: | Expected if you know the tech. |

## Surprising

### 1. Response format mismatch (NeMo vs OpenAI) :warning:

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

### 2. Multi-part content crashes `get_colang_history()` :warning:

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

### 3. No streaming support :warning:

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

### 4. RHOAI image missing `langchain-anthropic` :warning:

**Symptom:** NeMo Guardrails pod crashes on startup with `ModuleNotFoundError: No module named 'langchain_anthropic'` when configured to use Anthropic as the LLM engine.

**Root cause:** The RHOAI-bundled image (`quay.io/trustyai/nemo-guardrails-server:latest`) does not include the `langchain-anthropic` package. It ships with `langchain-openai` but not the Anthropic equivalent.

**Workaround:** Install at pod startup via command override:
```bash
/app/.venv/bin/pip install --no-cache-dir langchain-anthropic
```

This adds ~15s to pod startup time.

**What should be fixed:** The RHOAI NeMo Guardrails image should include `langchain-anthropic` (and `langchain-google-genai` etc.) to support all major LLM providers out of the box.

### 5. Self-check prompt too sensitive to agent metadata :warning:

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

### 7. NeMo Guardrails depends on LangChain for LLM access :warning:

**Priority rank: NEW**

NeMo Guardrails doesn't call LLM APIs directly. It uses LangChain as its LLM abstraction layer. The `engine` field in `config.yaml` maps to a specific `langchain-*` Python package:

| `engine` | Package required | Shipped in RHOAI image? |
|----------|-----------------|------------------------|
| `openai` | `langchain-openai` | Yes |
| `anthropic` | `langchain-anthropic` | No |
| `google` | `langchain-google-genai` | No |
| `nim` | `langchain-nvidia-ai-endpoints` | Yes |

This is a hidden dependency chain: NeMo → LangChain → provider-specific LangChain package → provider SDK → API.

**Why it matters:**

1. **Provider lock-in through packaging.** The RHOAI image only ships `langchain-openai` and `langchain-nvidia-ai-endpoints`. Want to use Anthropic or Google? Pip install at runtime or rebuild the image. This limits which models can be used for guardrail evaluation.

2. **LangChain is a heavy dependency.** It pulls in dozens of sub-packages, has frequent breaking changes between versions, and adds complexity to debugging. When something fails in the guardrails → LangChain → provider SDK chain, the stack traces are deep and hard to follow.

3. **Red Hat ships Llama Stack as the inference abstraction.** If NeMo used Llama Stack's `/v1/chat/completions` (OpenAI-compatible) endpoint directly instead of LangChain, it would work with any model served by Llama Stack — vLLM, TGI, Ollama, remote providers — without needing provider-specific packages.

**Alternatives to explore:**

| Approach | What changes | Benefit |
|----------|-------------|---------|
| **NeMo + Llama Stack inference** | Point NeMo's `engine: openai` at a Llama Stack endpoint | Any model Llama Stack serves becomes available for guardrail evaluation. No LangChain provider packages needed. |
| **NeMo + vLLM directly** | Point `engine: openai` at vLLM's OpenAI-compatible endpoint | Self-hosted model for guardrail checks. No external API calls. |
| **Replace NeMo with Guardrails Orchestrator** | Use the IBM FMS-based `GuardrailsOrchestrator` CRD instead of NeMo | Different architecture (detector-based, not LLM-as-judge). Uses Granite Guardian models via KServe. No LangChain dependency. |
| **NeMo drops LangChain** | NeMo calls OpenAI-compatible APIs directly via `httpx`/`requests` | Eliminates the LangChain layer entirely. Any OpenAI-compatible endpoint works. |

**What to validate:**
- Can NeMo Guardrails with `engine: openai` point at a Llama Stack endpoint? (Should work — both speak OpenAI chat completions format)
- Does the Guardrails Orchestrator CRD cover the same use cases as NeMo? (Different model — detectors vs conversational rails)
- What's the quality delta between GPT-4o-mini and a self-hosted Llama/Granite model for safety self-checks?

**Workaround:** Use `engine: openai` with GPT-4o-mini (works with the RHOAI image). Or `engine: openai` pointed at any OpenAI-compatible endpoint (vLLM, Llama Stack, LiteLLM).

### 8. NeMo Guardrails only accepts OpenAI format — can't guard Anthropic Messages API traffic :no_entry:

**Priority rank: NEW**

**Symptom:** An agent configured to use Anthropic's built-in provider (e.g., OpenClaw with `claude-sonnet-4-20250514 · anthropic` selected) sends requests using the Anthropic Messages API format (`POST /v1/messages`). NeMo Guardrails can't intercept or proxy these requests — it only accepts OpenAI chat completions format (`POST /v1/chat/completions`).

**The distinction that causes confusion:**

NeMo has two separate concepts that both involve "Anthropic":

| Concept | What it means | Works? |
|---------|--------------|--------|
| `engine: anthropic` in NeMo config | NeMo *calls* Anthropic to evaluate safety rails (internal, outbound) | Yes (if `langchain-anthropic` is installed) |
| Receiving Anthropic Messages format requests | NeMo *accepts* requests from agents using Anthropic wire protocol (inbound) | No — not supported |

`engine: anthropic` means NeMo can use Claude as its internal LLM for checking rails. It does NOT mean NeMo can sit in front of an agent that speaks Anthropic Messages API.

**Why this matters:**

If an enterprise deploys agents that use Anthropic directly (common — Claude is a top-tier model), there's no way to put NeMo Guardrails in front of them without changing the agent's provider configuration. The agent must be rewired to send OpenAI format to a guardrails proxy, which then calls whatever backend it wants.

```
DOESN'T WORK:
Agent ──Anthropic Messages format──▶ NeMo ──▶ Anthropic API
       POST /v1/messages              ✗ NeMo doesn't have this endpoint

WORKS (but requires agent config change):
Agent ──OpenAI format──▶ Adapter ──▶ NeMo ──engine:anthropic──▶ Anthropic API
       POST /v1/chat/completions            (internal, via LangChain)
```

**What would fix this:**

| Option | Owner | Effort |
|--------|-------|--------|
| NeMo adds `/v1/messages` endpoint | NeMo upstream | High — needs full Anthropic protocol support (streaming SSE format differs, `content` blocks, `max_tokens` required) |
| Adapter translates Anthropic ↔ OpenAI bidirectionally | Us / platform team | Medium — adapter detects format, converts both directions |
| Agent frameworks support guardrails proxy config | Agent upstream (OpenClaw, etc.) | Medium — `proxyUrl` per provider that routes traffic through a proxy |

**Current workaround:** Configure the agent to use a custom `guardrails-proxy` provider with `api: openai-completions` instead of the built-in Anthropic provider. This means the agent talks OpenAI format to the proxy, and NeMo handles the rest. The agent's users can't select the built-in Anthropic model from the UI — they must use the guardrails-wrapped model.

## Dead Ends

### 6. `NemoGuardrail` CRD doesn't support custom commands :no_entry:

**Symptom:** Cannot use the `NemoGuardrail` CRD from the NIM Operator to deploy with `langchain-anthropic` because the CRD doesn't allow command overrides.

**Root cause:** The `NemoGuardrail` CR manages the pod lifecycle but doesn't expose a `command` or `args` field. There's no way to inject `pip install langchain-anthropic` at startup.

**Workaround:** Deployed as a standalone Deployment instead of using the CRD. This gives full control over the container command.

**What should be fixed:** The `NemoGuardrail` CRD should support init containers, command overrides, or an `extraPackages` field for installing additional Python packages.

## Path to TrustyAI Service Operator (CRD-based deployment)

The `NemoGuardrail` CRD (`nemoguardrails.trustyai.opendatahub.io`) exists on RHOAI 3.3+ clusters and is managed by the TrustyAI Service Operator. Using it instead of our standalone Deployment would be the "proper" RHOAI-native path. Here's what's blocking it and who needs to fix what.

### What needs to happen

| Step | Owner | What | Why |
|------|-------|------|-----|
| 1 | **TrustyAI team** | Add `langchain-anthropic` to the RHOAI NeMo image | Image ships `langchain-openai` only. Using Anthropic as the guardrails LLM engine crashes at startup. |
| 2 | **NeMo upstream** | Fix `get_colang_history()` to handle list content | One-line fix: `if isinstance(content, list): content = " ".join(...)` before `.rsplit()`. Affects anyone sending OpenAI multi-part format. |
| 3 | **NeMo upstream** | Return OpenAI-compatible response format from `/v1/chat/completions` | Currently returns `{"messages": [...]}` instead of `{"choices": [...]}`. Every OpenAI-compatible client breaks. |
| 4 | **NeMo upstream** | Support `stream: true` parameter | Modern LLM clients default to streaming. NeMo ignores the flag and returns a single JSON blob, causing timeouts and broken pipes. |
| 5 | **TrustyAI team** | Add sidecar/init container support to `NemoGuardrail` CRD | Escape hatch: if upstream NeMo fixes take time, the CRD should allow injecting an adapter sidecar or running pip install via init container. |

### What works today with the CRD (without Anthropic)

If you use a **self-hosted model via vLLM** instead of Anthropic, you can skip step 1:

```yaml
apiVersion: trustyai.opendatahub.io/v1alpha1
kind: NemoGuardrail
metadata:
  name: openclaw-guardrails
  namespace: openclaw
spec:
  image: quay.io/trustyai/nemo-guardrails-server:latest
  config:
    configMapName: openclaw-guardrails-config
  model:
    engine: openai
    apiBase: http://your-vllm-svc.namespace.svc.cluster.local:8000/v1
    model: your-model-name
```

But you still need the adapter sidecar (steps 2-4), and the CRD doesn't support adding one (step 5). So the CRD path is blocked until either NeMo fixes 2-4 or TrustyAI adds step 5.

### When the CRD path will work

Once steps 1-4 are fixed upstream, the deployment simplifies from our current 3-manifest setup (ConfigMap + 2-container Deployment + Service) to a single `NemoGuardrail` CR. The adapter sidecar becomes unnecessary, and the TrustyAI operator manages the lifecycle.

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
