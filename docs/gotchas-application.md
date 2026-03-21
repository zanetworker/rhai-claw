# Application Gotchas (Agent-Side)

These are OpenClaw-specific behaviors. The `/deploy-openclaw` skill handles all of them automatically.

## OpenClaw binds to loopback by default

OpenClaw is designed as a personal assistant — it runs on your laptop and listens on `127.0.0.1:18789` so only local connections can reach it. This is a deliberate security choice for single-user mode.

In Kubernetes, the Service routes traffic to the pod's IP, not `127.0.0.1`. If the agent only listens on loopback, the Service health checks fail and no traffic reaches the agent. The fix is `openclaw config set gateway.bind lan`, which tells OpenClaw to listen on `0.0.0.0`.

The deployment handles this with an init container that runs the config command before the main container starts. The config is written to a shared `emptyDir` volume so the main container picks it up.

Any agent you deploy on Kubernetes must listen on `0.0.0.0` on its declared port. This is the agent's responsibility, not the platform's.

## OpenClaw uses port 18789, not 8000

OpenClaw's gateway listens on port 18789 by default — this is hardcoded in the application, not configurable via the standard `PORT` environment variable. We initially set `PORT=8000` and `containerPort: 8000` in the deployment, which resulted in a working pod with no reachable service. Debugging with `/proc/net/tcp` inside the container revealed the actual listening port.

The Service, Route, and `containerPort` must all use 18789. The browser control server listens on a separate port (18791) on loopback only.

## Gateway token regenerates on every pod restart

OpenClaw auto-generates a gateway auth token on first boot and writes it to `openclaw.json` in its state directory. Because the deployment uses an `emptyDir` volume (needed so the init container can write config), the state directory is ephemeral. Every pod restart generates a fresh token.

This means you need to run `make token` after any restart to get the current token. A persistent volume would fix this, but adds complexity for a demo deployment.

## Device pairing required after every reconnect

OpenClaw's Control UI uses a device pairing model borrowed from messaging apps — when a new browser session connects via WebSocket, it registers as a "device" that needs operator approval. This prevents unauthorized access even if someone has the gateway URL and token.

After connecting in the dashboard, you see "pairing required." Run `make approve-pairing` to accept the pending device. The pairing persists across page refreshes but is lost when the pod restarts (same `emptyDir` issue as the token).

## Browser automation fails

OpenClaw includes a browser automation tool that uses Chrome/Chromium for web scraping, screenshots, and page interaction. The `quay.io/aicatalyst/openclaw:latest` container image doesn't ship a Chrome binary — the tool executes but can't find a browser, returning "can't use browser automation in this environment."

This is a container image limitation, not a platform restriction. OpenClaw's `openclaw browser status` shows `detectedBrowser: unknown`. A custom image with Chromium installed, or a remote browser sidecar, would fix this.
