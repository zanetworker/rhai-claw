# MLflow Tracing Gotchas

Issues encountered setting up OTEL tracing from OpenClaw to MLflow. The current setup produces HTTP-level traces. This doc explains what's missing for full GenAI-level traces and what needs to happen.

## Severity

| Rating | Icon | Meaning |
|--------|------|---------|
| **Dead end** | :no_entry: | No workaround on this path. Must change approach. |
| **Surprising** | :warning: | Not obvious from docs. Costs hours of debugging. |
| **Obvious** | :bulb: | Expected if you know the tech. |

## Current State: HTTP-Level Traces Only :no_entry:

The OTEL preload script (`manifests/otel-tracing-configmap.yaml`) monkey-patches `globalThis.fetch` in Node.js to intercept outgoing HTTP calls to LLM providers. It creates spans with:

| What you get | Attribute |
|-------------|-----------|
| Provider | `gen_ai.system` ("anthropic", "openai", etc.) |
| URL | `http.url` |
| Method | `http.method` |
| Status | `http.response.status_code` |
| Latency | Span duration |
| Host | `server.address` |

| What you DON'T get | Why |
|--------------------|-----|
| Prompt text | Can't read request body without breaking streaming |
| Completion text | Can't tee ReadableStream (locks it, breaks chat) |
| Token counts | In the response body which we can't read |
| Model name | In the request body which we don't parse |
| Tool calls | Application-level, not visible at HTTP layer |
| Conversation ID | Application-level context |

## What GenAI Traces Should Look Like

