# Gotchas by Team

Everything below was discovered deploying OpenClaw with Kagenti, NeMo Guardrails, sandboxed containers, and MLflow tracing. The `/deploy-openclaw` skill handles most of them automatically — these are documented so each team knows what to fix upstream.

## Severity Ratings

| Rating | Icon | Meaning |
|--------|------|---------|
| **Dead end** | :no_entry: | No workaround on this path. Must change approach entirely. |
| **Surprising** | :warning: | Not obvious from docs. Costs hours of debugging. Poor error messages or silent failures. |
| **Obvious** | :bulb: | Expected if you understand the technology. Documented, discoverable. |

## Priority: All Gotchas Ranked

The top gotchas across all teams, ranked by how much time they waste and how many people they'll hit.

| # | Severity | Team | Gotcha | Time wasted |
|---|----------|------|--------|-------------|
| 1 | :no_entry: | Sandboxed Containers | Native Kata doesn't work on AWS cloud VMs — no nested virt | Hours if you don't know upfront |
| 2 | :warning: | TrustyAI / NeMo | `get_colang_history()` crashes on multi-part content lists | 3+ hours — error is in post-processing, not the obvious path |
| 3 | :warning: | TrustyAI / NeMo | Response format is not OpenAI-compatible despite `/v1/chat/completions` endpoint | 2+ hours — 200 OK but empty responses |
| 4 | :warning: | Kagenti | Namespace needs `kagenti-enabled=true` — completely silent failure | 2+ hours — no errors anywhere |
| 5 | :warning: | MLflow | OTLP rejected due to port in Host header — silently drops all traces | 2+ hours — zero indication of failure |
| 6 | :warning: | Sandboxed Containers | Port 15150 not in SG — peer pod VM created but unreachable | 1-2 hours — looks like it should work |
| 7 | :warning: | TrustyAI / NeMo | No streaming support — clients hang or get broken pipes | 1-2 hours |
| 8 | :warning: | Sandboxed Containers | Pod VM AMI creation fails on S3/IAM — no retry | 1-2 hours — fragile auto-provisioning |
| 9 | :warning: | Sandboxed Containers | `peer-pods-cm` must exist BEFORE KataConfig — no reconciliation | 1 hour + 20 min reboot to fix |
| 10 | :warning: | TrustyAI / NeMo | RHOAI image missing `langchain-anthropic` — blocks Anthropic engine | 30 min |
| 11 | :warning: | Kagenti | `spec.trace` doesn't inject OTEL env vars — webhook bug | 1+ hours — trace config exists but does nothing |
| 12 | :warning: | TrustyAI / NeMo | Self-check prompt flags agent metadata as attacks | 30 min — false positives on every message |
| 13 | :warning: | OpenClaw | Multi-part content format breaks downstream tools | 1+ hours — linked to NeMo crash (#2) |
| 14 | :warning: | Kagenti | Webhook early return bypasses trace injection | 1 hour — only surfaces when sidecars are disabled |
| 15 | :warning: | Sandboxed Containers | KataConfig deletion stuck on finalizer | 30 min — blocks cluster cleanup |
| 16 | :bulb: | OpenClaw | Binds to loopback by default — unreachable in K8s | 30 min |
| 17 | :bulb: | OpenClaw | Hardcoded port 18789 — ignores PORT env var | 15 min |
| 18 | :bulb: | Sandboxed Containers | KataConfig reboots worker nodes (10-60 min) | Expected, but painful without kataConfigPoolSelector |
| 19 | :bulb: | OpenClaw | Gateway token regenerates on restart | 5 min per restart |
| 20 | :bulb: | OpenClaw | Device pairing required after reconnect | 2 min per session |
| 21 | :bulb: | Kagenti | AgentRuntime CRD not in Helm chart | 5 min — manual install |
| 22 | :bulb: | Kagenti | CRDs get stuck terminating | 5 min — patch finalizers |
| 23 | :bulb: | Kagenti | Empty secrets cause silent failures | 10 min |
| 24 | :bulb: | MLflow | Experiment ID must be header | 5 min |
| 25 | :bulb: | Kagenti | AgentCard SYNCED=False for non-A2A agents | 15 min — ConfigMap pattern |
| 26 | :bulb: | Kagenti | Deployment name mismatch in webhook | Patched in fork |
| 27 | :bulb: | Kagenti | AgentCards CRD only from Helm first-install | Avoid deleting CRDs |
| 28 | :no_entry: | Sandboxed Containers | 4,000 sandboxed pods impractical | Design constraint, not a bug |
| 29 | :no_entry: | MLflow | Traces are HTTP-level only, not GenAI-level | Architectural gap — see 3 paths |
| 30 | :no_entry: | TrustyAI / NeMo | `NemoGuardrail` CRD can't add sidecars or command overrides | Blocks CRD-based deployment |
| 31 | :no_entry: | OpenClaw | `diagnostics-otel` extension broken in image | Blocks GenAI traces via Path 1 |
| 32 | :bulb: | OpenClaw | Browser automation broken in container | No Chrome in image |
| 33 | :bulb: | MLflow | OTEL export errors are silent | Set OTEL_LOG_LEVEL=debug |
| 34 | :bulb: | MLflow | No OTEL Collector — direct export | Deploy Collector for production |
| 35 | :bulb: | MLflow | Guardrails latency appears as LLM latency | Need span label separation |

## By Team

### OpenClaw / Agent Team

Owner: OpenClaw upstream

| # | Severity | Gotcha | Impact |
|---|----------|--------|--------|
| 16 | :bulb: | Binds to loopback by default | Agent unreachable in K8s |
| 17 | :bulb: | Hardcoded port 18789 | `PORT` env var ignored |
| 19 | :bulb: | Gateway token regenerates on restart | Re-pairing needed |
| 20 | :bulb: | Device pairing required after reconnect | UX friction |
| 32 | :bulb: | Browser automation broken | No Chrome in image |
| 31 | :no_entry: | `diagnostics-otel` extension broken | Blocks GenAI traces |
| 13 | :warning: | Multi-part content format | Breaks downstream tools expecting string content |

Full details: [gotchas-application.md](gotchas-application.md)

### Kagenti / Platform Team

Owner: Kagenti operator + kagenti-extensions

| # | Severity | Gotcha | Impact |
|---|----------|--------|--------|
| 4 | :warning: | Namespace needs `kagenti-enabled=true` label | Silent failure — webhook never fires |
| 11 | :warning: | `spec.trace` doesn't inject OTEL env vars | Trace config does nothing |
| 14 | :warning: | Webhook early return bypasses trace injection | Only when sidecars disabled |
| 26 | :bulb: | Deployment name mismatch in webhook | AgentRuntime lookup fails |
| 21 | :bulb: | AgentRuntime CRD not in Helm chart | Manual install needed |
| 22 | :bulb: | CRDs get stuck terminating | Patch finalizers |
| 27 | :bulb: | AgentCards CRD only from Helm first-install | Don't delete CRDs |
| 23 | :bulb: | Empty secrets cause silent failures | Skill verifies content length |
| 25 | :bulb: | AgentCard SYNCED=False for non-A2A agents | ConfigMap fetcher workaround |

Full details: [gotchas-platform-kagenti.md](gotchas-platform-kagenti.md)

### TrustyAI / Safety Team

Owner: TrustyAI operator + NeMo Guardrails integration in RHOAI

| # | Severity | Gotcha | Impact |
|---|----------|--------|--------|
| 2 | :warning: | `get_colang_history()` crashes on list content | Silent crash after response generated |
| 3 | :warning: | Response format not OpenAI-compatible | 200 OK but empty responses |
| 7 | :warning: | No streaming support | Clients hang or broken pipes |
| 10 | :warning: | RHOAI image missing `langchain-anthropic` | Blocks Anthropic engine |
| 12 | :warning: | Self-check prompt too sensitive to metadata | False positives on normal messages |
| 30 | :no_entry: | `NemoGuardrail` CRD can't add sidecars | Blocks CRD deployment path |

**Path to CRD-based deployment:** 5 steps needed across TrustyAI team and NeMo upstream. See [gotchas-nemo-guardrails.md § Path to TrustyAI Service Operator](gotchas-nemo-guardrails.md#path-to-trustyai-service-operator-crd-based-deployment).

Full details: [gotchas-nemo-guardrails.md](gotchas-nemo-guardrails.md)

### MLflow / Observability Team

Owner: MLflow operator + OTEL integration

| # | Severity | Gotcha | Impact |
|---|----------|--------|--------|
| 5 | :warning: | OTLP rejected — port in Host header | Silently drops all traces |
| 29 | :no_entry: | Traces HTTP-level only, not GenAI-level | No prompts, completions, or token counts |
| 33 | :bulb: | OTEL export errors are silent | Set OTEL_LOG_LEVEL=debug |
| 34 | :bulb: | No OTEL Collector | Deploy for production |
| 35 | :bulb: | Guardrails latency appears as LLM latency | Need span label separation |
| 24 | :bulb: | Experiment ID must be header | Preload script handles it |

Full details: [gotchas-mlflow-tracing.md](gotchas-mlflow-tracing.md)

### OpenShift Sandboxed Containers / Security Team

Owner: OpenShift sandboxed containers operator team

| # | Severity | Gotcha | Impact |
|---|----------|--------|--------|
| 1 | :no_entry: | Native Kata doesn't work on AWS cloud VMs | Must use peer pods or bare metal |
| 6 | :warning: | Port 15150 not open — peer pod unreachable | Dead end without SG access |
| 8 | :warning: | Pod VM AMI creation fails on S3/IAM | No retry, fragile auto-provisioning |
| 9 | :warning: | `peer-pods-cm` must exist before KataConfig | No reconciliation, costs a reboot to fix |
| 15 | :warning: | KataConfig deletion stuck on finalizer | Blocks cluster cleanup |
| 18 | :bulb: | KataConfig reboots worker nodes | Use kataConfigPoolSelector |
| 28 | :no_entry: | 4,000 sandboxed pods impractical | Design constraint |

Full details: [gotchas-sandboxed-containers.md](gotchas-sandboxed-containers.md)
