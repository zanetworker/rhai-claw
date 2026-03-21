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

### 13. Add API key to deployment

```bash
kubectl patch deploy openclaw -n <NAMESPACE> --type=json -p '[
  {"op":"add","path":"/spec/template/spec/containers/0/env/-","value":{
    "name":"ANTHROPIC_API_KEY",
    "valueFrom":{"secretKeyRef":{"name":"llm-keys","key":"anthropic"}}
  }}
]'
```

### 14. Wait for pod ready

```bash
kubectl wait --for=condition=available deployment/openclaw -n <NAMESPACE> --timeout=120s
```

### 15. Retrieve gateway token and URL

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

### 16. Approve device pairing

Tell the user the dashboard URL and gateway token. After they connect and see "pairing required," approve it:
```bash
kubectl exec -n <NAMESPACE> deploy/openclaw -c agent -- sh -c \
  'ID=$(openclaw devices list 2>/dev/null | grep "│" | grep -v "Request\|──" | head -1 | awk "{print \$2}"); openclaw devices approve $ID 2>/dev/null'
```

### 17. Report results

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
