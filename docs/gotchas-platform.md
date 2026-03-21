# Platform Gotchas (Kagenti-Side)

These are Kagenti platform behaviors discovered during deployment. The `/deploy-openclaw` skill handles all of them automatically.

## Namespace needs `kagenti-enabled=true` label

The kagenti-extensions webhook uses a `namespaceSelector` with `matchLabels: {kagenti-enabled: "true"}` to control which namespaces get sidecar injection. This is an opt-in design — the webhook only intercepts pod creates in labeled namespaces, preventing accidental injection in system namespaces.

The failure mode is silent: without the label, the API server never routes admission requests to the webhook. Pods create normally, no errors appear anywhere, but no env vars or sidecars are injected. We spent significant debugging time on this because `failurePolicy: Fail` only applies when the webhook is called and fails — not when the selector excludes the namespace entirely.

```bash
kubectl label namespace agents kagenti-enabled=true
```

## AgentCard shows `SYNCED=False` for non-A2A agents

The AgentCard controller tries to fetch agent metadata from `http://{serviceName}.{namespace}.svc.cluster.local:{port}/.well-known/agent-card.json`. This works for agents that implement the A2A protocol natively. OpenClaw doesn't — it's a WebSocket gateway, not an A2A server.

The Kagenti operator has a `ConfigMapFetcher` (in `internal/agentcard/fetcher.go`) that checks for a ConfigMap named `{serviceName}-card-signed` with key `agent-card.json` **before** falling back to HTTP. This is the designed escape hatch for non-A2A agents. The naming convention (`-card-signed` suffix) comes from the SPIFFE-based signing flow but works for unsigned cards too.

The deployment includes `manifests/agentcard-configmap.yaml` with the A2A agent card schema for OpenClaw. Once applied, the AgentCard controller reads the ConfigMap and sets `SYNCED=True`.

## AgentRuntime `spec.trace` doesn't inject env vars

