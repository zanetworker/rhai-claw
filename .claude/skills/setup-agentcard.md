---
name: setup-agentcard
description: Generate and deploy an A2A agent card for any agent running on Kagenti. Creates a ConfigMap with the agent card JSON schema so the Kagenti operator can discover the agent. No sidecar or image rebuild needed.
---

# Setup AgentCard

Generate an A2A agent card ConfigMap for an agent deployed via Kagenti. The Kagenti operator's ConfigMapFetcher reads agent cards from ConfigMaps before trying HTTP, so this is the simplest way to make any agent discoverable.

## How It Works

The Kagenti AgentCard controller looks for a ConfigMap named `{agentName}-card-signed` with key `agent-card.json` in the same namespace as the agent. No HTTP endpoint, no sidecar, no image changes needed.

## Steps

### 1. Identify the agent

Ask the user which agent to create the card for. Check existing deployments:

```bash
kubectl get deployments -n agents -l kagenti.io/type=agent
```

### 2. Gather agent metadata

Ask the user for:
- **Agent name** (human-readable)
- **Description** (what does this agent do)
- **Version**
- **Skills** (list of capabilities with name + description)
- **Input/output modes** (usually `text/plain`, optionally `image/png`, `application/json`)
- **Capabilities** (streaming: true/false, pushNotifications: true/false)

### 3. Get the agent's external URL

```bash
kubectl get route <agent-name> -n agents -o jsonpath='https://{.spec.host}'
```

### 4. Generate the ConfigMap

Create `manifests/agentcard-configmap.yaml` with the A2A agent card JSON schema:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: <agent-name>-card-signed
data:
  agent-card.json: |
    {
      "name": "<Agent Name>",
      "description": "<description>",
      "version": "<version>",
      "url": "<external-url>",
      "capabilities": {
        "streaming": <true|false>,
        "pushNotifications": <true|false>
      },
      "defaultInputModes": ["text/plain"],
      "defaultOutputModes": ["text/plain"],
      "skills": [
        {
          "name": "<skill-name>",
          "description": "<skill-description>",
          "inputModes": ["text/plain"],
          "outputModes": ["text/plain"]
        }
      ]
    }
```

The ConfigMap name MUST be `{agentName}-card-signed` where `agentName` matches the Service name (the `spec.targetRef.name` in the AgentCard CR).

### 5. Apply the ConfigMap

```bash
kubectl apply -f manifests/agentcard-configmap.yaml -n agents
```

### 6. Verify

Wait for the AgentCard controller to reconcile (may take up to 30s):

```bash
kubectl get agentcards -n agents -o wide
```

The `SYNCED` column should show `True` and the `PROTOCOL` should show `a2a`.

### 7. Report

Show the full agent card status:
- `kubectl get agentcards -n agents -o wide`
- `kubectl get agentcard <name> -n agents -o jsonpath='{.status.card}' | python3 -m json.tool`
