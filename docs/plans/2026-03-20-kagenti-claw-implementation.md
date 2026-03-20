# kagenti-claw Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Create a repo that lets any developer deploy OpenClaw on Kubernetes with Kagenti in one command.

**Architecture:** K8s manifests in `manifests/`, a single Claude Code skill `/deploy-openclaw` for automated setup, and a Makefile for non-Claude users. The deployment uses an init container to configure OpenClaw's gateway bind address before the main container starts.

**Tech Stack:** Kubernetes manifests (YAML), Kustomize, Helm (kagenti operator), Make, Claude Code skills

## Task 1: Initialize repo and create GitHub remote

**Files:**
- Create: `.gitignore`

**Step 1: Init git repo**

```bash
cd /Users/azaalouk/go/src/github.com/zanetworker/kagenti-claw
git init
```

**Step 2: Create .gitignore**

```
.DS_Store
*.swp
*.swo
```

**Step 3: Create GitHub repo**

```bash
gh repo create zanetworker/kagenti-claw --public --description "Deploy OpenClaw on Kubernetes with the Kagenti operator" --source .
```

**Step 4: Commit**

```bash
git add .gitignore
git commit -m "chore: initialize repo"
```

## Task 2: Create Kubernetes manifests

**Files:**
- Create: `manifests/namespace.yaml`
- Create: `manifests/deployment.yaml`
- Create: `manifests/service.yaml`
- Create: `manifests/route.yaml`
- Create: `manifests/agentruntime.yaml`
- Create: `manifests/kustomization.yaml`

**Step 1: Create namespace.yaml**

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: agents
```

**Step 2: Create deployment.yaml**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: openclaw
  labels:
    app.kubernetes.io/name: openclaw
    kagenti.io/type: agent
    protocol.kagenti.io/a2a: ""
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: openclaw
  template:
    metadata:
      labels:
        app.kubernetes.io/name: openclaw
        kagenti.io/type: agent
    spec:
      initContainers:
      - name: config-init
        image: quay.io/aicatalyst/openclaw:latest
        command:
        - sh
        - -c
        - |
          openclaw config set gateway.bind lan &&
          openclaw config set gateway.controlUi.dangerouslyAllowHostHeaderOriginFallback true
        volumeMounts:
        - name: openclaw-data
          mountPath: /home/node/.openclaw
      containers:
      - name: agent
        image: quay.io/aicatalyst/openclaw:latest
        ports:
        - containerPort: 18789
        volumeMounts:
        - name: openclaw-data
          mountPath: /home/node/.openclaw
      volumes:
      - name: openclaw-data
        emptyDir: {}
```

**Step 3: Create service.yaml**

```yaml
apiVersion: v1
kind: Service
metadata:
  name: openclaw
spec:
  selector:
    app.kubernetes.io/name: openclaw
  ports:
  - name: http
    port: 18789
    targetPort: 18789
```

**Step 4: Create route.yaml**

```yaml
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: openclaw
  annotations:
    haproxy.router.openshift.io/timeout: 300s
spec:
  to:
    kind: Service
    name: openclaw
  port:
    targetPort: 18789
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
```

**Step 5: Create agentruntime.yaml**

```yaml
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
```

**Step 6: Create kustomization.yaml**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: agents
resources:
- namespace.yaml
- deployment.yaml
- service.yaml
- route.yaml
- agentruntime.yaml
```

**Step 7: Commit**

```bash
git add manifests/
git commit -m "feat: add Kubernetes manifests for OpenClaw deployment"
```

## Task 3: Create Makefile

**Files:**
- Create: `Makefile`

**Step 1: Create Makefile**

```makefile
NAMESPACE ?= agents
IMAGE ?= quay.io/aicatalyst/openclaw:latest
KAGENTI_VERSION ?= 0.2.0-alpha.22
HELM ?= helm

.PHONY: deploy teardown token status approve-pairing install-kagenti

