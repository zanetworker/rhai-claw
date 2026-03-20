# BYOA Gap Analysis: OpenClaw on Kagenti

## The Vision

A developer deploys any agent as a standard Kubernetes workload and creates one AgentRuntime CR. The platform handles discovery, observability, identity, tool governance, and safety. The agent's code and image are never modified.

## Design Principles

**1. The agent is untouched.** No code changes, no image rebuilds, no framework requirements. The platform wraps the agent in infrastructure — sidecars, env vars, annotations — at admission time.

**2. One CR, full enrollment.** The AgentRuntime CR is the single declaration that enrolls a workload into the platform. Everything the platform needs to know — trace endpoint, identity config, agent metadata — lives on this CR.

**3. The operator enrolls, the webhook injects.** The operator stamps labels and triggers rolling updates. The webhook intercepts Pod CREATE and injects sidecars, env vars, and volumes. Clean separation: the operator is the control plane, the webhook is the data plane.

**4. Progressive layers.** Each platform concern (discovery, tracing, identity, governance, safety) is independent. You can adopt one without the others. Feature gates control what gets injected.

**5. GitOps clean.** The developer's Deployment manifest in git never shows platform concerns. The webhook mutates Pods, not Deployments. Argo CD sees no drift.

## What We Deployed

| Layer | Component | Status |
|-------|-----------|--------|
| Agent runtime | OpenClaw Deployment + Service + Route | Deployed |
| Lifecycle | AgentRuntime CR | Deployed, operator reconciles labels + config hash |
| Discovery | AgentCard CR + ConfigMap | Deployed, operator auto-creates AgentCard, ConfigMap provides A2A metadata |
| Observability | OTEL → MLflow tracing | Deployed via preload script, traces landing in MLflow |
| Admission | kagenti-extensions webhook | Deployed, intercepts pods, reads AgentRuntime CR |

## What We Did NOT Deploy

| Layer | Component | Why |
|-------|-----------|-----|
| Identity | SPIFFE/SPIRE sidecars | No SPIRE server on cluster |
| Tool governance | MCP Gateway | Not deployed |
| Safety | Guardrails Orchestrator, NeMo Guardrails | Not deployed |
| Sandboxing | Kata containers | Not configured |

## Gaps Between Vision and Reality

### 1. The operator doesn't inject anything

The AgentRuntime controller stamps labels and a config hash annotation. It does not inject env vars, volumes, or init containers. `spec.trace.endpoint` and `spec.identity.spiffe.trustDomain` go into the hash computation but never reach the pod.

**Impact:** We manually added `OTEL_EXPORTER_OTLP_ENDPOINT`, `NODE_OPTIONS`, `ANTHROPIC_API_KEY`, an init container for `gateway.bind=lan`, and an OTEL preload ConfigMap to the Deployment. All platform concerns leaked into the developer's manifest.

**To close:** The operator should inject env vars from `spec.trace` and a proposed `spec.secrets` field directly into the target Deployment's container spec.

### 2. The webhook doesn't inject trace env vars

The webhook reads `spec.trace` from the AgentRuntime CR into `ResolvedConfig.TraceEndpoint` but never converts it to `OTEL_EXPORTER_OTLP_ENDPOINT` on the container. We wrote `BuildTraceEnv()` and `appendEnvVarsIfAbsent()` to close this — not yet upstreamed.

**Additional issues found:**
- `AnyInjected()` returns false when all sidecars are disabled, causing an early return that skips trace injection entirely
- The webhook resolves the ReplicaSet name, not the Deployment name, so AgentRuntime lookup fails. We fixed by stripping the `pod-template-hash` suffix

### 3. Agent discovery requires agent cooperation or manual work

The AgentCard controller fetches `/.well-known/agent-card.json` from the agent's service. Agents that don't serve this endpoint (like OpenClaw) get `SYNCED=False`. The ConfigMap fallback (`{name}-card-signed`) works but is undocumented and requires manual creation.

**To close:** AgentRuntime should support an inline `spec.agentCard` field. The operator creates the ConfigMap automatically.

### 4. Agent-specific config lives in the developer's manifest

OpenClaw requires `gateway.bind=lan` to listen on `0.0.0.0`. We handled this with an init container. Every agent runtime has quirks like this — port bindings, auth modes, config paths. The platform can't know them all, but it should provide a generic mechanism.

**To close:** Support `spec.initCommands` or `spec.configOverrides` on AgentRuntime for agent-specific setup that runs before the main container.

### 5. Secrets management is manual

We manually added `ANTHROPIC_API_KEY` from a Secret to the Deployment. The platform should handle this.

**To close:** Add `spec.secrets` to AgentRuntime:
```yaml
spec:
  secrets:
  - secretRef: {name: llm-keys, key: anthropic}
    envVar: ANTHROPIC_API_KEY
```

### 6. OTEL instrumentation is transport-level, not application-level

Our fetch patch captures HTTP attributes (URL, status, latency) but not GenAI content (prompts, completions, token counts). Full GenAI observability requires either the agent's own instrumentation (OpenClaw's broken `diagnostics-otel` extension) or a standardized GenAI OTEL instrumentation library.

**To close:** This is an agent-side concern. The platform can provide the OTEL endpoint and SDK, but capturing prompt/completion content requires cooperation from the agent runtime. Document the contract: agents that emit GenAI semantic convention spans get richer traces.

### 7. Webhook deployment requires namespace opt-in

The webhook's `namespaceSelector` requires `kagenti-enabled=true` on every namespace where agents run. Missing this label causes silent failure — the webhook is never called, pods create normally, and no injection happens.

**To close:** Either the operator auto-labels namespaces when an AgentRuntime CR is created, or the Helm chart documents this prominently, or the webhook uses a broader selector with per-namespace opt-out instead.

## Summary

The architecture is sound. The three-part design (operator enrolls → webhook injects → controllers discover) separates concerns cleanly. The gaps are in the last mile — the operator computes hashes but doesn't inject, the webhook reads config but doesn't emit env vars, and agent discovery assumes A2A compliance.

Every manual step we took in this session is a concrete gap to close. The fixes we built (fetch instrumentation, `BuildTraceEnv`, deployment-name resolution, ConfigMap-based agent cards) prove the architecture works. They need to move from deployment-time workarounds into the operator and webhook code.
