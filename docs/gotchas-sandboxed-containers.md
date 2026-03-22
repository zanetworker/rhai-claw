# OpenShift Sandboxed Containers Gotchas

Issues encountered attempting to run OpenClaw in sandboxed (Kata) containers on an AWS-hosted OpenShift cluster. We ultimately removed the sandboxed containers setup due to the complexity, but these findings are documented for future attempts.

## Decision Tree

Before diving into gotchas, understand the decision path. Each fork leads to a different class of problems.

```
Want VM-level pod isolation?
├── Yes
│   ├── Bare metal nodes available?
│   │   ├── Yes → Native Kata (runtimeClassName: kata)
│   │   │         Straightforward. Install operator, create KataConfig, done.
│   │   │         Gotchas: node reboots (#2), scale limits (#6)
│   │   │
│   │   └── No (cloud VMs) → Nested virtualization?
│   │       ├── Supported (Azure, some GCP) → Native Kata may work
│   │       │   Not tested. Red Hat does not support nested virt in production.
│   │       │
│   │       └── Not supported (AWS) → DEAD END for native Kata
│   │           You must use Peer Pods (kata-remote)
│   │           ├── Peer Pods
│   │           │   Each pod = separate EC2 instance
│   │           │   Gotchas: AMI creation (#3), SG ports (#4), ConfigMap ordering (#7),
│   │           │            deletion stuck (#5), IAM permissions throughout
│   │           │   Verdict: WORKS but painful setup, ~10 steps, multiple IAM blockers
│   │           │
│   │           └── Bare metal instances (m5.metal, ~$4.6/hr)
│   │               Real KVM, native Kata works. Expensive.
│   │
│   └── At scale (hundreds of agents)?
│       └── DEAD END — see #6
│           ~350 MiB overhead per VM, or 1 EC2 instance per agent
│           Use NetworkPolicy + guardrails instead
│
└── No → Skip sandboxed containers entirely
    Use NetworkPolicy + RBAC + NeMo Guardrails for isolation
    This is what we did for the demo.
```

## Gotcha Severity

| Rating | Meaning |
|--------|---------|
| **Obvious** | Expected if you understand the technology. Documented, discoverable. |
| **Surprising** | Not obvious from docs. Costs hours of debugging. |
| **Dead end** | No workaround on this path. Must change approach entirely. |

## Obvious Gotchas

These follow directly from how Kata/peer pods work. You'd expect them if you read the docs carefully.

### 1. Native Kata needs bare metal — no nested virt on AWS

**Severity: Obvious / Dead end on AWS cloud VMs**

Kata runs workloads inside QEMU VMs. QEMU needs `/dev/kvm`. AWS cloud VMs (m6a, m5, c5, etc.) don't expose KVM to guests. No nested virtualization.

```
qemu-kvm: Could not access KVM kernel module: No such file or directory
qemu-kvm: failed to initialize kvm: No such file or directory
```

**Why it's "obvious":** Kata = hardware virtualization. Cloud VMs = already virtualized. VM-in-VM = nested virt. AWS doesn't do nested virt. This is in the Red Hat docs.

**Why you might still hit it:** The `KataConfig` with `enablePeerPods: true` creates **both** `kata` and `kata-remote` RuntimeClasses. If you use `kata` instead of `kata-remote` on a cloud VM, you get the QEMU error above. The naming doesn't scream "this one won't work on your infra."

**Path forward:** Use `kata-remote` (peer pods) on cloud, or `m5.metal` bare metal instances (~$4.6/hr).

### 2. KataConfig reboots worker nodes (10-60 min)

**Severity: Obvious**

The operator installs RHCOS extensions (QEMU, kata RPMs) and reconfigures CRI-O via MachineConfig. MachineConfig changes trigger node reboots.

**Why it's "obvious":** MachineConfig = node reboot. This is standard OpenShift behavior.

**Workaround:** Use `kataConfigPoolSelector` to isolate the blast radius:

```yaml
spec:
  kataConfigPoolSelector:
    matchLabels:
      node-role.kubernetes.io/kata-sandbox: ""
```

Create a dedicated MachineSet for sandbox nodes. Only those nodes reboot. Production workloads continue.