deploy: install-kagenti
	@kubectl get ns $(NAMESPACE) >/dev/null 2>&1 || kubectl create ns $(NAMESPACE)
	@kubectl apply -k manifests/ 2>&1 || \
		(echo "Note: AgentRuntime CRD may not be installed. Run 'make install-kagenti' first." && \
		 kubectl apply -f manifests/namespace.yaml -f manifests/deployment.yaml -f manifests/service.yaml -f manifests/route.yaml)
	@echo "Waiting for OpenClaw pod to be ready..."
	@kubectl wait --for=condition=available deployment/openclaw -n $(NAMESPACE) --timeout=120s
	@echo ""
	@make -s status
	@echo ""
	@make -s token

install-kagenti:
	@if kubectl get ns kagenti-system >/dev/null 2>&1; then \
		echo "Kagenti operator already installed."; \
	else \
		echo "Installing Kagenti operator $(KAGENTI_VERSION)..."; \
		DOCKER_CONFIG=$$(mktemp -d) && echo '{}' > "$$DOCKER_CONFIG/config.json" && \
		DOCKER_CONFIG=$$DOCKER_CONFIG $(HELM) install kagenti-operator \
			oci://ghcr.io/kagenti/kagenti-operator/kagenti-operator-chart \
			--version $(KAGENTI_VERSION) \
			--namespace kagenti-system \
			--create-namespace; \
	fi

teardown:
	@kubectl delete -k manifests/ --ignore-not-found
	@echo "OpenClaw removed from $(NAMESPACE)."

token:
	@echo "Gateway Token:"
	@kubectl exec -n $(NAMESPACE) deploy/openclaw -c agent -- \
		cat /home/node/.openclaw/openclaw.json 2>/dev/null | \
		python3 -c "import sys,json; print(json.load(sys.stdin).get('gateway',{}).get('auth',{}).get('token','NOT FOUND'))"
	@echo ""
	@echo "Dashboard URL:"
	@kubectl get route openclaw -n $(NAMESPACE) -o jsonpath='https://{.spec.host}{"\n"}' 2>/dev/null || echo "(no route found)"

status:
	@echo "=== Pod ==="
	@kubectl get pods -n $(NAMESPACE) -l app.kubernetes.io/name=openclaw
	@echo ""
	@echo "=== AgentRuntime ==="
	@kubectl get agentruntime -n $(NAMESPACE) 2>/dev/null || echo "(AgentRuntime CRD not installed)"
	@echo ""
	@echo "=== AgentCards ==="
	@kubectl get agentcards -n $(NAMESPACE) 2>/dev/null || echo "(AgentCard CRD not installed)"

approve-pairing:
	@kubectl exec -n $(NAMESPACE) deploy/openclaw -c agent -- \
		sh -c 'PENDING=$$(openclaw devices list 2>/dev/null | grep -A1 "Pending" | grep "│" | head -1 | awk "{print \$$2}"); \
		if [ -n "$$PENDING" ]; then openclaw devices approve $$PENDING; else echo "No pending pairings."; fi'
```

**Step 2: Commit**

```bash
git add Makefile
git commit -m "feat: add Makefile with deploy/teardown/token/status targets"
```

## Task 4: Create Claude Code skill

**Files:**
- Create: `.claude/skills/deploy-openclaw.md`

**Step 1: Create skill file**

The skill should be a rigid workflow that walks through all deployment steps sequentially, running commands and reporting results.

```markdown
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
```bash
DOCKER_CONFIG=$(mktemp -d) && echo '{}' > "$DOCKER_CONFIG/config.json" && \
DOCKER_CONFIG=$DOCKER_CONFIG helm install kagenti-operator \
  oci://ghcr.io/kagenti/kagenti-operator/kagenti-operator-chart \
  --version 0.2.0-alpha.22 \
  --namespace kagenti-system \
  --create-namespace
```

Wait for the operator pod to be ready:
```bash
kubectl wait --for=condition=available deployment/kagenti-controller-manager -n kagenti-system --timeout=120s
```

