# OpenShift Sandboxed Containers Gotchas

Issues encountered attempting to run OpenClaw in sandboxed (Kata) containers on an AWS-hosted OpenShift cluster. We ultimately removed the sandboxed containers setup due to the complexity, but these findings are documented for future attempts.

## 1. Native Kata doesn't work on AWS cloud VMs

**Symptom:** Pod stays in `ContainerCreating` forever. CRI-O logs show:
```
qemu-kvm: Could not access KVM kernel module: No such file or directory
qemu-kvm: failed to initialize kvm: No such file or directory
```

**Root cause:** Native Kata (`runtimeClassName: kata`) needs `/dev/kvm` on the host, which requires hardware virtualization (Intel VT-x / AMD-V) exposed to the VM. Standard AWS instance types (m6a, m5, c5, etc.) don't expose nested virtualization. There's no `/dev/kvm` inside the EC2 VM.

**Workaround:** Use **peer pods** (`kata-remote`) instead — each pod runs as a separate EC2 instance rather than a QEMU VM inside the existing node. Or use bare metal instances (`m5.metal`, ~$4.6/hr) that have real KVM.

**What to know:** This is not a bug — it's an infrastructure constraint. The `KataConfig` with `enablePeerPods: true` creates both `kata` and `kata-remote` RuntimeClasses, but only `kata-remote` works on cloud VMs.

## 2. KataConfig reboots worker nodes

**Symptom:** After creating a `KataConfig` CR, worker nodes go `NotReady` / `SchedulingDisabled` and stay down for 10-60 minutes.

**Root cause:** The operator creates a MachineConfig that installs RHCOS extensions (QEMU, kata-containers RPMs) and configures CRI-O. MachineConfig changes trigger a MachineConfigPool rollout, which reboots each node in the pool sequentially.

**Workaround:** Use `kataConfigPoolSelector` to target only specific nodes. Label one dedicated node (e.g., `node-role.kubernetes.io/kata-sandbox`) and target it in the KataConfig:

```yaml
spec:
  kataConfigPoolSelector:
    matchLabels:
      node-role.kubernetes.io/kata-sandbox: ""
```

This creates a separate MCP (`kata-oc`) containing only the labeled node. Only that node reboots. All other workers continue running.

**Best practice:** Create a dedicated MachineSet for sandbox nodes so you can add/remove them without affecting production workloads.

## 3. Peer pods need a pod VM AMI

**Symptom:** After creating `KataConfig` with `enablePeerPods: true`, an `osc-podvm-image-creation` job runs and fails.

**Root cause:** Peer pods need a dedicated AMI (Amazon Machine Image) for the pod VMs — these are lightweight VMs that run the actual workload. The operator tries to build this AMI automatically using an S3 bucket and the EC2 `import-image` API.

The AMI creation can fail for several reasons:
- S3 bucket name collision (deterministic naming, conflicts with previous attempts)
- IAM permissions insufficient for `s3:CreateBucket`, `ec2:ImportImage`, `iam:CreateRole`
- The `CredentialsRequest` for extended AWS permissions may not be fulfilled by the cloud credential operator

**Workaround:** If pod VM AMIs already exist in the account from a previous deployment, set `PODVM_AMI_ID` in the `peer-pods-cm` ConfigMap to skip automatic creation:

```bash
# Find existing AMIs
aws ec2 describe-images --owners self --filters "Name=name,Values=*podvm*" \
  --query 'Images[*].[ImageId,Name]' --output table

# Set it in the ConfigMap
oc patch configmap peer-pods-cm -n openshift-sandboxed-containers-operator \
  --type merge -p '{"data":{"PODVM_AMI_ID":"ami-0xxxxxxxxxxxx"}}'
```

## 4. Peer pods need port 15150 open in security group

**Symptom:** Peer pod EC2 instance is created successfully (visible in AWS console), but the pod stays in `ContainerCreating`. The cloud-api-adaptor (CAA) logs show:
```
Retrying failed agent proxy connection: dial tcp 10.0.x.x:15150: connect: connection timed out
```

**Root cause:** The CAA daemon on the worker node communicates with the kata-agent inside the peer pod VM on **TCP port 15150** (agent proxy) and **UDP port 9000** (VXLAN tunnel). The cluster's default security group may have port 9000 open but not 15150.

