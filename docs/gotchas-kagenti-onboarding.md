# Kagenti Onboarding Feedback

Field feedback and friction points from onboarding agents onto the Kagenti platform. These are not bugs — they're UX and architecture observations that should inform the roadmap.

## Severity

| Rating | Icon | Meaning |
|--------|------|---------|
| **Friction** | :warning: | Slows adoption. Developers hit this and question the value. |
| **Design question** | :thinking: | Needs a product decision. Multiple valid answers. |
| **Gap** | :no_entry: | Missing capability that blocks a real use case. |

## Friction

### Webhook adds onboarding complexity :warning:

Installing the kagenti-extensions webhook is an extra cluster-wide step before any agent can be deployed. The webhook requires:
- Its own namespace (`kagenti-webhook-system`)
- ClusterRole + ClusterRoleBinding for AgentRuntime reads
- Namespace labeling (`kagenti-enabled=true`) — silent failure if missing
- TLS cert management for admission webhooks

From a field perspective, this is real friction. A platform admin asks "what does this webhook do?" and the answer today is: injects OTEL env vars (if patched) and potentially sidecars (SPIFFE, Envoy — both planned). That's a hard sell for a cluster-wide admission webhook.

**Question for the team:** What else will the webhook do? If the roadmap includes identity injection (SPIFFE), MCP Gateway sidecar, or policy enforcement, the webhook earns its keep. If it's only for OTEL env vars, a simpler mechanism (operator-managed ConfigMap, pod annotation → controller) would reduce the blast radius.

**What would help:**
- Document the webhook's current and planned capabilities in a single table
- Consider making the webhook optional — the operator should work without it, with reduced functionality
- If the webhook stays required, bundle it in the operator Helm chart instead of a separate install

### One AgentRuntime per Deployment feels heavyweight :warning:

Today, every agent Deployment needs its own AgentRuntime CR:

```yaml
apiVersion: agent.kagenti.dev/v1alpha1
kind: AgentRuntime
metadata:
  name: my-agent        # 1:1 with Deployment
spec:
  targetRef:
    kind: Deployment
    name: my-agent
```

In a multi-tenant namespace where 10 developers deploy 10 agents, that's 10 AgentRuntime CRs. Each developer needs to know about Kagenti CRDs, understand `targetRef`, and create the CR alongside their Deployment.

**What developers expect:** "I deploy my pod. The platform detects it and does the right thing."

**What they get:** "Deploy your pod, then also create this CR, then also label the namespace, then also check if the webhook is installed."

**Options to reduce friction:**
- **Namespace-level defaults:** A single `AgentRuntimeDefaults` CR per namespace that applies to all Deployments with a label (e.g., `kagenti.io/type: agent`). No per-Deployment CR needed for the common case.
- **Auto-discovery:** The operator watches for Deployments with `kagenti.io/type: agent` label and auto-creates AgentRuntime CRs. Developer only adds a label.
- **Annotation-based:** Put trace config, identity config directly in Deployment annotations. No CRD needed at all for simple cases.

### Debugging is hard when things go wrong :warning:

When the platform doesn't do what you expect, the debugging path crosses multiple components:

```
Is the namespace labeled? → Is the webhook installed? → Is the webhook patched?
→ Is the AgentRuntime CR created? → Does the CR have the right targetRef?
→ Does the webhook have RBAC? → Is the MCP being matched correctly?
→ Check operator logs → Check webhook logs → Check pod events
```

Each hop is a different namespace, different logs, different RBAC. For a platform engineer, this is manageable. For a developer who just wants their agent to get traces, it's too many moving parts.

**What would help:**
- A single `kagenti status <namespace>` CLI command that checks all prerequisites and reports what's working/missing
- Better error messages on the webhook — instead of silently skipping, log why injection was skipped
- A debug annotation (`kagenti.io/debug: "true"`) that emits verbose logs for a specific pod

## Design Questions

### What do we mandate for app developers? :thinking:

Today, the platform injects OTEL env vars into agent pods. But for tracing to actually work, the agent application must:

1. **Read the env vars** — `OTEL_EXPORTER_OTLP_ENDPOINT`, `OTEL_SERVICE_NAME`, `OTEL_EXPORTER_OTLP_PROTOCOL`
2. **Initialize an OTEL SDK** — or use a preload script like we did for OpenClaw
3. **Emit spans with GenAI semantic conventions** — `gen_ai.system`, `gen_ai.request.model`, etc.

If the agent doesn't do steps 2-3, the env vars are useless. The platform can inject configuration, but can't inject instrumentation into arbitrary code.

**What should we mandate?**

| Approach | Developer burden | Platform control | Trace quality |
|----------|-----------------|-----------------|---------------|
| "Just set the env vars" | Minimal | Low — app must instrument itself | Varies wildly |
| "Use our OTEL preload/sidecar" | Low — we inject it | Medium — intercepts HTTP calls | HTTP-level only |
| "Adopt our SDK" | High — code changes | High — we control the instrumentation | Full GenAI traces |
| "We proxy your LLM calls" | None — transparent | Full — we see everything | Full, but adds latency |

The NeMo Guardrails adapter pattern (option 4) accidentally gives us full request/response visibility. If we formalize this as a "guardrails + observability proxy," it solves both safety and tracing without asking developers to change their code.

### What about identity? :thinking:

The webhook has planned SPIFFE/SPIRE sidecar injection for workload identity. Open questions:

- Does every agent need its own SPIFFE ID, or can a namespace share one?
- How does agent identity propagate to MCP server calls? (mTLS, token injection, header forwarding?)
- If a developer deploys an agent without SPIFFE, does it fail or run without identity?
- What's the UX for "my agent needs to call this MCP server" — is identity automatic or configured?

These questions need answers before the webhook complexity is justified.

### Multi-tenant namespace model :thinking:

The current design assumes namespace-per-team or namespace-per-agent. But some field scenarios have many developers sharing a namespace:

```
namespace: ai-agents
├── developer-a/agent-1  (Deployment)
├── developer-a/agent-2  (Deployment)
├── developer-b/agent-3  (Deployment)
└── developer-c/agent-4  (Deployment)
```

In this model:
- One namespace label covers all agents
- But each agent needs its own AgentRuntime CR (friction)
- All agents share the same webhook config (no per-agent customization)
- RBAC for who can create AgentRuntime CRs becomes important

**What would help:** Namespace-level defaults with per-agent overrides via annotations.

## Gap

### No "lean mode" for simple deployments :no_entry:

The minimal Kagenti setup today requires: operator + CRDs + webhook + namespace label + AgentRuntime CR + AgentCard ConfigMap. That's 6 moving parts for "I want my agent discovered and traced."

Field feedback: "Even the small pieces feel heavyweight."

**What lean mode should look like:**
1. Install operator (Helm, one command)
2. Deploy agent with `kagenti.io/type: agent` label
3. Done — operator auto-discovers, creates AgentRuntime, creates AgentCard from defaults

No webhook. No namespace labeling. No manual CRs. The operator does everything based on the label. The webhook becomes opt-in for advanced features (identity, sidecars, policy).

**Trade-off:** Less control per-agent, but dramatically lower time-to-first-agent. The 80% case (deploy, discover, trace) should be one label. The 20% case (custom identity, sidecars, MCP gateway) uses the full CR model.