### 6. Scaling to hundreds of sandboxed agents is impractical

**Severity: Obvious / Dead end at scale**

| Mode | Overhead per agent | 100 agents | 500 agents |
|------|-------------------|------------|------------|
| Native Kata | ~350 MiB RAM + 250m CPU | 35 GiB RAM, 25 vCPUs overhead | 175 GiB RAM, 125 vCPUs overhead |
| Peer pods | 1 EC2 instance per agent | 100 EC2 instances (~$4/hr) | 500 EC2 instances (~$20/hr) |

Benchmarks show native Kata maxes at ~134 containers per node vs ~377 for standard runc.

**Why it's "obvious":** Each agent = a VM. VMs have overhead. This is the fundamental tradeoff of VM-level isolation.

**Recommendation:** Use Kata on a few demo agents. Use NetworkPolicy + NeMo Guardrails for the bulk.

## Surprising Gotchas

These cost real debugging time. Not well-documented, not intuitive.

### 3. Pod VM AMI creation fails silently on IAM/S3 issues

**Severity: Surprising**

After creating `KataConfig` with peer pods, an `osc-podvm-image-creation` job runs to build the pod VM AMI. It frequently fails:

- **S3 bucket name collision:** Deterministic naming (`podvm-image-XXXXXXXXX.0.1`). If a previous attempt created the bucket, the new attempt fails with `BucketAlreadyOwnedByYou` — but the script treats this as fatal instead of continuing.
- **IAM permissions:** The `CredentialsRequest` asks for `s3:CreateBucket`, `ec2:ImportImage`, `iam:CreateRole`. The cloud credential operator may not grant all of these depending on the cluster's credential mode.
- **No retry:** The job runs once and fails. The operator doesn't retry. You're left with a failed job and no AMI.

**Why it's surprising:** The operator is supposed to handle AMI creation automatically. The docs say "PODVM_AMI_ID is populated when you run the KataConfig CR." In practice, the auto-creation is fragile.

**Workaround:** Find an existing AMI and set it manually:
```bash
aws ec2 describe-images --owners self --filters "Name=name,Values=*podvm*" \
  --query 'Images[*].[ImageId,Name]' --output table

oc patch configmap peer-pods-cm -n openshift-sandboxed-containers-operator \
  --type merge -p '{"data":{"PODVM_AMI_ID":"ami-0xxxxxxxxxxxx"}}'
```

### 4. Port 15150 not open — peer pod created but unreachable

**Severity: Surprising / Dead end without SG access**

The peer pod EC2 instance is created (you can see it in AWS console), networking is set up (VXLAN tunnel configured), but the pod stays in `ContainerCreating` forever. CAA logs show:

```
Retrying failed agent proxy connection: dial tcp 10.0.x.x:15150: connect: connection timed out
```

**Why it's surprising:**
1. The pod VM is running. The EC2 instance is healthy. Everything *looks* like it should work.
2. Port 9000 (VXLAN) is in the default SG rules. Port 15150 (agent proxy) is not. The docs mention "enable ports 15150 and 9000" but don't automate it.
3. The cluster's IAM credentials **cannot modify security groups.** You need out-of-band access (AWS Console or a privileged IAM user) to add the rule.

**Dead end if:** You don't have AWS Console access or a privileged IAM role. The cluster can create peer pod VMs but can never connect to them.

**Fix:**
```bash
aws ec2 authorize-security-group-ingress \
  --group-id sg-0xxxxxxxxxxxx \
  --ip-permissions "IpProtocol=tcp,FromPort=15150,ToPort=15150,UserIdGroupPairs=[{GroupId=sg-0xxxxxxxxxxxx}]"
```

### 5. KataConfig deletion stuck on finalizer

**Severity: Surprising**

`oc delete kataconfig` hangs indefinitely. Status: `"Failed to delete Pod VM Image"`.

**Why it's surprising:** The operator's finalizer tries to clean up the AMI and S3 bucket. If the credentials that created them have been rotated (common in STS-mode clusters), or if a different credential set created the bucket, cleanup fails. The finalizer blocks deletion. Your cluster is stuck with a half-uninstalled KataConfig.

