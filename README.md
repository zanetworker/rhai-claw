# kagenti-claw

**Every AI agent deserves a home. This is how you give it one.**

Deploying an AI agent on Kubernetes today is a mess. You wrestle with configs, debug networking, chase down auth tokens, and by the time it's running, you've forgotten why you started. There are too many steps, too many things that break silently, and zero joy in the process.

kagenti-claw changes that. One command. One minute. Your agent is live.

## What You Get

Three things happen when you run `make deploy`:

1. **The Kagenti operator** lands in your cluster — the brain that manages agent lifecycles, discovery, and identity
2. **OpenClaw** spins up as a managed agent — configured, routed, and ready to accept connections
3. **Everything connects** — TLS route, gateway token, device pairing — all wired together

You don't configure any of this. It just works.

## Quick Start

```bash
git clone https://github.com/zanetworker/kagenti-claw.git
cd kagenti-claw
make deploy
```

That's it. The output gives you your dashboard URL and gateway token.

Using Claude Code? Even simpler:

```bash
/deploy-openclaw
```

The skill handles everything — operator installation, manifest application, token retrieval, device pairing approval — and hands you the keys.

## What It Looks Like

After deployment, your cluster has a fully managed AI agent:

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

The Kagenti operator automatically discovers your agent, creates an AgentCard, and begins syncing metadata via the A2A protocol.

## How It Works

```
┌─────────────────────────────────────────────────────┐
│                  Your Cluster                        │
│                                                      │
│  ┌──────────────┐         ┌───────────────────────┐  │
│  │   Kagenti    │ watches │    OpenClaw Agent      │  │
│  │   Operator   │────────▶│  (Deployment + Svc)   │  │
│  │              │         │    Port 18789 (WS)     │  │
│  └──────┬───────┘         └───────────┬───────────┘  │
│         │ creates                     │               │
│  ┌──────▼───────┐         ┌───────────▼───────────┐  │
│  │ AgentRuntime │         │    Route (TLS edge)    │  │
│  │ AgentCard    │         │  ───▶ Dashboard URL    │  │
│  └──────────────┘         └───────────────────────┘  │
└─────────────────────────────────────────────────────┘
```

OpenClaw runs as a standard Kubernetes Deployment with the `kagenti.io/type: agent` label. An init container configures the gateway to bind on `0.0.0.0` so the Service can reach it. The Route terminates TLS and forwards WebSocket traffic with a 300-second timeout.

## Prerequisites

- A Kubernetes cluster (v1.28+) — OpenShift for Route support, or bring your own Ingress
- `kubectl` configured and connected
- `helm` v4+ (the Makefile installs the Kagenti operator for you)

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

## Connecting to the Dashboard

After `make deploy`, open the printed dashboard URL. Paste the gateway token, click Connect, then run `make approve-pairing` to authorize the session.

## Related Projects

- [**kagenti-operator**](https://github.com/kagenti/kagenti-operator) — The Kubernetes operator that powers agent lifecycle management, discovery, and identity
- [**OpenClaw**](https://quay.io/repository/aicatalyst/openclaw) — Multi-channel AI gateway with extensible messaging integrations

## One More Thing

This entire repo — every manifest, every config, every line — was built by deploying OpenClaw on a live cluster, hitting every wall (wrong ports, loopback binds, missing TLS, pairing gates), and encoding the fixes so you never have to. The pain is done. Just deploy.

## License

[Apache 2.0](LICENSE)
