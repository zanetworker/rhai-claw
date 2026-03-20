---
name: deploy-openclaw
description: Deploy OpenClaw on Kubernetes with the Kagenti operator. Installs the operator, applies manifests, creates the route, retrieves the gateway token, and approves device pairings. Run this after connecting to a Kubernetes cluster.
---

# Deploy OpenClaw

Deploy OpenClaw on Kubernetes with the Kagenti operator in one shot.

## Prerequisites

- `kubectl` connected to a Kubernetes cluster
- `helm` v4+ installed (for Kagenti operator)

## Steps

Follow these steps sequentially. Do not skip steps. Report the output of each step to the user.

### 1. Check cluster connectivity

Run: `kubectl cluster-info`

If this fails, stop and tell the user to configure kubectl access.

### 2. Install Kagenti operator

Check if already installed: `kubectl get ns kagenti-system`

If not installed, run:

DOCKER_CONFIG=$(mktemp -d) && echo '{}' > "$DOCKER_CONFIG/config.json" && \
DOCKER_CONFIG=$DOCKER_CONFIG helm install kagenti-operator \
  oci://ghcr.io/kagenti/kagenti-operator/kagenti-operator-chart \
  --version 0.2.0-alpha.22 \
  --namespace kagenti-system \
  --create-namespace

Wait for the operator pod to be ready:

kubectl wait --for=condition=available deployment/kagenti-controller-manager -n kagenti-system --timeout=120s

### 3. Install AgentRuntime CRD

Check if the CRD exists: `kubectl get crd agentruntimes.agent.kagenti.dev`

If not found, fetch and install it:

gh api repos/kagenti/kagenti-operator/contents/kagenti-operator/config/crd/bases/agent.kagenti.dev_agentruntimes.yaml \
  -H "Accept: application/vnd.github.raw" | kubectl apply -f -

### 4. Apply manifests

Run from the repo root:

kubectl apply -k manifests/

If kustomize fails (e.g., AgentRuntime CRD not yet ready), apply individual files:

kubectl apply -f manifests/namespace.yaml
kubectl apply -f manifests/deployment.yaml -n agents
kubectl apply -f manifests/service.yaml -n agents
kubectl apply -f manifests/route.yaml -n agents

Then apply AgentRuntime separately:

kubectl apply -f manifests/agentruntime.yaml -n agents

### 5. Wait for pod ready

kubectl wait --for=condition=available deployment/openclaw -n agents --timeout=120s

### 6. Retrieve gateway token

Wait 5 seconds for the config to be generated, then:

kubectl exec -n agents deploy/openclaw -c agent -- \
  cat /home/node/.openclaw/openclaw.json | \
  python3 -c "import sys,json; print(json.load(sys.stdin).get('gateway',{}).get('auth',{}).get('token','NOT FOUND'))"

### 7. Approve device pairings

List pending pairings:

kubectl exec -n agents deploy/openclaw -c agent -- openclaw devices list

If there are pending pairings, approve them by extracting the request ID from the Pending table and running:

kubectl exec -n agents deploy/openclaw -c agent -- openclaw devices approve <REQUEST_ID>

### 8. Report results

Print a summary with:

- **Dashboard URL**: `kubectl get route openclaw -n agents -o jsonpath='https://{.spec.host}'`
- **Gateway token** (from step 6)
- **AgentRuntimes**: `kubectl get agentruntimes -n agents`
- **AgentCards**: `kubectl get agentcards -n agents`

Format the output clearly so the user can copy the URL and token.