**Workaround:** Add an inbound rule to the cluster's node security group:
```bash
aws ec2 authorize-security-group-ingress \
  --group-id sg-0xxxxxxxxxxxx \
  --ip-permissions "IpProtocol=tcp,FromPort=15150,ToPort=15150,UserIdGroupPairs=[{GroupId=sg-0xxxxxxxxxxxx}]"
```

**Catch:** The cluster's machine API IAM credentials typically don't have `ec2:AuthorizeSecurityGroupIngress` permission. You need a user/role with SecurityGroup modify access, or do it through the AWS Console.

## 5. KataConfig deletion gets stuck on pod VM image cleanup

**Symptom:** `oc delete kataconfig` hangs indefinitely. Status shows `"Failed to delete Pod VM Image"`.

**Root cause:** The operator's finalizer tries to delete the pod VM AMI and its S3 bucket during cleanup. If the IAM credentials used for image creation have been rotated, or the S3 bucket was created by a different credential set, the cleanup fails and the finalizer blocks deletion.

**Workaround:** Remove the finalizer manually:
```bash
oc patch kataconfig <name> --type=json -p='[{"op":"remove","path":"/metadata/finalizers"}]'
```

The AMI and S3 bucket remain in AWS. Clean them up manually if needed.

## 6. Scaling: 4,000 sandboxed pods is impractical

**Symptom:** Not a bug — a design constraint for the keynote demo scenario.

**Root cause:** Each Kata pod has significant overhead:

| Mode | Overhead per pod | 4,000 pods |
|------|-----------------|------------|
| Native Kata | ~350 MiB RAM + 250m CPU (VM overhead) | 1.4 TiB RAM, 1,000 vCPUs just for overhead |
| Peer pods | 1 EC2 instance per pod | 4,000 EC2 instances (t3.medium = ~$0.04/hr each = $160/hr) |

Benchmarks show native Kata maxes at ~134 containers per node vs ~377 for standard runc.

**Recommendation for scale:** Use NetworkPolicy + NeMo Guardrails for the safety story. Demonstrate Kata on a handful of pods for the "VM isolation" narrative. Don't try to run all 4,000 audience pods in sandboxed containers.

## 7. `peer-pods-cm` ConfigMap must exist before KataConfig

**Symptom:** `KataConfig` with `enablePeerPods: true` creates the `kata` RuntimeClass but not `kata-remote`. No peer pod resources appear.

**Root cause:** The operator checks for the `peer-pods-cm` ConfigMap in `openshift-sandboxed-containers-operator` namespace. If it doesn't exist when the KataConfig is created, peer pods are not configured. The ConfigMap needs AWS details:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: peer-pods-cm
  namespace: openshift-sandboxed-containers-operator
data:
  CLOUD_PROVIDER: "aws"
  VXLAN_PORT: "9000"
  PODVM_INSTANCE_TYPE: "t3.medium"
  PROXY_TIMEOUT: "5m"
  DISABLECVM: "true"
  AWS_REGION: "us-east-2"
  AWS_SUBNET_ID: "subnet-0xxxxxxxxxxxx"
  AWS_VPC_ID: "vpc-0xxxxxxxxxxxx"
  AWS_SG_IDS: "sg-0xxxxxxxxxxxx"
```

**How to get the AWS IDs from the cluster:**
```bash
# Use the cluster's own credentials
CREDS=$(oc get secret aws-cloud-credentials -n openshift-machine-api -o jsonpath='{.data.credentials}' | base64 -d)
AWS_AK=$(echo "$CREDS" | grep aws_access_key_id | head -1 | awk '{print $3}')
AWS_SK=$(echo "$CREDS" | grep aws_secret_access_key | head -1 | awk '{print $3}')
INSTANCE_ID=$(oc get machine -n openshift-machine-api -o jsonpath='{.items[0].status.providerStatus.instanceId}')

AWS_ACCESS_KEY_ID=$AWS_AK AWS_SECRET_ACCESS_KEY=$AWS_SK \
  aws ec2 describe-instances --instance-ids $INSTANCE_ID \
  --query 'Reservations[0].Instances[0].[SubnetId,VpcId,SecurityGroups[*].GroupId]' --output json
```

**Workaround:** Create the ConfigMap before creating the KataConfig, or delete and recreate the KataConfig after creating the ConfigMap (which triggers another node reboot).

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
