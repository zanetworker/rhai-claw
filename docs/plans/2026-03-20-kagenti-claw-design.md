# kagenti-claw Design

## Purpose

A single repo that lets any developer deploy OpenClaw on Kubernetes with the Kagenti operator in one command. Includes a Claude Code skill for fully automated setup and a Makefile for non-Claude users.

## Repo Structure

```
kagenti-claw/
├── CLAUDE.md
├── README.md
├── Makefile
├── manifests/
│   ├── namespace.yaml
│   ├── deployment.yaml
│   ├── service.yaml
│   ├── route.yaml
│   └── kustomization.yaml
└── .claude/
    └── skills/
        └── deploy-openclaw.md
```

## Manifests

- **namespace.yaml**: Creates `agents` namespace (skipped if exists)
- **deployment.yaml**: OpenClaw deployment with init container that runs `openclaw config set gateway.bind lan` + `gateway.controlUi.dangerouslyAllowHostHeaderOriginFallback true`. Image: `quay.io/aicatalyst/openclaw:latest`. Port 18789. Labels: `kagenti.io/type: agent`, `protocol.kagenti.io/a2a: ""`
- **service.yaml**: ClusterIP on port 18789
- **route.yaml**: Edge TLS route with 300s timeout annotation for WebSocket support

## Skill: `/deploy-openclaw`

Single skill that handles the full lifecycle:

1. Check cluster connectivity (`kubectl cluster-info`)
2. Install kagenti operator via Helm (if not present)
3. Install AgentRuntime CRD from kagenti-operator repo (if not present)
4. Apply all manifests
5. Wait for pod ready
6. Create AgentRuntime CR pointing at the deployment
7. Retrieve gateway token from pod config
8. Approve any pending device pairings
9. Print: URL, token, `kubectl get agentruntimes`, `kubectl get agentcards`

## Makefile

| Target | Description |
|--------|-------------|
| `deploy` | Apply all manifests, wait for ready |
| `teardown` | Delete all resources |
| `token` | Print gateway auth token |
| `status` | Show pod, agentruntime, agentcard status |
| `approve-pairing` | Approve pending device pairings |

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `NAMESPACE` | `agents` | Target namespace |
| `IMAGE` | `quay.io/aicatalyst/openclaw:latest` | OpenClaw image |
| `KAGENTI_VERSION` | latest | Helm chart version |

## README

Includes: one-liner quick start, architecture overview, expected output samples for `kubectl get agentruntimes` and `kubectl get agentcards`, and manual setup steps.
