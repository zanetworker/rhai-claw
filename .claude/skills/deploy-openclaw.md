---
name: deploy-openclaw
description: Deploy OpenClaw on Kubernetes with the Kagenti operator, webhook, MLflow tracing, and A2A agent card. Handles every gotcha automatically. Run this after connecting to a Kubernetes cluster.
---

# Deploy OpenClaw

One skill to deploy OpenClaw on Kagenti with full observability.

## Prerequisites

- `kubectl` connected to a Kubernetes/OpenShift cluster
- `helm` v4+ installed

## Steps

Follow these steps sequentially. Report the output of each step.

### 1. Check cluster connectivity and permissions

Run: `kubectl cluster-info`

If this fails, stop and tell the user to configure kubectl access.

Then check if the user has cluster-admin:
```bash
kubectl auth can-i create crd 2>/dev/null && echo "CLUSTER_ADMIN=true" || echo "CLUSTER_ADMIN=false"
```

If **not cluster-admin**, check that the platform prerequisites are already installed:
```bash
kubectl get ns kagenti-system 2>/dev/null && echo "Operator: OK" || echo "Operator: MISSING"
kubectl get crd agentruntimes.agent.kagenti.dev 2>/dev/null && echo "AgentRuntime CRD: OK" || echo "AgentRuntime CRD: MISSING"
kubectl get crd agentcards.agent.kagenti.dev 2>/dev/null && echo "AgentCards CRD: OK" || echo "AgentCards CRD: MISSING"
kubectl get ns kagenti-webhook-system 2>/dev/null && echo "Webhook: OK" || echo "Webhook: MISSING"
```

If anything is MISSING, tell the user:

> "You don't have cluster-admin permissions. The following platform components need to be installed by your cluster administrator before you can proceed:
>
> **Ask your platform team to run:**
> 1. Install the Kagenti operator: `helm install kagenti-operator oci://ghcr.io/kagenti/kagenti-operator/kagenti-operator-chart --version 0.2.0-alpha.22 --namespace kagenti-system --create-namespace`
> 2. Install the AgentRuntime CRD: `kubectl apply -f https://raw.githubusercontent.com/kagenti/kagenti-operator/main/kagenti-operator/config/crd/bases/agent.kagenti.dev_agentruntimes.yaml`
> 3. Install the webhook: `kubectl apply -f manifests/webhook/webhook-all.yaml` (from the kagenti-claw repo)
> 4. Create and label your namespace: `kubectl create ns <NAMESPACE> && kubectl label namespace <NAMESPACE> kagenti-enabled=true`
>
> Once these are in place, re-run `/deploy-openclaw`."

Then **stop**. Do not proceed without the platform prerequisites.

If cluster-admin or all prerequisites are present, continue.

### 2. Choose namespace

Ask the user what namespace to deploy into. Default: `openclaw`.

Do NOT reuse an existing namespace that has other workloads. If the chosen namespace already exists, warn the user and ask if they want to continue or pick a different one.

### 3. Check for stale resources

Check if any kagenti-claw resources already exist in the chosen namespace:
```bash
kubectl get deploy openclaw -n <NAMESPACE> 2>/dev/null
kubectl get agentruntime openclaw -n <NAMESPACE> 2>/dev/null
kubectl get agentcard -n <NAMESPACE> 2>/dev/null
```

If any exist, ask the user: "Previous deployment detected. Delete and redeploy, or abort?" If they choose to redeploy, delete the existing resources first.

Also check for terminating CRDs — these block new CR creation:
```bash
kubectl get crd agentruntimes.agent.kagenti.dev -o jsonpath='{.metadata.deletionTimestamp}' 2>/dev/null
kubectl get crd agentcards.agent.kagenti.dev -o jsonpath='{.metadata.deletionTimestamp}' 2>/dev/null
```

If a CRD is terminating, remove its finalizers and wait for deletion before proceeding:
```bash
kubectl patch crd <CRD_NAME> --type=json -p '[{"op":"remove","path":"/metadata/finalizers"}]'
sleep 5
```

### 4. Install Kagenti operator (cluster-admin only)

