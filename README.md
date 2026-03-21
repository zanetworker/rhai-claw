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

The skill walks through everything — operator, webhook, manifests, API keys, tracing, pairing. It asks for input only when it can't automate (e.g., your Anthropic API key if no Secret exists).

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
| **Webhook** | The [kagenti-extensions](https://github.com/kagenti/kagenti-extensions) admission webhook intercepts Pod CREATE events and injects sidecars (SPIFFE, Envoy), env vars (OTEL), and volumes based on the AgentRuntime CR spec. Requires `kagenti-enabled=true` label on the namespace. |

## After Deployment

Your cluster has a fully managed, discoverable AI agent:

```
$ kubectl get agentruntimes -n openclaw
NAME       TYPE    TARGET     PHASE    AGE
openclaw   agent   openclaw   Active   2m
```

```
$ kubectl get agentcards -n openclaw
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
  namespace: openclaw
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

## Configuration

| Variable | Default | What it does |
|----------|---------|-------------|
| `NAMESPACE` | `openclaw` | Where OpenClaw lands (the skill asks you to choose) |
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

## Claude Code Skill

Run `/deploy-openclaw` for full automated deployment: operator, webhook, CRDs, RBAC, namespace setup, manifests, API keys, A2A agent card, OTEL tracing, route, token, and device pairing.

## Connecting to the Dashboard

After `make deploy`, open the printed dashboard URL. Paste the gateway token, click Connect, then run `make approve-pairing` to authorize the session.

## Prerequisites

**Required:**
- A Kubernetes cluster (v1.28+) — OpenShift for Route support, or bring your own Ingress
- `kubectl` configured and connected to the cluster
- `helm` v4+ installed locally (Helm v3.x does not support OCI charts)
- An **Anthropic API key** — the `/deploy-openclaw` skill will ask for it and create a Secret. If you already have a Secret named `llm-keys` with an `anthropic` key in the `agents` namespace, it will be used automatically

**Optional (for full observability):**
- **MLflow** deployed on the cluster — the OTEL preload script sends traces to MLflow. If MLflow is not present, OpenClaw still works but without tracing. MLflow's `--allowed-hosts` must include the service hostname with port (e.g., `mlflow-service.test.svc.cluster.local:5000`)

**Assumptions the skill handles for you:**
- Asks you to choose a namespace (default: `openclaw`) — does not reuse existing namespaces with other workloads
- Detects stale resources from previous deployments and offers cleanup
- Creates the namespace and labels it with `kagenti-enabled=true` for the webhook
- Installs the Kagenti operator via Helm if not present
- Installs the AgentRuntime CRD if not in the cluster
- Deploys the webhook from bundled manifests (no Helm or clone needed)
- Detects MLflow on the cluster and configures OTEL tracing automatically (or skips if not found)
- Configures `AgentRuntime.spec.trace` dynamically based on detected MLflow endpoint
- Creates the OTEL preload ConfigMap and A2A agent card ConfigMap
- Asks you to create the API key Secret yourself (never asks for the key directly) and verifies it exists before continuing
- Patches the Deployment with the API key reference and OTEL env vars
- Retrieves the gateway token and approves device pairing

## FYI: Gotchas

Things we hit deploying OpenClaw on Kagenti. The `/deploy-openclaw` skill handles all of them automatically — these are documented for understanding, not for manual steps.

- [**Application gotchas**](docs/gotchas-application.md) — OpenClaw-specific: loopback binding, non-standard port, token regeneration, device pairing, missing Chrome
- [**Platform gotchas**](docs/gotchas-platform.md) — Kagenti-specific: namespace labels, AgentCard sync, trace injection gaps, MLflow DNS rebinding, OTEL instrumentation level

## AgentRuntime Controller

The AgentRuntime CRD and controller were added in [`kagenti-operator#218`](https://github.com/kagenti/kagenti-operator/pull/218) (merged to main, commit [`019ef44`](https://github.com/kagenti/kagenti-operator/commit/019ef44)). The CRD is not yet included in the Helm chart — it must be installed manually from the repo:

```bash
kubectl apply -f https://raw.githubusercontent.com/kagenti/kagenti-operator/main/kagenti-operator/config/crd/bases/agent.kagenti.dev_agentruntimes.yaml
```

## Webhook Changes (not yet upstream)

The released webhook image (`ghcr.io/kagenti/kagenti-extensions/kagenti-webhook:0.4.0-alpha.9`) reads `spec.trace` from the AgentRuntime CR but doesn't inject OTEL env vars into the agent container. We patched three files in [kagenti-extensions](https://github.com/kagenti/kagenti-extensions) to close this gap:

| File | Change |
|------|--------|
| `container_builder.go` | Added `BuildTraceEnv()` — converts `ResolvedConfig.TraceEndpoint/Protocol/SamplingRate` into `OTEL_EXPORTER_OTLP_ENDPOINT`, `OTEL_EXPORTER_OTLP_PROTOCOL`, `OTEL_TRACES_SAMPLER`, `OTEL_TRACES_SAMPLER_ARG` env vars |
| `pod_mutator.go` | Calls `BuildTraceEnv()` and injects env vars into `podSpec.Containers[0]` via `appendEnvVarsIfAbsent()`. Also fixes early return when all sidecars are disabled (trace injection still needed) and resolves Deployment name from ReplicaSet name by stripping `pod-template-hash` |
| `container_builder_test.go` | 4 tests covering: endpoint+protocol+rate, no endpoint, endpoint-only, and `appendEnvVarsIfAbsent` preserving existing values |

The changes are in a fork: [`zanetworker/kagenti-extensions@0048067`](https://github.com/zanetworker/kagenti-extensions/commit/0048067) on the [`feat/trace-env-injection`](https://github.com/zanetworker/kagenti-extensions/tree/feat/trace-env-injection) branch.

The patched image is at `quay.io/azaalouk/kagenti-webhook:trace-injection`. To use the upstream image instead, you lose OTEL env var injection from `spec.trace` — the OTEL preload script in `manifests/otel-tracing-configmap.yaml` still works independently.

## Related Projects

- [**Kagenti Operator**](https://github.com/kagenti/kagenti-operator) — Agent lifecycle management, discovery, and identity for Kubernetes
- [**kagenti-a2a-adapter**](https://github.com/zanetworker/kagenti-a2a-adapter) — Generate A2A protocol wrappers for non-A2A agents (CrewAI, LangGraph, OpenAI Agents SDK)
- [**OpenClaw**](https://quay.io/repository/aicatalyst/openclaw) — Multi-channel AI gateway with extensible messaging integrations
- [**BYOA Blog Series**](https://www.redhat.com/en/blog/operationalizing-bring-your-own-agent-red-hat-ai-openclaw-edition) — The full walkthrough of operationalizing agents on Red Hat AI

## License

[Apache 2.0](LICENSE)