The AgentRuntime controller (PR [#218](https://github.com/kagenti/kagenti-operator/pull/218)) processes `spec.trace` by including it in a SHA256 config hash. When the hash changes (e.g., you update the trace endpoint), the controller stamps a new `kagenti.io/config-hash` annotation on the PodTemplateSpec, which triggers a rolling update. But the new pods come up identical to the old ones — the controller never writes `OTEL_EXPORTER_OTLP_ENDPOINT` to the container's env vars.

The webhook (kagenti-extensions) has the resolution pipeline: `ReadAgentRuntimeOverrides()` extracts `TraceEndpoint` from the CR, `ResolveConfig()` merges it into `ResolvedConfig`, but `ContainerBuilder` never emits the env vars. The patched webhook image (`quay.io/azaalouk/kagenti-webhook:trace-injection`) adds `BuildTraceEnv()` to close this gap. See [Webhook Changes](../README.md#webhook-changes-not-yet-upstream).

Two additional bugs were fixed in the patched image:
- **Early return bypass:** When all sidecar feature gates are disabled, `AnyInjected()` returns false and the function exits before reaching the trace injection code. The fix checks whether trace injection is needed independently of sidecar decisions.
- **Deployment name mismatch:** The webhook receives the pod's `GenerateName` which is the ReplicaSet name (e.g., `openclaw-748648db65`), but `AgentRuntime.spec.targetRef.name` is the Deployment name (`openclaw`). The fix strips the `pod-template-hash` suffix using the pod's label.

## MLflow OTLP endpoint rejects requests with port in Host header

MLflow 3.x has DNS rebinding protection via `--allowed-hosts`. The OTEL SDK's HTTP client sends the `Host` header as `mlflow-service.test.svc.cluster.local:5000` (including the port because 5000 is non-standard). MLflow's allowed hosts list had `mlflow-service.test.svc.cluster.local` but not the `:5000` variant, so every OTLP export was rejected with "Invalid Host header - possible DNS rebinding attack detected."

The OTEL exporter silently swallowed the 400 response — no error logs appeared in the agent pod. We only found this by curling the MLflow `/v1/traces` endpoint directly and comparing with and without the `Host` header.

The fix: add `mlflow-service.${POD_NAMESPACE}.svc.cluster.local:5000` to MLflow's `ALLOWED_HOSTS` in its deployment startup script.

## OTEL traces are HTTP-level, not GenAI-level

The OTEL preload script (`manifests/otel-tracing-configmap.yaml`) patches `globalThis.fetch` to create spans for outgoing LLM API calls. This captures HTTP-level attributes: URL, method, status code, latency, and which provider was called (Anthropic, OpenAI, etc.).

It does not capture GenAI-level attributes: the prompt text, completion text, token counts, model parameters, or tool call details. This is because the Anthropic SDK uses streaming responses — reading the response body to extract completion text would require teeing the ReadableStream, which caused "ReadableStream is locked" errors that broke chat completely.

Full GenAI observability requires application-level instrumentation. OpenClaw has a `diagnostics-otel` extension designed for this, but it's broken in the current image build — the `index.js` file is missing from the extension directory, so the extension fails to load with "extension entry escapes package directory."

## Webhook needs RBAC for AgentRuntime reads

The webhook service account (`kagenti-webhook` in `kagenti-webhook-system`) needs `get/list/watch` permissions on `agentruntimes.agent.kagenti.dev` to read `spec.trace` from the AgentRuntime CR at admission time. Without this, the webhook logs `"AgentRuntime CRD not available or list failed"` and falls back to no trace config.

The bundled webhook manifests in `manifests/webhook/webhook-all.yaml` include a `ClusterRole` and `ClusterRoleBinding` for this. The upstream Helm chart does not include this RBAC because the AgentRuntime integration was added separately.

## AgentRuntime CRD not in Helm chart

The AgentRuntime CRD was added in [kagenti-operator#218](https://github.com/kagenti/kagenti-operator/pull/218) and merged to main, but the Helm chart (`oci://ghcr.io/kagenti/kagenti-operator/kagenti-operator-chart`) has not been updated to include it. The CRD must be installed separately:

```bash
kubectl apply -f https://raw.githubusercontent.com/kagenti/kagenti-operator/main/kagenti-operator/config/crd/bases/agent.kagenti.dev_agentruntimes.yaml
```

The operator binary in the Helm chart also doesn't include the AgentRuntime controller code yet — the controller reconciles but the released image predates PR #218.

## CRDs get stuck terminating after deletion

Deleting a CRD while CRs still exist causes the CRD to hang in `Terminating` state with finalizers. On the next install, `kubectl apply` fails with "create not allowed while custom resource definition is terminating." The fix is to patch out the finalizers:

```bash
kubectl patch crd agentruntimes.agent.kagenti.dev --type=json -p '[{"op":"remove","path":"/metadata/finalizers"}]'
```

The skill checks for terminating CRDs in the stale resource detection step and clears them automatically.

## AgentCards CRD comes from the Helm chart only

The `agentcards.agent.kagenti.dev` CRD is installed by the Kagenti operator Helm chart at first install. Helm does not recreate CRDs on subsequent installs. If the CRD is manually deleted, you must uninstall and reinstall the operator (`helm uninstall` then `helm install`) to get it back.

## Empty secrets cause silent failures

Creating a secret with `kubectl create secret --from-literal=anthropic=$ANTHROPIC_API_KEY` when `$ANTHROPIC_API_KEY` is unset in the shell creates a secret with an empty value. The secret exists (passes `kubectl get secret` checks) but OpenClaw reports "No API key found." The skill now verifies the secret has non-empty content by checking the base64-encoded value length.

## Secrets are namespace-scoped

A secret created in the `agents` namespace is not visible in the `openclaw` namespace. The skill emphasizes the target namespace in every secret creation command. This caused a `CreateContainerConfigError` during testing when the secret was in the wrong namespace.