**Workaround:**
```bash
oc patch kataconfig <name> --type=json -p='[{"op":"remove","path":"/metadata/finalizers"}]'
```

The AMI and S3 bucket are orphaned in AWS. Clean up manually.

### 7. `peer-pods-cm` must exist BEFORE KataConfig

**Severity: Surprising**

If you create the `KataConfig` with `enablePeerPods: true` but the `peer-pods-cm` ConfigMap doesn't exist yet, the operator installs native Kata only. It creates the `kata` RuntimeClass but not `kata-remote`. No peer pod infrastructure is set up.

**Why it's surprising:** You'd expect the operator to reconcile — detect the ConfigMap later and set up peer pods. It doesn't. The peer pods decision is made at KataConfig creation time only.

**Workaround:** Delete the KataConfig (triggers node reboot for uninstall), create the ConfigMap, then recreate the KataConfig (triggers another node reboot for install). Two reboots because of ordering.

The ConfigMap needs actual AWS resource IDs:

```bash
# Get IDs from a running instance
CREDS=$(oc get secret aws-cloud-credentials -n openshift-machine-api -o jsonpath='{.data.credentials}' | base64 -d)
AWS_AK=$(echo "$CREDS" | grep aws_access_key_id | head -1 | awk '{print $3}')
AWS_SK=$(echo "$CREDS" | grep aws_secret_access_key | head -1 | awk '{print $3}')
INSTANCE_ID=$(oc get machine -n openshift-machine-api -o jsonpath='{.items[0].status.providerStatus.instanceId}')

AWS_ACCESS_KEY_ID=$AWS_AK AWS_SECRET_ACCESS_KEY=$AWS_SK \
  aws ec2 describe-instances --instance-ids $INSTANCE_ID \
  --query 'Reservations[0].Instances[0].[SubnetId,VpcId,SecurityGroups[*].GroupId]' --output json
```

## The UX Verdict

Setting up peer pods on AWS requires ~10 ordered steps with multiple failure modes at each step. Several steps need credentials the cluster doesn't have. The feedback loop is slow (node reboots, AMI builds). When things fail, errors are often in operator logs rather than user-facing resources.

| Step | Time | Can fail? | Recovery |
|------|------|-----------|----------|
| Install operator | 2 min | Rarely | Reinstall |
| Create `peer-pods-cm` | 1 min | Need AWS IDs | Query from cluster |
| Set `PODVM_AMI_ID` | 1 min | AMI may not exist | Build or find one |
| Add SG port 15150 | 1 min | **Need out-of-band AWS access** | AWS Console |
| Create sandbox MachineSet | 5-10 min | Node provisioning | Check AWS quotas |
| Create KataConfig | 10-20 min | ConfigMap ordering, MCP issues | Delete + recreate (another reboot) |
| Wait for MCP rollout | 10-20 min | Node reboot failures | Check MCP status |
| Verify RuntimeClass | 1 min | May not appear if peer pods not configured | Check operator logs |
| Test pod | 1-2 min | SG, AMI, networking | Check CAA logs |

**Total happy path:** ~30-40 minutes. **With failures:** 1-3 hours (each KataConfig delete/recreate costs 20+ min in node reboots).

**Compare to NetworkPolicy + NeMo Guardrails:** ~5 minutes, no node reboots, no AWS IAM dependencies, no AMI builds.

## Summary: Order of Operations for Peer Pods on AWS

If you attempt this again, the correct sequence is:

1. Install the sandboxed containers operator from OperatorHub
2. Create the `peer-pods-cm` ConfigMap with AWS details
3. Optionally set `PODVM_AMI_ID` if a pod VM AMI already exists
4. Add port 15150 TCP inbound to the cluster security group
5. Create a dedicated MachineSet with a `kata-sandbox` label
6. Wait for the sandbox node to be Ready
7. Create `KataConfig` with `enablePeerPods: true` and `kataConfigPoolSelector` targeting only the sandbox node
8. Wait for MCP rollout (node reboot, 10-20 min)
9. Verify `kata-remote` RuntimeClass exists
10. Test with a pod using `runtimeClassName: kata-remote`
