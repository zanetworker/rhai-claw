# kagenti-claw

**Bring Your Own Agent. We bring the platform.**

The AI agent world is messy. Teams reach for LangChain, CrewAI, AutoGen, or build from scratch. Good. That's the creative phase. But once an agent leaves a developer's laptop and starts talking to production data, calling external APIs, or running on shared infrastructure, freedom without guardrails stops being a feature and starts being a liability.

This repo is the companion to [Operationalizing "Bring Your Own Agent" on Red Hat AI, the OpenClaw edition](https://www.redhat.com/en/blog/operationalizing-bring-your-own-agent-red-hat-ai-openclaw-edition). It takes [OpenClaw](https://github.com/openclaw/openclaw), a personal AI assistant that routes agent interactions across channels (WhatsApp, Telegram, Slack, Discord) through a central WebSocket gateway, and operationalizes it on Kubernetes with [Kagenti](https://github.com/kagenti/kagenti-operator).

We aren't wrapping OpenClaw in a proprietary framework. We're wrapping it in platform infrastructure.

## The BYOA Principle

The platform is framework-agnostic. What matters is that the agent has identity, runs under least-privilege, gets observed, passes safety checks, and can be audited after the fact. The platform provides security, governance, observability, and lifecycle management. The agent stays yours.

OpenClaw doesn't sandbox by default. It doesn't enforce RBAC, trace tool calls, or gate access to external services. Kagenti and Red Hat AI add each of those layers without touching the agent's code.

## Quick Start

```bash
git clone https://github.com/zanetworker/kagenti-claw.git
cd kagenti-claw
make deploy
```

One command. The output gives you your dashboard URL and gateway token.

Using Claude Code? Even simpler:

```bash
/deploy-openclaw
```

## What Gets Deployed

```
┌─────────────────────────────────────────────────────────────┐
│                      Your Cluster                            │
│                                                              │
│  ┌────────────────┐           ┌───────────────────────────┐  │
│  │    Kagenti     │  watches  │      OpenClaw Agent        │  │
│  │    Operator    │──────────▶│   (Deployment + Service)   │  │
│  │                │           │   Port 18789 (WebSocket)   │  │
│  └───────┬────────┘           └─────────────┬─────────────┘  │
│          │ creates                          │                 │
│  ┌───────▼────────┐           ┌─────────────▼─────────────┐  │
│  │  AgentRuntime  │           │   Route (TLS edge, 300s)  │  │
│  │  (lifecycle)   │           │   ───▶ Dashboard URL       │  │
│  └───────┬────────┘           └───────────────────────────┘  │
│          │                                                    │
│  ┌───────▼────────┐           ┌───────────────────────────┐  │
│  │   AgentCard    │◀──────────│  ConfigMap (A2A schema)   │  │
│  │  (discovery)   │  reads    │  openclaw-card-signed      │  │
│  └────────────────┘           └───────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

Three Kagenti primitives manage the agent's lifecycle:

| Primitive | What it does |
|-----------|-------------|
| **AgentRuntime** | Attaches to an existing Deployment or StatefulSet. Applies labels, config hashes, and tracks pod readiness. The agent code is untouched. |
| **AgentCard** | Discovers agent metadata via the A2A protocol. Supports HTTP fetch or ConfigMap-based injection for agents that don't natively serve `/.well-known/agent-card.json`. |
| **ConfigMap (agent card)** | A static A2A agent card injected as `{agentName}-card-signed`. The Kagenti `ConfigMapFetcher` reads this before trying HTTP. No sidecar or image rebuild needed. |

## After Deployment

Your cluster has a fully managed, discoverable AI agent:

```
$ kubectl get agentruntimes -n agents
NAME       TYPE    TARGET     PHASE    AGE
openclaw   agent   openclaw   Active   2m
```

```
$ kubectl get agentcards -n agents
NAME                       PROTOCOL   KIND         TARGET     VERIFIED   BOUND   SYNCED   AGE
openclaw-deployment-card   a2a        Deployment   openclaw                      True     2m
```

The AgentCard shows `SYNCED=True` because the operator found the `openclaw-card-signed` ConfigMap and loaded the A2A agent card schema from it. No HTTP endpoint was needed.

## How the AgentCard Gets Its Data

Agents that speak A2A natively serve `/.well-known/agent-card.json` over HTTP. OpenClaw doesn't. Instead of building a sidecar or adapter, we use the Kagenti operator's **ConfigMap fetcher**.

The `ConfigMapFetcher` in the Kagenti operator checks for a ConfigMap named `{agentName}-card-signed` with key `agent-card.json` in the agent's namespace **before** falling back to HTTP. This means:

1. **No image rebuild** — the agent image stays untouched
2. **No sidecar** — no extra container serving a static file
3. **No A2A adapter** — no protocol translation layer

You define the agent card as a ConfigMap:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: openclaw-card-signed    # Must be {serviceName}-card-signed
  namespace: agents
data:
  agent-card.json: |
    {
      "name": "OpenClaw",
      "description": "Multi-channel AI gateway with extensible messaging integrations",
      "version": "2026.3.14",
      "url": "https://openclaw-agents.apps.your-cluster.com",
      "capabilities": { "streaming": true, "pushNotifications": false },
      "defaultInputModes": ["text/plain"],
      "defaultOutputModes": ["text/plain"],
      "skills": [
        { "name": "chat", "description": "Conversational AI agent" },
        { "name": "web-browsing", "description": "Browse and extract from web pages" },
        { "name": "code-execution", "description": "Execute code and return results" }
      ]
    }
```

Apply it, and the AgentCard CR syncs automatically. This pattern works for any non-A2A agent.

## The Platform Layers (from the blog)

This repo covers the deployment and discovery layer. The [blog series](https://www.redhat.com/en/blog/operationalizing-bring-your-own-agent-red-hat-ai-openclaw-edition) covers the full stack:

| Layer | What it provides | Status |
|-------|-----------------|--------|
| **Isolation** | Sandboxed containers (Kata) for kernel-isolated agent sessions | Planned |
| **Identity** | SPIFFE/SPIRE workload identity, scoped service-account tokens | Planned (Kagenti) |
| **Lifecycle** | AgentRuntime + AgentCard CRDs for deploy, discover, observe | This repo |
| **Observability** | MLflow tracing (OTEL-compatible) for prompts, tool calls, token costs | Developer preview |
| **Safety** | Garak adversarial scanning, Guardrails Orchestrator, NeMo Guardrails | GA / Tech preview |
| **Tool governance** | MCP Gateway (Envoy-based) with identity-based tool filtering | Developer preview |
| **API surface** | OpenResponses-compatible runtime, vLLM chat completions | Available |

## Configuration

| Variable | Default | What it does |
|----------|---------|-------------|
| `NAMESPACE` | `agents` | Where OpenClaw lands |
| `IMAGE` | `quay.io/aicatalyst/openclaw:latest` | The agent image |
| `KAGENTI_VERSION` | `0.2.0-alpha.22` | Kagenti operator chart version |

```bash
make deploy NAMESPACE=my-agents IMAGE=quay.io/aicatalyst/openclaw:20260320-d0ed2c3
```

## Makefile Targets

| Command | What it does |
|---------|-------------|
| `make deploy` | Install operator + deploy OpenClaw + print credentials |
| `make teardown` | Remove everything cleanly |
| `make token` | Print the gateway token and dashboard URL |
| `make status` | Show pod, AgentRuntime, and AgentCard status |
| `make approve-pairing` | Approve pending dashboard device pairings |

## Claude Code Skills

| Skill | What it does |
|-------|-------------|
| `/deploy-openclaw` | Full automated deployment: operator, manifests, route, token, pairing |
| `/setup-agentcard` | Generate and deploy an A2A agent card ConfigMap for any agent |

## Connecting to the Dashboard

After `make deploy`, open the printed dashboard URL. Paste the gateway token, click Connect, then run `make approve-pairing` to authorize the session.

## Prerequisites

- A Kubernetes cluster (v1.28+) — OpenShift for Route support, or bring your own Ingress
- `kubectl` configured and connected
- `helm` v4+ (the Makefile installs the Kagenti operator for you)

## Gotchas

Things we hit deploying OpenClaw on Kagenti. Read these before filing bugs.

**Application concerns (agent-side)**

- **OpenClaw binds to loopback by default.** It listens on `127.0.0.1:18789`, not `0.0.0.0`. The Kubernetes Service can't reach it. The init container runs `openclaw config set gateway.bind lan` to fix this. Any agent you deploy must listen on `0.0.0.0` on its declared port — this is the agent's responsibility, not the platform's.
- **OpenClaw uses port 18789, not 8000.** The gateway WebSocket port is non-standard. The Service and Route must target 18789.
- **Gateway token regenerates on every pod restart.** OpenClaw stores its auth token in the ephemeral `emptyDir` volume. New pod = new token. Run `make token` after restarts.
- **Device pairing required after every reconnect.** The Control UI requires device pairing approval. Run `make approve-pairing` after connecting.
- **Browser automation fails — no Chrome in the image.** The `quay.io/aicatalyst/openclaw:latest` image doesn't ship Chromium. Browser tool calls return "can't use browser automation in this environment."
- **Env var refusal is the LLM, not the platform.** When asked "show me your env vars," GPT-4o refuses for "privacy reasons." This is model-level safety behavior, not platform enforcement. The tools are available — the model chooses not to use them.

**Platform concerns (Kagenti-side)**

- **Namespace needs `kagenti-enabled=true` label.** The webhook's `namespaceSelector` requires this label. Without it, the webhook is never called and injection silently doesn't happen. `kubectl label namespace agents kagenti-enabled=true`
- **AgentCard shows `SYNCED=False` for non-A2A agents.** OpenClaw doesn't serve `/.well-known/agent-card.json`. Create a ConfigMap named `{serviceName}-card-signed` with key `agent-card.json` to provide the agent card data. The operator's `ConfigMapFetcher` reads it before trying HTTP.
- **AgentRuntime `spec.trace` doesn't inject env vars.** The operator includes it in the config hash (triggering a rollout) but doesn't set `OTEL_EXPORTER_OTLP_ENDPOINT` on the pod. The webhook has the plumbing (`ResolvedConfig.TraceEndpoint`) but doesn't emit env vars yet.
- **MLflow OTLP endpoint rejects requests with port in Host header.** The OTEL SDK sends `Host: mlflow-service.test.svc.cluster.local:5000`. MLflow's `--allowed-hosts` must include the `:5000` variant or it rejects with "DNS rebinding attack detected."
- **OTEL traces are HTTP-level, not GenAI-level.** Without application-level instrumentation, traces show URL/status/latency but not prompts, completions, or token counts. The agent needs to emit GenAI semantic convention spans for full observability.

## Related Projects

- [**Kagenti Operator**](https://github.com/kagenti/kagenti-operator) — Agent lifecycle management, discovery, and identity for Kubernetes
- [**kagenti-a2a-adapter**](https://github.com/zanetworker/kagenti-a2a-adapter) — Generate A2A protocol wrappers for non-A2A agents (CrewAI, LangGraph, OpenAI Agents SDK)
- [**OpenClaw**](https://quay.io/repository/aicatalyst/openclaw) — Multi-channel AI gateway with extensible messaging integrations
- [**BYOA Blog Series**](https://www.redhat.com/en/blog/operationalizing-bring-your-own-agent-red-hat-ai-openclaw-edition) — The full walkthrough of operationalizing agents on Red Hat AI

## License

[Apache 2.0](LICENSE)
