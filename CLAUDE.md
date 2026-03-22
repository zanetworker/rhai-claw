# kagenti-claw

Deploy OpenClaw on Kubernetes with the Kagenti operator.

## Quick Start

Run `/deploy-openclaw` to deploy everything automatically.

## Project Structure

- `manifests/` — Kubernetes manifests (Deployment, Service, Route, AgentRuntime, Guardrails)
- `.claude/skills/deploy-openclaw.md` — Automated deployment skill
- `Makefile` — Manual deployment targets
- `docs/gotchas-nemo-guardrails.md` — NeMo Guardrails integration gotchas and workarounds

## Key Details

- OpenClaw listens on port **18789** (WebSocket gateway)
- Gateway must bind to `0.0.0.0` via `gateway.bind=lan` config (init container handles this)
- Route needs edge TLS with 300s timeout for WebSocket support
- Device pairing must be approved after first dashboard connection
- Kagenti operator repo: https://github.com/kagenti/kagenti-operator

## NeMo Guardrails

- Guardrails proxy sits between OpenClaw and the LLM (Anthropic API)
- OpenClaw configured with custom `guardrails-proxy` model provider via `openclaw config set --batch-file`
- Adapter sidecar transforms NeMo response format to OpenAI format and handles streaming
- Colang v1 rules in `manifests/guardrails-config.yaml` define safety policies
- See `docs/gotchas-nemo-guardrails.md` for 6 gotchas we hit and their workarounds
