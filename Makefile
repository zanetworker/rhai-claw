NAMESPACE ?= agents
IMAGE ?= quay.io/aicatalyst/openclaw:latest
KAGENTI_VERSION ?= 0.2.0-alpha.22
HELM ?= helm

.PHONY: deploy teardown token status approve-pairing install-kagenti

deploy: install-kagenti
	@kubectl get ns $(NAMESPACE) >/dev/null 2>&1 || kubectl create ns $(NAMESPACE)
	@kubectl apply -k manifests/ 2>&1 || \
		(echo "Note: AgentRuntime CRD may not be installed yet. Applying core manifests only." && \
		 kubectl apply -f manifests/namespace.yaml -f manifests/deployment.yaml -f manifests/service.yaml -f manifests/route.yaml -n $(NAMESPACE))
	@echo "Waiting for OpenClaw pod to be ready..."
	@kubectl wait --for=condition=available deployment/openclaw -n $(NAMESPACE) --timeout=120s
	@echo ""
	@$(MAKE) -s status
	@echo ""
	@$(MAKE) -s token

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