Skip this step if the operator is already installed or if the user doesn't have cluster-admin (step 1 verified prerequisites).

The operator Helm chart is published as an OCI artifact from [kagenti-operator](https://github.com/kagenti/kagenti-operator) CI to `ghcr.io/kagenti/kagenti-operator/`. Check [GitHub releases](https://github.com/kagenti/kagenti-operator/releases) for the latest version.

Check: `kubectl get ns kagenti-system`

If not installed:
```bash
DOCKER_CONFIG=$(mktemp -d) && echo '{}' > "$DOCKER_CONFIG/config.json" && \
DOCKER_CONFIG=$DOCKER_CONFIG helm install kagenti-operator \
  oci://ghcr.io/kagenti/kagenti-operator/kagenti-operator-chart \
  --version 0.2.0-alpha.22 \
  --namespace kagenti-system \
  --create-namespace
```

Note: The `DOCKER_CONFIG` workaround avoids `docker-credential-desktop` errors on macOS when pulling OCI charts. It creates a temp config so Helm skips the credential store (the chart is public, no auth needed).

Wait: `kubectl wait --for=condition=available deployment/kagenti-controller-manager -n kagenti-system --timeout=120s`

### 5. Install CRDs (cluster-admin only)

Skip if already present (step 1 verified).

Check for BOTH required CRDs:
```bash
kubectl get crd agentruntimes.agent.kagenti.dev 2>/dev/null
kubectl get crd agentcards.agent.kagenti.dev 2>/dev/null
```

The `agentcards` CRD is installed by the operator Helm chart. If it's missing (e.g., after a manual CRD deletion), the operator needs to be reinstalled: `helm uninstall kagenti-operator -n kagenti-system` then re-run step 4.

The `agentruntimes` CRD is NOT in the Helm chart yet — install it manually if missing:
```bash
kubectl apply -f https://raw.githubusercontent.com/kagenti/kagenti-operator/main/kagenti-operator/config/crd/bases/agent.kagenti.dev_agentruntimes.yaml
```

### 6. Install kagenti-extensions webhook (cluster-admin only)

Skip if already present (step 1 verified).

Check: `kubectl get ns kagenti-webhook-system`

If not installed:
```bash
kubectl apply -f manifests/webhook/webhook-all.yaml
```

Wait: `kubectl wait --for=condition=available deployment/kagenti-webhook-controller-manager -n kagenti-webhook-system --timeout=120s`

### 7. Create and label namespace (cluster-admin only)

Skip if namespace already exists and is labeled (step 1 verified).

```bash
kubectl create ns <NAMESPACE> 2>/dev/null || true
kubectl label namespace <NAMESPACE> kagenti-enabled=true --overwrite
```

### 8. Set up LLM API key

Check if an `llm-keys` secret exists in the namespace:
```bash
kubectl get secret llm-keys -n <NAMESPACE>
```

If found, verify it has non-empty content:
```bash
kubectl get secret llm-keys -n <NAMESPACE> -o jsonpath='{.data.anthropic}' | wc -c
```

If the character count is 0, the secret exists but is empty (likely created with `$ANTHROPIC_API_KEY` unset). Delete it and ask the user to recreate:
```bash
kubectl delete secret llm-keys -n <NAMESPACE>
```

If not found or empty, tell the user — **replace `<NAMESPACE>` with the actual chosen namespace name in every command**:

> "OpenClaw needs an Anthropic API key. Create the secret in the **`<NAMESPACE>`** namespace using one of these methods, then tell me to continue.
>
> **Option 1: From environment variable (recommended)**
> ```bash
> # Verify your key is set first:
> echo $ANTHROPIC_API_KEY | head -c10
>
> # Then create the secret (must be in the <NAMESPACE> namespace):
> kubectl create secret generic llm-keys \
>   --from-literal=anthropic=$ANTHROPIC_API_KEY \
>   -n <NAMESPACE>
> ```
>
> **Option 2: Interactive (no env var needed)**
> ```bash
> read -s -p 'Anthropic API key: ' KEY && \
> kubectl create secret generic llm-keys \
>   --from-literal=anthropic=$KEY \
>   -n <NAMESPACE> && \
> unset KEY
> ```
>
> **Option 3: From a YAML file**
> ```yaml
> apiVersion: v1
> kind: Secret
> metadata:
>   name: llm-keys
>   namespace: <NAMESPACE>   # Must match the deployment namespace
> type: Opaque
> data:
>   anthropic: <BASE64_ENCODED_KEY>   # echo -n 'sk-ant-...' | base64
> ```
> ```bash
> kubectl apply -f llm-keys-secret.yaml
> ```"

Then **stop and wait** for the user to confirm. After they confirm, verify both existence AND content:
```bash
kubectl get secret llm-keys -n <NAMESPACE> && \
  echo "Content length:" && \
  kubectl get secret llm-keys -n <NAMESPACE> -o jsonpath='{.data.anthropic}' | wc -c
```

If content length is 0, tell the user the secret is empty and ask them to recreate it.

### 9. Detect MLflow

Search for MLflow on the cluster:
```bash
kubectl get svc -A 2>/dev/null | grep -i mlflow | grep -v minio | grep -v postgresql | grep -v operator
```

If found, extract the service name, namespace, and port:
```bash
MLFLOW_SVC=$(kubectl get svc -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}:{.spec.ports[0].port}{"\n"}{end}' | grep -i mlflow | grep -v minio | grep -v postgresql | grep -v operator | head -1)
```

If not found, ask the user: "No MLflow found on the cluster. Provide the MLflow service endpoint (e.g., `mlflow-service.test.svc.cluster.local:5000`), or press Enter to skip tracing."

If MLflow is available, set `MLFLOW_ENDPOINT` (e.g., `http://mlflow-service.test.svc.cluster.local:5000`). If skipped, set `MLFLOW_ENDPOINT=""`.

### 10. Apply manifests

Apply each manifest individually to the chosen namespace:
```bash
kubectl apply -f manifests/deployment.yaml -n <NAMESPACE>
kubectl apply -f manifests/service.yaml -n <NAMESPACE>
kubectl apply -f manifests/route.yaml -n <NAMESPACE>
kubectl apply -f manifests/agentcard-configmap.yaml -n <NAMESPACE>
kubectl apply -f manifests/otel-tracing-configmap.yaml -n <NAMESPACE>
```

### 11. Apply AgentRuntime

If `MLFLOW_ENDPOINT` is set, create the AgentRuntime with trace config:
```bash
kubectl apply -n <NAMESPACE> -f - <<EOF
apiVersion: agent.kagenti.dev/v1alpha1
kind: AgentRuntime
metadata:
  name: openclaw
spec:
  type: agent
  targetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: openclaw
  trace:
    endpoint: "$MLFLOW_ENDPOINT"
    protocol: http
    sampling:
      rate: 1.0
EOF
```

If no MLflow, apply the base manifest:
```bash
kubectl apply -f manifests/agentruntime.yaml -n <NAMESPACE>
```

### 12. Configure OTEL tracing

If `MLFLOW_ENDPOINT` is set, patch the deployment with OTEL env vars:
```bash
kubectl patch deploy openclaw -n <NAMESPACE> --type=json -p "[
  {\"op\":\"add\",\"path\":\"/spec/template/spec/containers/0/env/-\",\"value\":{\"name\":\"NODE_OPTIONS\",\"value\":\"--require /otel/otel-setup.js\"}},
  {\"op\":\"add\",\"path\":\"/spec/template/spec/containers/0/env/-\",\"value\":{\"name\":\"OTEL_EXPORTER_OTLP_ENDPOINT\",\"value\":\"$MLFLOW_ENDPOINT\"}},
  {\"op\":\"add\",\"path\":\"/spec/template/spec/containers/0/env/-\",\"value\":{\"name\":\"OTEL_SERVICE_NAME\",\"value\":\"openclaw\"}}
]"
```

If no MLflow, skip this step.

### 13. Set up LLM API keys on deployment

Ask the user which LLM provider they want to use for guardrails evaluation. Default: OpenAI (`gpt-4o-mini`).

**OpenAI (recommended — works with RHOAI NeMo image out of the box):**
```bash
kubectl patch deploy openclaw -n <NAMESPACE> --type=json -p '[
  {"op":"add","path":"/spec/template/spec/containers/0/env/-","value":{
    "name":"OPENAI_API_KEY",
    "valueFrom":{"secretKeyRef":{"name":"llm-keys","key":"openai"}}
  }}
]'
```

Verify the `llm-keys` secret has an `openai` key:
```bash
kubectl get secret llm-keys -n <NAMESPACE> -o jsonpath='{.data.openai}' | wc -c
```

If missing, tell the user to add it:
```bash
kubectl patch secret llm-keys -n <NAMESPACE> --type=json -p '[{"op":"add","path":"/data/openai","value":"'$(echo -n $OPENAI_API_KEY | base64)'"}]'
```

**Anthropic (requires workaround — see gotcha #4):**

> **Note:** The RHOAI NeMo Guardrails image does not ship `langchain-anthropic`. Using `engine: anthropic` in the NeMo config requires either:
> - Pip installing `langchain-anthropic` at pod startup (standalone deployment, not CRD) — adds ~15s startup
> - Waiting for the TrustyAI team to add the package to the image
>
> The `engine: anthropic` code path in NeMo uses `langchain-anthropic` → Anthropic Python SDK → Anthropic Messages API (`/v1/messages`). This is a different protocol from OpenAI chat completions (`/v1/chat/completions`). The package is the only blocker — the code works.
>
> If Anthropic is required, use the standalone deployment in `manifests/guardrails-deployment.yaml` instead of the NemoGuardrails CRD.

Also add the Anthropic key if needed for OpenClaw's direct use:
```bash
kubectl patch deploy openclaw -n <NAMESPACE> --type=json -p '[
  {"op":"add","path":"/spec/template/spec/containers/0/env/-","value":{
    "name":"ANTHROPIC_API_KEY",
    "valueFrom":{"secretKeyRef":{"name":"llm-keys","key":"anthropic"}}
  }}
]'
```

### 13b. Detect self-hosted models and set up Llama Stack gateway

Check if the cluster has self-hosted models and Llama Stack:

```bash
kubectl get inferenceservice -A 2>/dev/null
kubectl get llamastackdistributions -A 2>/dev/null
```

If InferenceServices are found, get the model details:
```bash
ISVC_NS=$(kubectl get inferenceservice -A -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null)
ISVC_NAME=$(kubectl get inferenceservice -A -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
ISVC_ROUTE=$(kubectl get inferenceservice -A -o jsonpath='{.items[0].status.url}' 2>/dev/null)
if [ -n "$ISVC_ROUTE" ]; then
  MODEL_ID=$(curl -sk "$ISVC_ROUTE/v1/models" | python3 -c "import sys,json; print(json.load(sys.stdin)['data'][0]['id'])" 2>/dev/null)
  echo "Found model: $MODEL_ID in namespace $ISVC_NS at $ISVC_ROUTE"
fi
```

Ask the user:

> "Found self-hosted model `<MODEL_ID>` in namespace `<ISVC_NS>`.
>
> **Recommended:** Deploy a dedicated Llama Stack instance as the inference gateway for guardrails. This lets you switch between self-hosted and remote models by changing one config line.
>
> **Warning:** Do NOT modify existing Llama Stack instances (e.g., playground). Create a separate one.
>
> **Warning:** Models smaller than 8B parameters are too small for reliable safety evaluation — guardrails will silently fail to block harmful content.
>
> Options:
> 1. **Llama Stack gateway** (recommended) — routes to both self-hosted vLLM and remote OpenAI through one endpoint
> 2. **OpenAI direct** — GPT-4o-mini, simpler but no self-hosted option
> 3. **Skip guardrails** — deploy OpenClaw without safety rails"

**If the user chooses Llama Stack gateway (option 1):**

Create a dedicated Llama Stack instance in the model namespace:

```bash
# Create config for the dedicated Llama Stack instance
kubectl apply -n $ISVC_NS -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: llama-stack-guardrails-config
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
            base_url: http://${ISVC_NAME}-predictor.${ISVC_NS}.svc.cluster.local:8080/v1
            api_token: fake
            max_tokens: 4096
            tls_verify: false
        - provider_id: openai-hosted
          provider_type: remote::openai
          config:
            api_key: \${env.OPENAI_API_KEY}
      safety: []
    metadata_store:
      type: sqlite
      db_path: /opt/app-root/src/.llama/distributions/rh/inference_store.db
EOF
```

Ensure `llm-keys` secret exists in the model namespace:
```bash
kubectl get secret llm-keys -n $ISVC_NS 2>/dev/null || \
  kubectl create secret generic llm-keys -n $ISVC_NS --from-literal=openai=$OPENAI_API_KEY
```

Create the LlamaStackDistribution:
```bash
kubectl apply -n $ISVC_NS -f - <<EOF
apiVersion: llamastack.io/v1alpha1
kind: LlamaStackDistribution
metadata:
  name: lsd-guardrails
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
EOF
```

Wait for the Llama Stack instance to be ready:
```bash
kubectl wait --for=jsonpath='{.status.conditions[?(@.type=="HealthCheck")].status}'=True \
  llamastackdistribution/lsd-guardrails -n $ISVC_NS --timeout=120s
```

Set guardrails variables:
- `GUARDRAILS_MODEL=openai-hosted/gpt-4o-mini` (or `vllm-local/$MODEL_ID` for self-hosted)
- `GUARDRAILS_API_BASE=http://lsd-guardrails-service.$ISVC_NS.svc.cluster.local:8321/v1`
- `GUARDRAILS_API_KEY=none`

**If the user chooses OpenAI direct (option 2):**
- `GUARDRAILS_MODEL=gpt-4o-mini`
- `GUARDRAILS_API_BASE=` (empty, uses default OpenAI URL)
- `GUARDRAILS_API_KEY=${OPENAI_API_KEY}`

### 14. Deploy NeMo Guardrails via TrustyAI operator

Deploy guardrails using the product stack — the TrustyAI `NemoGuardrails` CRD manages the NeMo pod lifecycle.

First, apply the guardrails Colang config:
```bash
kubectl apply -f manifests/guardrails-config.yaml -n <NAMESPACE>
```

Then create the `NemoGuardrails` CR:
```bash
kubectl apply -n <NAMESPACE> -f - <<'EOF'
apiVersion: trustyai.opendatahub.io/v1alpha1
kind: NemoGuardrails
metadata:
  name: openclaw-guardrails
spec:
  env:
    - name: OPENAI_API_KEY
      valueFrom:
        secretKeyRef:
          name: llm-keys
          key: openai
  nemoConfigs:
    - name: openclaw-safety
      default: true
      configMaps:
        - openclaw-guardrails-config
EOF
```

Wait for the CRD-managed pod:
```bash
kubectl wait --for=condition=available deployment/openclaw-guardrails -n <NAMESPACE> --timeout=120s
```

### 15. Deploy the OpenAI format adapter

The NeMo server has three known issues that require an adapter (see gotchas #1-3):
- Returns `{"messages": [...]}` instead of OpenAI `{"choices": [...]}` format
- Crashes on multi-part `content: [...]` (list format) from OpenClaw
- Ignores `stream: true` — clients expecting SSE hang

Deploy the adapter as a separate service that proxies to the CRD-managed NeMo service:
```bash
kubectl apply -f manifests/guardrails-adapter.yaml -n <NAMESPACE>
kubectl wait --for=condition=available deployment/openclaw-guardrails-adapter -n <NAMESPACE> --timeout=60s
```

The adapter normalizes content, converts response format, and adds SSE streaming. OpenClaw talks to `openclaw-guardrails-proxy` (the adapter), not `openclaw-guardrails` (NeMo directly).

### 16. Configure OpenClaw to route through guardrails

Create the batch config pointing at the adapter service:
```bash
kubectl apply -n <NAMESPACE> -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: openclaw-guardrails-batch
data:
  guardrails-config.json: |
    [
      {
        "path": "models.providers.guardrails-proxy",
        "value": {
          "baseUrl": "http://openclaw-guardrails-proxy.<NAMESPACE>.svc.cluster.local/v1",
          "apiKey": "${OPENAI_API_KEY}",
          "api": "openai-completions",
          "models": [
            { "id": "gpt-4o-mini", "name": "GPT-4o-mini via Guardrails" }
          ]
        }
      },
      {
        "path": "agents.defaults.model.primary",
        "value": "guardrails-proxy/gpt-4o-mini"
      }
    ]
EOF
```

**IMPORTANT:** Replace `<NAMESPACE>` with the actual namespace in the `baseUrl`.

Patch the OpenClaw init container to apply the guardrails config on every pod start:
```bash
kubectl patch deployment openclaw -n <NAMESPACE> --type='json' -p='[
  {
    "op": "replace",
    "path": "/spec/template/spec/initContainers/0/command",
    "value": ["sh", "-c", "openclaw config set gateway.bind lan && openclaw config set gateway.controlUi.dangerouslyAllowHostHeaderOriginFallback true && openclaw config set diagnostics.enabled true && openclaw config set --batch-file /tmp/guardrails-config.json --strict-json"]
  },
  {
    "op": "add",
    "path": "/spec/template/spec/initContainers/0/volumeMounts/-",
    "value": {"name": "guardrails-batch-config", "mountPath": "/tmp/guardrails-config.json", "subPath": "guardrails-config.json"}
  },
  {
    "op": "add",
    "path": "/spec/template/spec/volumes/-",
    "value": {"name": "guardrails-batch-config", "configMap": {"name": "openclaw-guardrails-batch"}}
  }
]'
```

### 17. Wait for pod ready

```bash
kubectl wait --for=condition=available deployment/openclaw -n <NAMESPACE> --timeout=120s
```

Verify the guardrails proxy is configured:
```bash
kubectl exec -n <NAMESPACE> deploy/openclaw -c agent -- openclaw config get agents.defaults.model.primary 2>/dev/null | grep -v otel
```

Should output: `guardrails-proxy/gpt-4o-mini`

### 18. Retrieve gateway token and URL

Wait 5 seconds, then:
```bash
kubectl exec -n <NAMESPACE> deploy/openclaw -c agent -- \
  cat /home/node/.openclaw/openclaw.json | \
  python3 -c "import sys,json; print(json.load(sys.stdin)['gateway']['auth']['token'])"
```

```bash
kubectl get route openclaw -n <NAMESPACE> -o jsonpath='https://{.spec.host}'
```

If no route (non-OpenShift), suggest: `kubectl port-forward svc/openclaw -n <NAMESPACE> 18789:18789`

### 19. Approve device pairing

Tell the user the dashboard URL and gateway token. After they connect and see "pairing required," approve it:
```bash
kubectl exec -n <NAMESPACE> deploy/openclaw -c agent -- sh -c \
  'ID=$(openclaw devices list 2>/dev/null | grep "│" | grep -v "Request\|──" | head -1 | awk "{print \$2}"); openclaw devices approve $ID 2>/dev/null'
```

### 20. Report results

```bash
echo "=== Dashboard ==="
kubectl get route openclaw -n <NAMESPACE> -o jsonpath='https://{.spec.host}{"\n"}'
echo ""
echo "=== Gateway Token ==="
kubectl exec -n <NAMESPACE> deploy/openclaw -c agent -- cat /home/node/.openclaw/openclaw.json 2>/dev/null | \
  python3 -c "import sys,json; print(json.load(sys.stdin)['gateway']['auth']['token'])"
echo ""
echo "=== AgentRuntime ==="
kubectl get agentruntimes -n <NAMESPACE>
echo ""
echo "=== AgentCards ==="
kubectl get agentcards -n <NAMESPACE>
```

If MLflow was configured:
```bash
echo ""
echo "=== MLflow Traces ==="
echo "Check traces at: <MLFLOW_ROUTE_URL>"
```