The [OpenTelemetry GenAI Semantic Conventions](https://opentelemetry.io/docs/specs/semconv/gen-ai/gen-ai-spans/) (v1.37+) define the standard:

**Span attributes (on every LLM call span):**
```
gen_ai.system = "anthropic"
gen_ai.request.model = "claude-sonnet-4-20250514"
gen_ai.request.max_tokens = 4096
gen_ai.request.temperature = 0.7
gen_ai.response.model = "claude-sonnet-4-20250514"
gen_ai.response.finish_reasons = ["stop"]
gen_ai.usage.input_tokens = 1523
gen_ai.usage.output_tokens = 487
```

**Events (opt-in, attached to the span):**
```
Event: gen_ai.user.message
  gen_ai.prompt = "What sessions are at the conference today?"

Event: gen_ai.assistant.message
  gen_ai.completion = "Here are today's sessions..."
```

**MLflow maps these** via its [OTLP attribute mapping](https://mlflow.org/docs/latest/genai/tracing/opentelemetry/attribute-mapping) to render rich trace views: prompt/completion pairs, token usage charts, model cost tracking, and tool call trees.

## Why We Can't Get GenAI Traces from HTTP Interception

The OTEL preload script intercepts `fetch()` calls at the HTTP transport layer. To get GenAI attributes, you'd need to:

1. **Parse the request body** to extract `model`, `max_tokens`, `messages` — possible for non-streaming, but the Anthropic SDK uses streaming by default
2. **Read the response body** to extract `content`, `usage.input_tokens`, `usage.output_tokens` — this requires teeing the `ReadableStream`

The problem with teeing:
```javascript
// This breaks OpenClaw:
const [stream1, stream2] = response.body.tee();
// stream1 → read for tracing
// stream2 → return to caller
// ERROR: "ReadableStream is locked" — the SDK expects an unlocked stream
```

The Anthropic SDK reads the stream incrementally for token-by-token display. Once you tee it, the original stream reference is consumed, and the SDK throws.

## Three Paths to GenAI Traces

### Path 1: OpenClaw's Built-in `diagnostics-otel` Extension (Broken)

OpenClaw has a `diagnostics-otel` extension that's designed for exactly this. It hooks into OpenClaw's internal agent lifecycle (after parsing, before/after LLM calls) and emits structured spans with prompt, completion, token counts, and tool calls.

**Status:** Broken. The extension's `index.js` is missing from the container image build. OpenClaw logs show:
```
[plugins] extension entry escapes package directory: ./index.js (source=/app/dist/extensions/diffs)
```

**What needs to happen:**
- Fix the OpenClaw container image build to include the `diagnostics-otel` extension
- Or mount the extension JS files via ConfigMap and configure OpenClaw to load them
- The extension would need to emit spans following the [OTEL GenAI semantic conventions](https://opentelemetry.io/docs/specs/semconv/gen-ai/gen-ai-spans/) for MLflow to render them correctly

**Effort:** Medium — need to fix the image build or find the extension source

### Path 2: Application-Level SDK Instrumentation

Use the Anthropic SDK's built-in OTEL support or a library like [OpenLLMetry](https://github.com/traceloop/openllmetry) that wraps LLM SDK calls:

**For Python agents** (not OpenClaw, but relevant for other BYOA agents):
```python
from opentelemetry.instrumentation.anthropic import AnthropicInstrumentor
AnthropicInstrumentor().instrument()
```

**For Node.js** (OpenClaw's runtime):
```javascript
// OpenLLMetry has a Node.js SDK
const { Traceloop } = require("@traceloop/node-server-sdk");
Traceloop.init({ exporter: otlpExporter });
```

**What needs to happen:**
- Add `@traceloop/node-server-sdk` to OpenClaw's dependencies (or install at startup)
- Initialize before the Anthropic SDK is loaded
- Requires OpenClaw image modification or a custom preload script

**Effort:** Medium — needs package installation and preload ordering

### Path 3: NeMo Guardrails Adapter Tracing (Simplest for Demo)

Since all LLM calls now flow through our OpenAI adapter sidecar, we can add GenAI span attributes there. The adapter sees both the request and response in full (non-streaming, since NeMo doesn't stream).

**What needs to happen:**
Add to the adapter's `do_POST`:
```python
# Before forwarding to NeMo:
model = req_json.get("model", "unknown")
messages = req_json.get("messages", [])
last_user_msg = next((m["content"] for m in reversed(messages) if m["role"] == "user"), "")

# After getting NeMo's response:
span_attrs = {
    "gen_ai.system": "anthropic",
    "gen_ai.request.model": model,
    "gen_ai.usage.input_tokens": 0,  # NeMo doesn't return usage
    "gen_ai.usage.output_tokens": 0,
    "gen_ai.response.finish_reasons": '["stop"]',
}
# Emit span via OTEL SDK
```

The adapter would need the OTEL Python SDK installed (`opentelemetry-sdk`, `opentelemetry-exporter-otlp`), adding ~20s to startup and 30MB to the container.

**Limitation:** NeMo Guardrails doesn't return token usage in its response, so `gen_ai.usage.*` would be zero. You'd get model name, prompt, completion, and latency — but not token counts.

**Effort:** Low — modify the adapter, add pip install

## MLflow-Specific Gotchas

### 1. MLflow rejects OTLP with port in Host header :warning:

MLflow 3.x has DNS rebinding protection. The OTEL SDK sends `Host: mlflow-service.test.svc.cluster.local:5000` but MLflow's `--allowed-hosts` list only had the hostname without port. Every trace was silently rejected (400).

**Fix:** Add `hostname:port` to MLflow's `ALLOWED_HOSTS`.

### 2. OTEL export errors are silent :warning:

The Node.js OTEL SDK's `OTLPTraceExporter` swallows HTTP errors by default. When MLflow rejects traces (400, 403, etc.), no error appears in OpenClaw's logs. You only discover the problem by curling MLflow's `/v1/traces` endpoint directly.

**Fix:** Set `OTEL_LOG_LEVEL=debug` to see exporter errors, or check MLflow's access logs.

### 3. MLflow experiment ID must be passed as header :bulb:

MLflow's OTLP endpoint routes traces to experiments via the `x-mlflow-experiment-id` header. Without it, traces go to experiment "0" (default). The preload script passes this header, but if you use a different exporter or collector, you need to configure it.

### 4. No OTEL Collector — direct export only :bulb:

The current setup exports traces directly from the OpenClaw pod to MLflow's `/v1/traces` endpoint. There's no OTEL Collector in between. This means:
- No batching (each span is exported individually)
- No retry on failure
- No trace sampling control
- No fan-out to multiple backends

For production, deploy an OTEL Collector as a sidecar or cluster service that batches, retries, and routes traces.

### 5. Guardrails latency appears as LLM latency :bulb:

With NeMo Guardrails in the path, each "LLM call" in the trace includes the guardrails processing time (5 rail checks + actual LLM call). A single user message generates ~5 spans: the self-check input call, canonical form call, LLM generation call, self-check output call, plus the top-level call. Total latency is 10-20s, which looks like a very slow LLM but is actually the guardrails pipeline.

**What to consider:** If you add GenAI tracing in the adapter (Path 3), clearly label spans as `guardrails.pipeline` vs `llm.call` so the MLflow view distinguishes guardrails overhead from actual inference latency.

## Recommended Next Steps

1. **Short term (demo):** Use Path 3 — add basic GenAI attributes to the adapter. Gets model name, prompt, completion into MLflow. No token counts.
2. **Medium term:** Fix OpenClaw's `diagnostics-otel` extension or add OpenLLMetry. Gets full GenAI traces with token counts.
3. **Long term:** Deploy OTEL Collector, configure sampling, add dashboards for cost/latency tracking per model.
