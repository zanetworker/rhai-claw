# Gotchas by Team

Everything below was discovered deploying OpenClaw with Kagenti, NeMo Guardrails, sandboxed containers, and MLflow tracing. The `/deploy-openclaw` skill handles most of them automatically — these are documented so each team knows what to fix upstream.

## Severity Ratings

| Rating | Icon | Meaning |
|--------|------|---------|
| **Dead end** | :no_entry: | No workaround on this path. Must change approach entirely. |
| **Surprising** | :warning: | Not obvious from docs. Costs hours of debugging. Poor error messages or silent failures. |
| **Obvious** | :bulb: | Expected if you understand the technology. Documented, discoverable. |

## Priority: All Gotchas Ranked

The top gotchas across all teams, ranked by how likely they are to block you and how long you'll spend before figuring it out.

| # | Severity | Team | Gotcha | Potential UX time cost |
|---|----------|------|--------|------------------------|
| 1 | :no_entry: | [TrustyAI / NeMo](#trustyai--safety-team) | [NeMo only accepts OpenAI format — can't guard Anthropic Messages API traffic](gotchas-nemo-guardrails.md#8-nemo-guardrails-only-accepts-openai-format--cant-guard-anthropic-messages-api-traffic-no_entry) | Agents using Anthropic directly bypass guardrails entirely |
| 2 | :no_entry: | [TrustyAI / NeMo](#trustyai--safety-team) | [`NemoGuardrail` CRD can't add sidecars or command overrides](gotchas-nemo-guardrails.md#6-nemoguardrail-crd-doesnt-support-custom-commands-no_entry) | Blocks CRD-based deployment |
| 3 | :no_entry: | [MLflow](#mlflow--observability-team) | [Traces are HTTP-level only, not GenAI-level](gotchas-mlflow-tracing.md#current-state-http-level-traces-only-no_entry) | Architectural gap — see 3 paths |
| 4 | :no_entry: | [OpenClaw](#openclaw--agent-team) | [`diagnostics-otel` extension broken in image](gotchas-application.md#diagnostics-otel-extension-broken-in-image-no_entry) | Blocks GenAI traces via Path 1 |
| 5 | :warning: | [TrustyAI / NeMo](#trustyai--safety-team) | [No streaming — crashes on `self.stop=None` via Llama Stack](gotchas-nemo-guardrails.md#3-no-streaming-support-warning) | NeMo bug, Llama Stack trigger. Adapter works around it. |
| 6 | :warning: | [TrustyAI / NeMo](#trustyai--safety-team) | [NeMo depends on LangChain for LLM access — provider lock-in](gotchas-nemo-guardrails.md#7-nemo-guardrails-depends-on-langchain-for-llm-access-warning) | Limits which models can evaluate safety. Explore Llama Stack. |
| 7 | :warning: | [TrustyAI / NeMo](#trustyai--safety-team) | [RHOAI image missing `langchain-anthropic` — blocks Anthropic engine](gotchas-nemo-guardrails.md#4-rhoai-image-missing-langchain-anthropic-warning) | 30 min — blocks Anthropic as guardrail evaluator |
| 8 | :warning: | [TrustyAI / NeMo](#trustyai--safety-team) | [Self-check prompt flags agent metadata as attacks](gotchas-nemo-guardrails.md#5-self-check-prompt-too-sensitive-to-agent-metadata-warning) | 30 min — false positives on every message |
| | ✅ | [TrustyAI / NeMo](#trustyai--safety-team) | [~~`get_colang_history()` crashes on multi-part content~~](gotchas-nemo-guardrails.md#2-multi-part-content-crashes-get_colang_history-warning) | **FIXED in 0.20.0 nightly** |
| | ✅ | [TrustyAI / NeMo](#trustyai--safety-team) | [~~Response format not OpenAI-compatible~~](gotchas-nemo-guardrails.md#1-response-format-mismatch-nemo-vs-openai-warning) | **FIXED in 0.20.0 nightly** |
| 11 | :warning: | [Llama Stack / Inference](#llama-stack--inference-team) | [3B model silently breaks safety rails — guardrails are theater](gotchas-llama-stack.md#1-3b-model-silently-breaks-safety-rails--no-errors-no-warnings-warning) | No errors, no warnings, rails just don't work |
| 12 | :warning: | [Kagenti](#kagenti--platform-team) | [Namespace needs `kagenti-enabled=true` — completely silent failure](gotchas-platform-kagenti.md#namespace-needs-kagenti-enabledtrue-label-warning) | 2+ hours — no errors anywhere |
| 13 | :warning: | [MLflow](#mlflow--observability-team) | [OTLP rejected due to port in Host header — silently drops all traces](gotchas-mlflow-tracing.md#1-mlflow-rejects-otlp-with-port-in-host-header-warning) | 2+ hours — zero indication of failure |
| 14 | :warning: | [OpenClaw](#openclaw--agent-team) | [Multi-part content format breaks downstream tools](gotchas-application.md#multi-part-content-format-breaks-downstream-tools-warning) | 1+ hours — linked to NeMo crash (#5) |
| 15 | :warning: | [Kagenti](#kagenti--platform-team) | [`spec.trace` doesn't inject OTEL env vars — webhook bug](gotchas-platform-kagenti.md#spectrace-doesnt-inject-otel-env-vars-warning) | 1+ hours — trace config exists but does nothing |
| 16 | :warning: | [Kagenti](#kagenti--platform-team) | [Webhook early return bypasses trace injection](gotchas-platform-kagenti.md#webhook-early-return-bypasses-trace-injection-warning) | 1 hour — only when sidecars disabled |
| 17 | :warning: | [Llama Stack / Inference](#llama-stack--inference-team) | [KServe headless service not reachable cross-namespace](gotchas-llama-stack.md#2-kserve-headless-service-not-reachable-from-other-namespaces-warning) | Must use Route instead of internal service |
| 18 | :warning: | [Sandboxed Containers](#openshift-sandboxed-containers--security-team) | [Port 15150 not in SG — peer pod VM created but unreachable](gotchas-sandboxed-containers.md#4-port-15150-not-open--peer-pod-created-but-unreachable) | 1-2 hours — looks like it should work |
| 19 | :warning: | [Sandboxed Containers](#openshift-sandboxed-containers--security-team) | [Pod VM AMI creation fails on S3/IAM — no retry](gotchas-sandboxed-containers.md#3-pod-vm-ami-creation-fails-silently-on-iams3-issues) | 1-2 hours — fragile auto-provisioning |
| 20 | :warning: | [Sandboxed Containers](#openshift-sandboxed-containers--security-team) | [`peer-pods-cm` must exist BEFORE KataConfig — no reconciliation](gotchas-sandboxed-containers.md#7-peer-pods-cm-must-exist-before-kataconfig) | 1 hour + 20 min reboot to fix |
| 21 | :warning: | [Sandboxed Containers](#openshift-sandboxed-containers--security-team) | [KataConfig deletion stuck on finalizer](gotchas-sandboxed-containers.md#5-kataconfig-deletion-stuck-on-finalizer) | 30 min — blocks cluster cleanup |
| 22 | :bulb: | [Sandboxed Containers](#openshift-sandboxed-containers--security-team) | [Native Kata doesn't work on AWS cloud VMs — no nested virt](gotchas-sandboxed-containers.md#1-native-kata-needs-bare-metal--no-nested-virt-on-aws) | Expected — Kata = hardware virt, cloud VMs = no nested virt |
| 23 | :bulb: | [Sandboxed Containers](#openshift-sandboxed-containers--security-team) | [Hundreds of sandboxed agents impractical](gotchas-sandboxed-containers.md#6-scaling-sandboxed-pods-is-impractical) | Design constraint — VM overhead per pod |
| 24 | :bulb: | [OpenClaw](#openclaw--agent-team) | [Binds to loopback by default — unreachable in K8s](gotchas-application.md#binds-to-loopback-by-default-bulb) | 30 min |
| 25 | :bulb: | [OpenClaw](#openclaw--agent-team) | [Hardcoded port 18789 — ignores PORT env var](gotchas-application.md#hardcoded-port-18789-bulb) | 15 min |
| 26 | :bulb: | [Kagenti](#kagenti--platform-team) | [AgentCard SYNCED=False for non-A2A agents](gotchas-platform-kagenti.md#agentcard-syncedfalse-for-non-a2a-agents-bulb) | 15 min — ConfigMap pattern |
| 27 | :bulb: | [Sandboxed Containers](#openshift-sandboxed-containers--security-team) | [KataConfig reboots worker nodes (10-60 min)](gotchas-sandboxed-containers.md#2-kataconfig-reboots-worker-nodes-10-60-min) | Expected, but painful without kataConfigPoolSelector |
| 28 | :bulb: | [Kagenti](#kagenti--platform-team) | [Empty secrets cause silent failures](gotchas-platform-kagenti.md#empty-secrets-cause-silent-failures-bulb) | 10 min |
| 29 | :bulb: | [OpenClaw](#openclaw--agent-team) | [Gateway token regenerates on restart](gotchas-application.md#gateway-token-regenerates-on-every-restart-bulb) | 5 min per restart |
| 30 | :bulb: | [Kagenti](#kagenti--platform-team) | [AgentRuntime CRD not in Helm chart](gotchas-platform-kagenti.md#agentruntime-crd-not-in-helm-chart-bulb) | 5 min — CRD exists but Helm chart doesn't package it |
| 31 | :bulb: | [Kagenti](#kagenti--platform-team) | [CRDs get stuck terminating](gotchas-platform-kagenti.md#crds-get-stuck-terminating-bulb) | 5 min — patch finalizers |
| 32 | :bulb: | [MLflow](#mlflow--observability-team) | [Experiment ID must be header](gotchas-mlflow-tracing.md#3-mlflow-experiment-id-must-be-passed-as-header-bulb) | 5 min |
| 33 | :bulb: | [OpenClaw](#openclaw--agent-team) | [Device pairing required after reconnect](gotchas-application.md#device-pairing-required-after-every-reconnect-bulb) | UX friction, but adds security (prevents unauthorized access) |
| 34 | :warning: | [Kagenti](#kagenti--platform-team) | [Deployment name mismatch in webhook](gotchas-platform-kagenti.md#deployment-name-mismatch-in-webhook-warning) | Still open — Phase 2 (issue #177) |
| 35 | :bulb: | [Kagenti](#kagenti--platform-team) | [AgentCards CRD only from Helm first-install](gotchas-platform-kagenti.md#agentcards-crd-only-from-helm-first-install-bulb) | Avoid deleting CRDs |
| 36 | :bulb: | [OpenClaw](#openclaw--agent-team) | [Browser automation broken in container](gotchas-application.md#browser-automation-broken-bulb) | No Chrome in image |
| 37 | :bulb: | [MLflow](#mlflow--observability-team) | [OTEL export errors are silent](gotchas-mlflow-tracing.md#2-otel-export-errors-are-silent-warning) | Set OTEL_LOG_LEVEL=debug |
| 38 | :bulb: | [MLflow](#mlflow--observability-team) | [No OTEL Collector — direct export](gotchas-mlflow-tracing.md#4-no-otel-collector--direct-export-only-bulb) | Deploy Collector for production |
| 39 | :bulb: | [MLflow](#mlflow--observability-team) | [Guardrails latency appears as LLM latency](gotchas-mlflow-tracing.md#5-guardrails-latency-appears-as-llm-latency-bulb) | Need span label separation |
| 40 | :bulb: | [Llama Stack / Inference](#llama-stack--inference-team) | [Stuck predictor pods accumulate](gotchas-llama-stack.md#3-multiple-stuck-predictor-pods-accumulate-bulb) | Log tailing attaches to wrong pod |

## By Team

### OpenClaw / Agent Team

Owner: OpenClaw upstream

| # | Severity | Gotcha | Impact |
|---|----------|--------|--------|
| 31 | :no_entry: | `diagnostics-otel` extension broken | Blocks GenAI traces |
| 13 | :warning: | Multi-part content format | Breaks downstream tools expecting string content |
| 16 | :bulb: | Binds to loopback by default | Agent unreachable in K8s |
| 17 | :bulb: | Hardcoded port 18789 | `PORT` env var ignored |
| 19 | :bulb: | Gateway token regenerates on restart | Re-pairing needed |
| 20 | :bulb: | Device pairing required after reconnect | UX friction, but adds security |
| 32 | :bulb: | Browser automation broken | No Chrome in image |

Full details: [gotchas-application.md](gotchas-application.md)

### Kagenti / Platform Team

Owner: Kagenti operator + kagenti-extensions

| # | Severity | Gotcha | Impact |
|---|----------|--------|--------|
| 4 | :warning: | Namespace needs `kagenti-enabled=true` label | Silent failure — webhook never fires |
| 11 | :warning: | `spec.trace` doesn't inject OTEL env vars | Trace config does nothing |
| 14 | :warning: | Webhook early return bypasses trace injection | Only when sidecars disabled |
| 26 | :warning: | Deployment name mismatch in webhook | AgentRuntime lookup fails — Phase 2 (issue #177) |
| 21 | :bulb: | AgentRuntime CRD not in Helm chart | CRD exists but chart doesn't package it |
| 22 | :bulb: | CRDs get stuck terminating | Patch finalizers |
| 23 | :bulb: | Empty secrets cause silent failures | Skill verifies content length |
| 25 | :bulb: | AgentCard SYNCED=False for non-A2A agents | ConfigMap fetcher workaround |
| 27 | :bulb: | AgentCards CRD only from Helm first-install | Don't delete CRDs |

Full details: [gotchas-platform-kagenti.md](gotchas-platform-kagenti.md)

**Onboarding feedback:** Webhook complexity, AgentRuntime-per-Deployment friction, developer mandates (env vars, identity), lean mode proposal. See [gotchas-kagenti-onboarding.md](gotchas-kagenti-onboarding.md).

### TrustyAI / Safety Team

Owner: TrustyAI operator + NeMo Guardrails integration in RHOAI

| # | Severity | Gotcha | Impact |
|---|----------|--------|--------|
| 37 | :no_entry: | NeMo only accepts OpenAI format — can't guard Anthropic Messages API traffic | Agents using Anthropic directly bypass guardrails |
| 30 | :no_entry: | `NemoGuardrail` CRD can't add sidecars | Blocks CRD deployment path |
| 7 | :warning: | No streaming support | 0.20.0 added flag but crashes on `self.stop=None` via Llama Stack |
| 36 | :warning: | NeMo depends on LangChain for LLM access | Provider lock-in, explore Llama Stack / vLLM alternatives |
| 10 | :warning: | RHOAI image missing `langchain-anthropic` | Blocks Anthropic engine |
| 12 | :warning: | Self-check prompt too sensitive to metadata | False positives on normal messages |
| | ✅ | ~~`get_colang_history()` crashes on list content~~ | **FIXED in 0.20.0 nightly** |
| | ✅ | ~~Response format not OpenAI-compatible~~ | **FIXED in 0.20.0 nightly** |

**Adapter still needed:** [Why the adapter exists](nemo-adapter-why.md). Streaming and content normalization still require it as of 0.20.0.

**Path to CRD-based deployment:** 5 steps needed across TrustyAI team and NeMo upstream. See [gotchas-nemo-guardrails.md § Path to TrustyAI Service Operator](gotchas-nemo-guardrails.md#path-to-trustyai-service-operator-crd-based-deployment).

Full details: [gotchas-nemo-guardrails.md](gotchas-nemo-guardrails.md)

### MLflow / Observability Team

Owner: MLflow operator + OTEL integration

| # | Severity | Gotcha | Impact |
|---|----------|--------|--------|
| 29 | :no_entry: | Traces HTTP-level only, not GenAI-level | No prompts, completions, or token counts |
| 5 | :warning: | OTLP rejected — port in Host header | Silently drops all traces |
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
| 28 | :no_entry: | Hundreds of sandboxed agents impractical | Design constraint |
| 6 | :warning: | Port 15150 not open — peer pod unreachable | Dead end without SG access |
| 8 | :warning: | Pod VM AMI creation fails on S3/IAM | No retry, fragile auto-provisioning |
| 9 | :warning: | `peer-pods-cm` must exist before KataConfig | No reconciliation, costs a reboot to fix |
| 15 | :warning: | KataConfig deletion stuck on finalizer | Blocks cluster cleanup |
| 18 | :bulb: | KataConfig reboots worker nodes | Use kataConfigPoolSelector |

Full details: [gotchas-sandboxed-containers.md](gotchas-sandboxed-containers.md)

### Llama Stack / Inference Team

Owner: Llama Stack operator + vLLM / KServe

| # | Severity | Gotcha | Impact |
|---|----------|--------|--------|
| 38 | :warning: | 3B model silently breaks safety rails | Guardrails appear to run but block nothing — no errors |
| 39 | :warning: | KServe headless service not reachable cross-namespace | Must use Route instead of internal service |
| 40 | :bulb: | Stuck predictor pods accumulate | Log tailing hits wrong pod |
Full details: [gotchas-llama-stack.md](gotchas-llama-stack.md)
