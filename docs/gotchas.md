# Gotchas by Team

Everything below was discovered deploying OpenClaw with Kagenti, NeMo Guardrails, and MLflow tracing. The `/deploy-openclaw` skill handles all of them automatically — these are documented so each team knows what to fix upstream.

## OpenClaw / Agent Team

Owner: OpenClaw upstream

| Gotcha | Impact | Status |
|--------|--------|--------|
| Binds to loopback by default | Agent unreachable in K8s — Service health checks fail silently | Workaround: `openclaw config set gateway.bind lan` in init container |
| Hardcoded port 18789 | `PORT` env var ignored, breaks standard container conventions | Workaround: match all manifests to 18789 |
| Gateway token regenerates on every restart | Dashboard needs re-pairing after every pod restart | Workaround: `make token` + `make approve-pairing` |
| Device pairing required after reconnect | UX friction for every browser session | Workaround: auto-approve in skill |
| Browser automation broken in container | Chrome binary missing from image, `openclaw browser status` shows `unknown` | No fix — needs Chromium in image or remote browser sidecar |
| `diagnostics-otel` extension broken | `index.js` missing from image build, no GenAI-level traces | No fix — blocks Path 1 for GenAI observability |
| Multi-part content format (`content: [...]`) | Breaks downstream tools that expect `content: "string"` | Workaround: adapter normalizes before forwarding |

Full details: [gotchas-application.md](gotchas-application.md)

## Kagenti / Platform Team

Owner: Kagenti operator + kagenti-extensions

| Gotcha | Impact | Status |
|--------|--------|--------|
| Namespace needs `kagenti-enabled=true` label | Webhook never fires — silent failure, no errors anywhere | Workaround: skill labels namespace automatically |
| AgentCard `SYNCED=False` for non-A2A agents | No discovery for agents that don't serve `/.well-known/agent-card.json` | Workaround: ConfigMap fetcher with `{name}-card-signed` convention |
| `spec.trace` doesn't inject OTEL env vars | AgentRuntime CR has trace config but pods get no env vars | Fix: patched webhook in fork ([`zanetworker/kagenti-extensions@0048067`](https://github.com/zanetworker/kagenti-extensions/commit/0048067)) |
| Webhook early return bypasses trace injection | When all sidecars disabled, `AnyInjected()` returns false before trace code runs | Fix: patched in same fork |
| Deployment name mismatch in webhook | Pod's `GenerateName` is ReplicaSet name, not Deployment name — AgentRuntime lookup fails | Fix: strip `pod-template-hash` suffix |
| AgentRuntime CRD not in Helm chart | Must install CRD manually after Helm install | Needs Helm chart update |
| CRDs get stuck terminating | Blocks reinstallation until finalizers removed | Workaround: skill patches out finalizers |
| AgentCards CRD only from Helm first-install | Manual deletion requires full Helm reinstall to recover | Document: don't delete CRDs |
| Empty secrets cause silent failures | `$ANTHROPIC_API_KEY` unset creates empty secret, agent says "No API key" | Workaround: skill verifies secret content length |

Full details: [gotchas-platform.md](gotchas-platform.md)

## TrustyAI / Safety Team

Owner: TrustyAI operator + NeMo Guardrails integration in RHOAI

| Gotcha | Impact | Status |
|--------|--------|--------|
| NeMo response format is not OpenAI-compatible | Clients expecting `{"choices": [...]}` get `{"messages": [...]}` — empty responses | Workaround: OpenAI adapter sidecar transforms format |
| `get_colang_history()` crashes on list content | Multi-part `content: [{"type":"text","text":"..."}]` causes `TypeError: must be str or None, not list` | Workaround: adapter normalizes list to string. **Upstream fix needed in NeMo** |
| No streaming support in NeMo server | Clients sending `stream: true` get no SSE — connection hangs or breaks | Workaround: adapter strips stream flag, converts response to SSE |
| RHOAI image missing `langchain-anthropic` | NeMo can't use Anthropic as guardrails LLM engine | Workaround: `pip install` at pod startup (+15s) |
| Self-check prompt too sensitive to metadata | OpenClaw's internal metadata (component names, timestamps) triggers false safety violations | Workaround: tuned prompt to explicitly ignore system metadata |
| `NemoGuardrail` CRD doesn't support command overrides | Can't use CRD path because no way to pip install missing packages | Workaround: standalone Deployment instead of CRD |

Full details: [gotchas-nemo-guardrails.md](gotchas-nemo-guardrails.md)

## MLflow / Observability Team

Owner: MLflow operator + OTEL integration

| Gotcha | Impact | Status |
|--------|--------|--------|
| Traces are HTTP-level only, not GenAI-level | No prompt text, completion text, token counts, or tool calls in traces | See [3 paths to GenAI traces](gotchas-mlflow-tracing.md#three-paths-to-genai-traces) |
| MLflow rejects OTLP with port in Host header | DNS rebinding protection blocks traces when port included in hostname | Fix: add `hostname:port` to MLflow `ALLOWED_HOSTS` |
| OTEL export errors are silent | 400/403 from MLflow never logged — traces silently dropped | Workaround: set `OTEL_LOG_LEVEL=debug` |
| No OTEL Collector — direct export | No batching, retry, sampling, or fan-out | Need: deploy Collector as sidecar or cluster service |
| Guardrails latency appears as LLM latency | 5 guardrails LLM calls per request inflate apparent inference time to 10-20s | Need: separate span labels for guardrails vs inference |
| Experiment ID must be header | Traces go to experiment "0" without `x-mlflow-experiment-id` header | Workaround: preload script sets header |

Full details: [gotchas-mlflow-tracing.md](gotchas-mlflow-tracing.md)
