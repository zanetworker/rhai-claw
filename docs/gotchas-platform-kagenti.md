# Platform Gotchas (Kagenti-Side)

These are Kagenti platform behaviors discovered during deployment. The `/deploy-openclaw` skill handles all of them automatically.

## Severity

| Rating | Icon | Meaning |
|--------|------|---------|
| **Dead end** | :no_entry: | No workaround. Must change approach. |
| **Surprising** | :warning: | Not obvious from docs. Costs hours. |
| **Obvious** | :bulb: | Expected if you know the tech. |

## Surprising

### Namespace needs `kagenti-enabled=true` label :warning:

**Priority rank: #4**

The kagenti-extensions webhook uses a `namespaceSelector` with `matchLabels: {kagenti-enabled: "true"}`. Without the label, the API server never routes admission requests to the webhook. Pods create normally, no errors appear anywhere, but no env vars or sidecars are injected.

**Why it's surprising:** The failure is completely silent. `failurePolicy: Fail` only applies when the webhook is called and fails — not when the selector excludes the namespace entirely. We spent significant debugging time on this.

**Fix:**
```bash
kubectl label namespace agents kagenti-enabled=true
```

### `spec.trace` doesn't inject OTEL env vars :warning:

**Priority rank: #11**

**Status (2026-03-25): STILL OPEN.** The webhook reads trace overrides from AgentRuntime (`ReadAgentRuntimeOverrides()` extracts `TraceEndpoint`, `TraceProtocol`, `TraceSamplingRate`) and passes them through `ResolveConfig()`, but no code path in `ContainerBuilder` emits `OTEL_EXPORTER_OTLP_ENDPOINT` env vars into the agent container. The sidecars (envoy, spiffe-helper, client-registration) are injected but OTEL tracing env vars are not.

The AgentRuntime controller (PR [#218](https://github.com/kagenti/kagenti-operator/pull/218)) processes `spec.trace` by including it in a SHA256 config hash. When the hash changes, the controller stamps a `kagenti.io/config-hash` annotation, triggering a rolling update. But the new pods come up identical — the controller never writes `OTEL_EXPORTER_OTLP_ENDPOINT` to the container's env vars.

**Why it's surprising:** The CR has a `trace` field. You set it. The pod restarts. But nothing changes. No error, no warning. The config hash changes prove the controller sees the trace config — it just doesn't act on it.

**Fix:** Patched webhook image `quay.io/azaalouk/kagenti-webhook:trace-injection` adds `BuildTraceEnv()`. Fork: [`zanetworker/kagenti-extensions@0048067`](https://github.com/zanetworker/kagenti-extensions/commit/0048067).

### Webhook early return bypasses trace injection :warning:

**Priority rank: #14**

**Status (2026-03-25): STILL OPEN.** `AnyInjected()` checks `EnvoyProxy || SpiffeHelper || ClientRegistration`. When all sidecar feature gates are disabled, `AnyInjected()` returns false and `InjectAuthBridge()` exits at line 157-159 before any trace injection could happen. There is still no separate OTEL trace injection path independent of sidecar decisions.

**Why it's surprising:** Only surfaces when you don't want sidecars (SPIFFE, Envoy) but do want OTEL tracing. The common case in lightweight deployments.

**Fix:** Patched in same fork — checks trace injection independently.

### Deployment name mismatch in webhook :warning:

**Priority rank: #26**

**Status (2026-03-25): STILL OPEN.** `deriveWorkloadName()` in `authbridge_webhook.go` returns the ReplicaSet name by trimming the trailing `-` from `GenerateName` (e.g., `openclaw-748648db65`). But `AgentRuntime.spec.targetRef.name` is the Deployment name (`openclaw`). The `ReadAgentRuntimeOverrides()` function matches `targetRef.name` against this derived name — mismatch. The code comments say "Resolving the Deployment name requires a ReplicaSet owner-ref lookup, which is planned for Phase 2 (issue #177)."

**Impact:** AgentRuntime per-workload overrides (trace, identity) are never applied to controller-managed pods. Only bare pods (with explicit Name) work correctly.

**Workaround:** Name the AgentRuntime CR's `targetRef.name` to match the ReplicaSet name pattern, or wait for Phase 2 fix.

## Obvious

### AgentCard `SYNCED=False` for non-A2A agents :bulb:

**Priority rank: #25**

The AgentCard controller tries to fetch from `/.well-known/agent-card.json` over HTTP. OpenClaw is a WebSocket gateway, not an A2A server.

**Why it's obvious:** If your agent doesn't speak A2A, it won't serve the agent card. The Kagenti operator has a `ConfigMapFetcher` escape hatch — create a ConfigMap named `{serviceName}-card-signed` with key `agent-card.json`.

**Fix:** `manifests/agentcard-configmap.yaml` provides the card. AgentCard controller reads it and sets `SYNCED=True`.

### AgentRuntime CRD not in Helm chart :bulb:

**Priority rank: #21**

**Status (2026-03-25): PARTIALLY FIXED.** The CRD exists at `config/crd/bases/agent.kagenti.dev_agentruntimes.yaml` in the repo, but the Helm chart's `crds/` directory only contains `agent.kagenti.dev_agentcards.yaml`. Still needs manual install:

```bash
kubectl apply -f https://raw.githubusercontent.com/kagenti/kagenti-operator/main/kagenti-operator/config/crd/bases/agent.kagenti.dev_agentruntimes.yaml
```

The AgentRuntime controller is registered in `cmd/main.go` and works — it's just the Helm chart packaging that's behind.

### CRDs get stuck terminating :bulb:

**Priority rank: #22**

Deleting a CRD while CRs still exist causes it to hang with finalizers. Next install fails with "create not allowed while custom resource definition is terminating."

**Fix:**
```bash
kubectl patch crd agentruntimes.agent.kagenti.dev --type=json -p '[{"op":"remove","path":"/metadata/finalizers"}]'
```

### AgentCards CRD only from Helm first-install :bulb:

**Priority rank: #27**

The `agentcards` CRD is installed by Helm at first install. Helm doesn't recreate CRDs on subsequent installs. If manually deleted, you must `helm uninstall` then `helm install` to recover.

### Empty secrets cause silent failures :bulb:

**Priority rank: #23**

```bash
kubectl create secret --from-literal=anthropic=$ANTHROPIC_API_KEY
```

When `$ANTHROPIC_API_KEY` is unset, this creates a secret with an empty value. The secret exists (passes `kubectl get secret` checks) but OpenClaw reports "No API key found."

**Fix:** Skill verifies content length after creation.

### Secrets are namespace-scoped :bulb:

A secret in the `agents` namespace is not visible in the `openclaw` namespace. Caused a `CreateContainerConfigError` during testing. The skill emphasizes the target namespace in every command.

### Webhook needs RBAC for AgentRuntime reads :bulb:

**Status (2026-03-25): STILL OPEN.** The webhook needs `get/list/watch` on `agentruntimes.agent.kagenti.dev`. Without this, it logs `"AgentRuntime CRD not available or list failed"` and falls back to no trace config. The bundled `manifests/webhook/webhook-all.yaml` includes the RBAC. The upstream webhook Helm chart still does not include this RBAC.

The webhook's `ReadAgentRuntimeOverrides()` gracefully degrades (returns nil, nil) when the CRD isn't installed or RBAC is missing, so the webhook itself doesn't crash — it just ignores per-workload overrides silently.
