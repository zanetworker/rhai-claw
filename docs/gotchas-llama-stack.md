# Llama Stack Gotchas

Issues encountered using Llama Stack / vLLM as the inference backend for NeMo Guardrails safety evaluation.

## Severity

| Rating | Icon | Meaning |
|--------|------|---------|
| **Dead end** | :no_entry: | No workaround on this path. Must change approach. |
| **Surprising** | :warning: | Not obvious from docs. Costs hours. |
| **Obvious** | :bulb: | Expected if you know the tech. |

## What We Tested

We pointed NeMo Guardrails at the cluster's self-hosted vLLM endpoint (Llama 3.2 3B Instruct served via KServe InferenceService) to eliminate external API calls for guardrail safety checks. The goal: fully on-cluster agent safety with zero dependency on OpenAI or Anthropic APIs.

```
NeMo Guardrails (engine: openai, api_base: vLLM endpoint)
    │
    ▼ POST /v1/chat/completions
    │
vLLM (Llama 3.2 3B Instruct, A10G GPU)
    │
    ▼ Returns: OpenAI-format response
```

This works mechanically — NeMo sends requests, vLLM responds. But the model quality determines whether the safety rails actually function.

## Surprising

### 1. 3B model silently breaks safety rails — no errors, no warnings :warning:

NeMo Guardrails' self-check rails depend on the LLM answering "Yes" (block) or "No" (allow) to a structured policy prompt. Llama 3.2 3B Instruct is too small to follow these instructions reliably:

