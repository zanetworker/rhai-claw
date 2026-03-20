# kagenti-claw

Deploy OpenClaw on Kubernetes with the Kagenti operator.

## Quick Start

Run `/deploy-openclaw` to deploy everything automatically.

## Project Structure

- `manifests/` — Kubernetes manifests (Deployment, Service, Route, AgentRuntime)
- `.claude/skills/deploy-openclaw.md` — Automated deployment skill
- `Makefile` — Manual deployment targets

## Key Details

- OpenClaw listens on port **18789** (WebSocket gateway)
- Gateway must bind to `0.0.0.0` via `gateway.bind=lan` config (init container handles this)
- Route needs edge TLS with 300s timeout for WebSocket support
- Device pairing must be approved after first dashboard connection
- Kagenti operator repo: https://github.com/kagenti/kagenti-operator