### 3. Install AgentRuntime CRD

Check if the CRD exists: `kubectl get crd agentruntimes.agent.kagenti.dev`

If not found, install from the kagenti-operator repo. The CRD file is at:
`/Users/azaalouk/go/src/github.com/kagenti/kagenti-operator/kagenti-operator/config/crd/bases/agent.kagenti.dev_agentruntimes.yaml`

If that local path doesn't exist, fetch it:
```bash
gh api repos/kagenti/kagenti-operator/contents/kagenti-operator/config/crd/bases/agent.kagenti.dev_agentruntimes.yaml \
  -H "Accept: application/vnd.github.raw" | kubectl apply -f -
```

### 4. Apply manifests

```bash
kubectl apply -k manifests/
```

If kustomize fails (e.g., AgentRuntime CRD missing), apply individual files:
```bash
kubectl apply -f manifests/namespace.yaml
kubectl apply -f manifests/deployment.yaml -n agents
kubectl apply -f manifests/service.yaml -n agents
kubectl apply -f manifests/route.yaml -n agents
```

Then apply the AgentRuntime separately:
```bash
kubectl apply -f manifests/agentruntime.yaml -n agents
```

### 5. Wait for pod ready

```bash
kubectl wait --for=condition=available deployment/openclaw -n agents --timeout=120s
```

### 6. Retrieve gateway token

Wait 5 seconds for the config to be generated, then:
```bash
kubectl exec -n agents deploy/openclaw -c agent -- \
  cat /home/node/.openclaw/openclaw.json | \
  python3 -c "import sys,json; print(json.load(sys.stdin).get('gateway',{}).get('auth',{}).get('token','NOT FOUND'))"
```

### 7. Approve device pairings

List pending pairings:
```bash
kubectl exec -n agents deploy/openclaw -c agent -- openclaw devices list
```

If there are pending pairings, approve them:
```bash
kubectl exec -n agents deploy/openclaw -c agent -- openclaw devices approve <REQUEST_ID>
```

### 8. Report results

Print a summary with:
- Dashboard URL: `kubectl get route openclaw -n agents -o jsonpath='https://{.spec.host}'`
- Gateway token (from step 6)
- `kubectl get agentruntimes -n agents`
- `kubectl get agentcards -n agents`
```

**Step 2: Commit**

```bash
git add .claude/
git commit -m "feat: add /deploy-openclaw Claude Code skill"
```

## Task 5: Create CLAUDE.md

**Files:**
- Create: `CLAUDE.md`

**Step 1: Create CLAUDE.md**

```markdown
# kagenti-claw

Deploy OpenClaw on Kubernetes with the Kagenti operator.

## Quick Start

Run `/deploy-openclaw` to deploy everything automatically.

## Project Structure

- `manifests/` — Kubernetes manifests (Deployment, Service, Route, AgentRuntime)
- `.claude/skills/deploy-openclaw.md` — Automated deployment skill
- `Makefile` — Manual deployment targets

## Key Details

- OpenClaw listens on port **18789** (WebSocket gateway)
- Gateway must bind to `0.0.0.0` via `gateway.bind=lan` config (init container handles this)
- Route needs edge TLS with 300s timeout for WebSocket support
- Device pairing must be approved after first dashboard connection
```

**Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: add CLAUDE.md"
```

## Task 6: Create README.md

**Files:**
- Create: `README.md`

**Step 1: Create README.md with quick start, architecture, and expected output samples**

Include:
- One-liner quick start (`make deploy`)
- What it deploys (diagram or description)
- Prerequisites
- Manual steps
- Expected output of `kubectl get agentruntimes` and `kubectl get agentcards`
- Configuration variables
- Teardown

**Step 2: Commit**

```bash
git add README.md
git commit -m "docs: add README with quick start and expected outputs"
```

## Task 7: Push to GitHub

**Step 1: Push**

```bash
git push -u origin main
```