- **Self-check input rail:** Always returns "No" (don't block) regardless of content. Profanity, env var extraction, data exfiltration — all pass through.
- **Response generation:** Ignores the user's actual question. Returns generic "Hello! How can I assist you today?" for everything.
- **No error anywhere:** NeMo doesn't validate the model's self-check answer. A wrong answer silently disables the guardrail.

This is dangerous because the guardrails appear to be running (logs show rail execution, latency looks normal) but they're not actually protecting anything.

**Minimum model requirements for guardrail self-checks:**

| Model size | Self-check accuracy | Notes |
|-----------|-------------------|-------|
| 3B (Llama 3.2 3B) | Broken | Can't follow policy prompts |
| 8B (Llama 3.1 8B) | Functional | Minimum viable for self-checks |
| 8B safety (Granite Guardian, Llama Guard) | Good | Purpose-built for content classification |
| 70B+ (Llama 3.1 70B) | Excellent | Best quality, needs multi-GPU |

### 2. KServe headless service not reachable from other namespaces :warning:

The KServe InferenceService creates a headless Service (`ClusterIP: None`) for the predictor. From the `openclaw` namespace, connecting to `llama3-2-8b-predictor.test.svc.cluster.local:80` fails with `Connection refused`.

**Root cause:** Headless services resolve to pod IPs directly, but the port mapping (80 → 8080) doesn't apply the same way as with regular ClusterIP services.

**Workaround:** Use the external Route instead:
```
https://llama3-2-8b-test.apps.cluster-nrpwk.nrpwk.sandbox2474.opentlc.com/v1
```

This works from inside the cluster but adds TLS overhead and goes through the router.

### 3. Multiple stuck predictor pods accumulate :bulb:

The KServe InferenceService keeps creating new predictor pods when the GPU node has issues (node restart, OOM, scheduling failures). Old pods stay in `Init:ContainerStatusUnknown` indefinitely. On our cluster, 4 out of 5 predictor pods were stuck:

When tailing logs, `oc logs -f -l serving.kserve.io/inferenceservice=<name>` may attach to a stuck pod instead of the running one. Target the specific running pod by name instead.

## Configuration: NeMo + vLLM

To point NeMo Guardrails at a vLLM endpoint, use `engine: openai` with a custom `openai_api_base`:

```yaml
models:
  - type: main
    engine: openai
    model: llama3-2-8b                    # must match vLLM's model ID
    parameters:
      openai_api_base: https://llama3-2-8b-test.apps.cluster.example.com/v1
      openai_api_key: none                # vLLM doesn't need auth (unless OAuth proxy)
```

Verify the model ID first:
```bash
curl -sk https://<vllm-route>/v1/models | jq '.data[0].id'
```

The model ID must exactly match what vLLM serves — it's the `id` field from `/v1/models`, not the HuggingFace model name.

## Deploying a Dedicated Llama Stack Instance

Create a separate LlamaStackDistribution for guardrails inference. Deploy it in the same namespace as your vLLM models so it can reach them via internal service.

**1. Create the config ConfigMap:**

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: llama-stack-guardrails-config
  namespace: <MODEL_NAMESPACE>    # same ns as your InferenceService
data:
  config.yaml: |
    version: "2"
    image_name: rh
    apis:
      - inference
    providers:
      inference:
        - provider_id: vllm-local
          provider_type: remote::vllm
          config:
            base_url: http://<ISVC_NAME>-predictor.<MODEL_NAMESPACE>.svc.cluster.local:8080/v1
            api_token: fake
            max_tokens: 4096
            tls_verify: false
        - provider_id: openai-hosted
          provider_type: remote::openai
          config:
            api_key: ${env.OPENAI_API_KEY}
      safety: []
    metadata_store:
      type: sqlite
      db_path: /opt/app-root/src/.llama/distributions/rh/inference_store.db
```

**2. Create the LlamaStackDistribution CR:**

```yaml
apiVersion: llamastack.io/v1alpha1
kind: LlamaStackDistribution
metadata:
  name: lsd-guardrails
  namespace: <MODEL_NAMESPACE>
spec:
  replicas: 1
  server:
    containerSpec:
      env:
        - name: OPENAI_API_KEY
          valueFrom:
            secretKeyRef:
              name: llm-keys
              key: openai
      name: llama-stack
      port: 8321
      resources:
        requests:
          cpu: 250m
          memory: 500Mi
        limits:
          cpu: "1"
          memory: 2Gi
    distribution:
      name: rh-dev
    userConfig:
      configMapName: llama-stack-guardrails-config
```

**3. Point NeMo Guardrails at the dedicated instance:**

```yaml
# guardrails config.yaml
models:
  - type: main
    engine: openai
    model: openai-hosted/gpt-4o-mini     # or vllm-local/<model-id>
    parameters:
      openai_api_base: http://lsd-guardrails-service.<MODEL_NAMESPACE>.svc.cluster.local:8321/v1
      openai_api_key: none
```

**Available models through this instance:**

| Model ID | Provider | Backend | Min size for guardrails |
|----------|----------|---------|------------------------|
| `vllm-local/<model-id>` | `remote::vllm` | Self-hosted GPU | 8B+ required |
| `openai-hosted/gpt-4o-mini` | `remote::openai` | OpenAI API | Works well |
| `openai-hosted/gpt-4o` | `remote::openai` | OpenAI API | Excellent |

Swap between self-hosted and remote by changing the model ID in the guardrails config. Same Llama Stack endpoint, same API.

## Configuring Llama Stack as Universal Inference Gateway

Llama Stack can serve as the single inference endpoint for NeMo Guardrails, routing to either self-hosted models (vLLM) or remote providers (OpenAI) through the same API. NeMo doesn't know which backend is active — it just talks `/v1/chat/completions`.

### What we changed

The default `LlamaStackDistribution` config only has a `remote::vllm` provider. To add OpenAI:

**1. Add `remote::openai` provider to `llama-stack-config` ConfigMap:**

```yaml
providers:
  inference:
    # Existing vLLM provider (self-hosted)
    - provider_id: vllm-inference-1
      provider_type: remote::vllm
      config:
        base_url: http://llama3-2-8b-predictor.test.svc.cluster.local:8080/v1
        api_token: fake
        max_tokens: 4096

    # New: OpenAI provider (remote/hosted)
    - provider_id: openai-hosted
      provider_type: remote::openai
      config:
        api_key: ${env.OPENAI_API_KEY}
```

**2. Add `OPENAI_API_KEY` env var to the Llama Stack deployment:**

```bash
# Create secret in the Llama Stack namespace
oc create secret generic llm-keys -n <LS_NAMESPACE> --from-literal=openai=$OPENAI_API_KEY

# Patch the deployment
oc patch deployment <LSD_NAME> -n <LS_NAMESPACE> --type=json -p '[
  {"op":"add","path":"/spec/template/spec/containers/0/env/-","value":{
    "name":"OPENAI_API_KEY",
    "valueFrom":{"secretKeyRef":{"name":"llm-keys","key":"openai"}}
  }}
]'
```

**3. Llama Stack auto-discovers all OpenAI models** — no manual registration needed. After restart, `/v1/models` returns both:

| Model ID | Provider | Backend |
|----------|----------|---------|
| `vllm-inference-1/llama3-2-8b` | `remote::vllm` | Self-hosted GPU |
| `openai-hosted/gpt-4o-mini` | `remote::openai` | OpenAI API |

**4. Point NeMo Guardrails at Llama Stack:**

```yaml
# guardrails config.yaml
models:
  - type: main
    engine: openai
    model: openai-hosted/gpt-4o-mini     # or vllm-inference-1/llama3-2-8b
    parameters:
      openai_api_base: http://lsd-genai-playground-service.<LS_NAMESPACE>.svc.cluster.local:8321/v1
      openai_api_key: none
```

### Switching between backends

To switch NeMo from OpenAI to self-hosted, change one line in the guardrails config:

```yaml
# Remote (OpenAI via Llama Stack)
model: openai-hosted/gpt-4o-mini

# Self-hosted (vLLM via Llama Stack)
model: vllm-inference-1/llama3-2-8b
```

Same Llama Stack endpoint, same API, different backend. Restart the NeMo pod to pick up the change.

**Caveat:** Self-hosted models must be 8B+ for guardrail self-checks to work (see gotcha #1 above). The 3B model on this cluster silently fails to evaluate safety rails.

## Recommended Setup

For self-hosted guardrail evaluation that actually works:

1. **Serve an 8B+ model** on vLLM (e.g., Llama 3.1 8B Instruct, Granite Guardian 8B)
2. **Or use a dedicated safety model** like Llama Guard 3 8B alongside the main model
3. **Point NeMo at the 8B+ model** for rail evaluation, while OpenClaw uses whatever model the user wants for actual generation
4. **Test the self-check rails** with the test prompts before going live — don't assume the model works

The A10G GPU (24GB VRAM) on this cluster can serve up to ~8B parameter models with half precision. For 70B you'd need multi-GPU (A100s).
