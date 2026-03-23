# Application Gotchas (OpenClaw Agent-Side)

These are OpenClaw-specific behaviors. The `/deploy-openclaw` skill handles all of them automatically.

## Severity

| Rating | Icon | Meaning |
|--------|------|---------|
| **Dead end** | :no_entry: | No workaround. Must change approach. |
| **Surprising** | :warning: | Not obvious from docs. Costs hours. |
| **Obvious** | :bulb: | Expected if you know the tech. |

## Surprising

### Multi-part content format breaks downstream tools :warning:

**Priority rank: #13**

OpenClaw sends message `content` as a list of typed blocks (OpenAI multi-part format):
```json
{"content": [{"type": "text", "text": "hello"}]}
```

This is valid per the OpenAI API spec, but tools downstream (NeMo Guardrails, custom proxies) that do string operations on `content` crash. NeMo's `get_colang_history()` calls `.rsplit()` on the content, which throws `TypeError: must be str or None, not list`.

**Why it's surprising:** The format is technically correct. You don't expect a valid OpenAI message to break an OpenAI-compatible endpoint. The crash happens in post-processing, not during the obvious request handling path.

**Workaround:** Adapter normalizes `content` from list to string before forwarding.

## Dead Ends

### `diagnostics-otel` extension broken in image :no_entry:

**Priority rank: #31**

OpenClaw has a built-in `diagnostics-otel` extension designed for GenAI-level OTEL tracing (prompt text, completion text, token counts, tool calls). The extension's `index.js` is missing from the container image build:

```
[plugins] extension entry escapes package directory: ./index.js (source=/app/dist/extensions/diffs)
```

This blocks the best path to full GenAI observability. No workaround without fixing the image build.

### Browser automation broken :bulb:

**Priority rank: #32**

Chrome/Chromium is not in the `quay.io/aicatalyst/openclaw:latest` image. `openclaw browser status` shows `detectedBrowser: unknown`. Web scraping, screenshots, and page interaction tools fail.

Not a platform issue — needs Chromium added to the image or a remote browser sidecar.

## Obvious

### Binds to loopback by default :bulb:

**Priority rank: #16**

OpenClaw listens on `127.0.0.1:18789` — a deliberate security choice for single-user laptop mode. In Kubernetes, the Service routes to the pod IP, not loopback. Agent is unreachable.

**Why it's obvious:** Any agent designed for localhost won't work in K8s without binding to `0.0.0.0`.

**Fix:** `openclaw config set gateway.bind lan` in init container.

### Hardcoded port 18789 :bulb:

**Priority rank: #17**

Port 18789 is hardcoded. The standard `PORT` env var is ignored. We initially set `PORT=8000` and `containerPort: 8000` — working pod, no reachable service. Found the real port via `/proc/net/tcp` inside the container.

**Why it's obvious (in hindsight):** Non-standard ports are common in agent frameworks. Always check what the process actually listens on.

**Fix:** Match all manifests (Service, Route, containerPort) to 18789.

### Gateway token regenerates on every restart :bulb:

**Priority rank: #19**

OpenClaw generates a gateway auth token on first boot, writes to `openclaw.json`. The `emptyDir` volume is ephemeral — every pod restart = new token. Dashboard needs re-pairing.

**Fix:** `make token` + `make approve-pairing` after restarts. A PVC would persist state but adds complexity.

### Device pairing required after every reconnect :bulb:

**Priority rank: #20**

OpenClaw's Control UI uses a device pairing model (like messaging apps). New browser sessions register as "devices" needing operator approval. Pairing persists across page refreshes but is lost on pod restart.

This is UX friction, but it's also a security feature — it prevents unauthorized access even if someone has the gateway URL and token. The pairing model ensures only explicitly approved devices can interact with the agent.

**Fix:** `make approve-pairing` or auto-approve in the deploy skill.
