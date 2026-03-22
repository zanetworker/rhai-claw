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

```
llama3-2-8b-predictor-679bcc4888-68bv5   0/2     Init:ContainerStatusUnknown
llama3-2-8b-predictor-679bcc4888-9wtwn   0/2     Init:ContainerStatusUnknown
llama3-2-8b-predictor-679bcc4888-c7b6s   0/2     Init:ContainerStatusUnknown
llama3-2-8b-predictor-679bcc4888-fk6t6   0/2     Init:ContainerStatusUnknown
llama3-2-8b-predictor-679bcc4888-x8gwk   2/2     Running                        ← only one working
```

When tailing logs, `oc logs -f -l serving.kserve.io/inferenceservice=llama3-2-8b` may attach to a stuck pod instead of the running one. You need to target the specific running pod by name.

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

## Recommended Setup

For self-hosted guardrail evaluation that actually works:

1. **Serve an 8B+ model** on vLLM (e.g., Llama 3.1 8B Instruct, Granite Guardian 8B)
2. **Or use a dedicated safety model** like Llama Guard 3 8B alongside the main model
3. **Point NeMo at the 8B+ model** for rail evaluation, while OpenClaw uses whatever model the user wants for actual generation
4. **Test the self-check rails** with the test prompts before going live — don't assume the model works

The A10G GPU (24GB VRAM) on this cluster can serve up to ~8B parameter models with half precision. For 70B you'd need multi-GPU (A100s).
