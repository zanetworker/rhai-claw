# kagenti-claw

**No matter where your agent comes from, the platform is your agent's safe haven.**

OpenClaw, ZeroClaw, a custom LangGraph agent, a CrewAI crew, something you built last weekend with Claude Code — the platform doesn't care. You build the agent. The platform brings identity, observability, tool governance, and lifecycle management. Your agent's code stays untouched.

This repo is the companion to [Operationalizing "Bring Your Own Agent" on Red Hat AI, the OpenClaw edition](https://www.redhat.com/en/blog/operationalizing-bring-your-own-agent-red-hat-ai-openclaw-edition). It takes [OpenClaw](https://github.com/openclaw/openclaw) — a personal AI assistant that routes agent interactions across channels (WhatsApp, Telegram, Slack, Discord) — and operationalizes it on Kubernetes with [Kagenti](https://github.com/kagenti/kagenti-operator). OpenClaw is the example. The pattern works for any agent runtime.

## Table of Contents

- [The BYOA Principle](#the-byoa-principle)
- [Quick Start](#quick-start)
- [What Gets Deployed](#what-gets-deployed)
- [After Deployment](#after-deployment)
- [How the AgentCard Gets Its Data](#how-the-agentcard-gets-its-data)
- [Configuration](#configuration)
- [NeMo Guardrails Integration](#nemo-guardrails-integration)
- [Gotchas by Team](#gotchas-by-team)
- [AgentRuntime Controller](#agentruntime-controller)
- [Webhook Changes (not yet upstream)](#webhook-changes-not-yet-upstream)
- [Related Projects](#related-projects)

## The BYOA Principle

One agent, one pod. The developer deploys a standard container. The platform wraps it in infrastructure.

| You bring | The platform adds |
|-----------|-------------------|
| Your agent container (any framework, any runtime) | **Discovery** — AgentCard CR auto-indexes your agent via A2A |
| Your LLM provider keys | **Observability** — OTEL traces to MLflow for every LLM call |
| Your tools and MCP servers | **Identity** — SPIFFE/SPIRE workload identity (planned) |
| | **Tool governance** — MCP Gateway with identity-based filtering (planned) |
| | **Safety** — Guardrails Orchestrator at the inference boundary (planned) |
| | **Lifecycle** — AgentRuntime CR manages labels, config, rolling updates |

The platform is framework-agnostic. It doesn't ask you to rewrite your agent or adopt a specific SDK. It wraps your workload in enterprise infrastructure — the same way OpenShift wraps any container in networking, storage, and security without modifying the application.

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
- An **Anthropic API key** — the skill asks you to create a Secret (never asks for the key directly)

**With cluster-admin:**
- `helm` v4+ installed locally (Helm v3.x does not support OCI charts)
- The skill installs everything: operator, CRDs, webhook, namespace

**Without cluster-admin:**
- Ask your platform team to pre-install the Kagenti operator, CRDs, webhook, and create your namespace with `kagenti-enabled=true` label
- The skill detects what's missing and tells you exactly what to ask for
- Once the platform prerequisites are in place, the skill handles everything else with namespace-scoped permissions

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

## NeMo Guardrails Integration

OpenClaw routes all LLM calls through [NVIDIA NeMo Guardrails](https://github.com/NVIDIA-NeMo/Guardrails) for enterprise safety enforcement. The guardrails sit as a proxy between OpenClaw and the LLM, applying input/output rails on every request.

```
User ──▶ OpenClaw ──▶ OpenAI Adapter ──▶ NeMo Guardrails ──▶ Anthropic API
                      (format bridge)    (Colang v1 rails)    (actual LLM)
```

**What gets blocked:**
- Profanity, hate speech, NSFW content
- Environment variable / API key extraction attempts
- Data exfiltration to external endpoints
- Bulk data download requests
- Access to sensitive system files

**What gets allowed:**
- Normal conversation, greetings, questions
- Todo items, notes, memory updates
- Conference schedule queries
- Drafting emails, brainstorming

The guardrails deployment consists of three pieces:

| Manifest | What it does |
|----------|-------------|
| `manifests/guardrails-config.yaml` | ConfigMap with `config.yaml` (model, rails, self-check prompts) + `rails.co` (Colang v1 flow definitions) |
| `manifests/guardrails-deployment.yaml` | Two-container pod: NeMo Guardrails server + OpenAI format adapter sidecar |
| `manifests/guardrails-service.yaml` | ClusterIP Service (port 80 → adapter on 8080) |

OpenClaw connects to the guardrails proxy via a custom model provider in `openclaw.json`:

```json
{
  "models": {
    "providers": {
      "guardrails-proxy": {
        "baseUrl": "http://openclaw-guardrails.<NAMESPACE>.svc.cluster.local/v1",
        "api": "openai-completions",
        "models": [{"id": "claude-sonnet-4-20250514", "name": "Claude via Guardrails"}]
      }
    }
  },
  "agents": {
    "defaults": {
      "model": {"primary": "guardrails-proxy/claude-sonnet-4-20250514"}
    }
  }
}
```

## Gotchas by Team

We hit 35 gotchas deploying OpenClaw with Kagenti, NeMo Guardrails, sandboxed containers, and MLflow tracing. The `/deploy-openclaw` skill handles most of them automatically. Each team has its own section with impact and status:

**[docs/gotchas.md](docs/gotchas.md)** — the full index with tables per team:

| Team | Owner | Count | Details |
|------|-------|-------|---------|
| [OpenClaw / Agent](docs/gotchas.md#openclaw--agent-team) | OpenClaw upstream | 7 | Loopback binding, hardcoded port, token regen, broken OTEL extension, multi-part content |
| [Kagenti / Platform](docs/gotchas.md#kagenti--platform-team) | Kagenti operator + extensions | 9 + [onboarding feedback](docs/gotchas-kagenti-onboarding.md) | Namespace labels, AgentCard sync, trace injection, CRD lifecycle, webhook friction, lean mode |
| [TrustyAI / Safety](docs/gotchas.md#trustyai--safety-team) | TrustyAI operator + NeMo in RHOAI | 6 | Response format, list content crash, streaming, missing packages, CRD path blocked |
| [MLflow / Observability](docs/gotchas.md#mlflow--observability-team) | MLflow operator + OTEL | 6 | HTTP vs GenAI traces, Host header, silent errors, latency attribution |
| [Sandboxed Containers / Security](docs/gotchas.md#openshift-sandboxed-containers--security-team) | Sandboxed containers operator | 7 | No nested virt on AWS, node reboots, AMI creation, SG ports, peer pods config |

Deep-dive docs per area:
- [docs/gotchas-application.md](docs/gotchas-application.md)
- [docs/gotchas-platform-kagenti.md](docs/gotchas-platform-kagenti.md) + [onboarding feedback](docs/gotchas-kagenti-onboarding.md)
- [docs/gotchas-nemo-guardrails.md](docs/gotchas-nemo-guardrails.md)
- [docs/gotchas-mlflow-tracing.md](docs/gotchas-mlflow-tracing.md)
- [docs/gotchas-sandboxed-containers.md](docs/gotchas-sandboxed-containers.md)

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
