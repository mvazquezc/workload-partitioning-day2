# Test Plan: Day-0 `cpuPartitioningMode: AllNodes` vs. Post-Install Infrastructure Patch

## Objective

Validate that a cluster deployed **without** `cpuPartitioningMode: AllNodes` but with the Infrastructure CR patched to `AllNodes` post-install produces functionally identical node configuration to a cluster deployed with day-0 `AllNodes`, once the same PerformanceProfile is applied.

## Background

When `cpuPartitioningMode: AllNodes` is set at install time, the installer sets `Infrastructure.Status.CPUPartitioning = AllNodes` and the NTO render command generates bootstrap `01-<role>-cpu-partitioning` MachineConfigs with empty-cpuset workload pinning files. These serve as:

1. An initial "pinning-ready" state so nodes boot with CRI-O and kubelet aware of the `management` workload class before any PerformanceProfile exists.
2. A fallback safety net if the PerformanceProfile is deleted later.

The hypothesis is that patching the Infrastructure CR post-install and then applying a PerformanceProfile produces the same runtime behavior, with the only difference being the absence of the bootstrap fallback MCs.

## Critical Finding: Ordering Constraint

Patching `Infrastructure.Status.CPUPartitioning = AllNodes` **before** the kubelet is aware of workload partitioning causes a deadlock:

1. The OpenShift kube-apiserver has a compiled-in admission plugin (in `openshift/kubernetes`) that enforces: if `Infrastructure.Status.CPUPartitioning == AllNodes`, then every Node update must include `management.workload.openshift.io/cores` in `status.capacity` and `status.allocatable`.
2. The kubelet only registers this extended resource when `/etc/kubernetes/openshift-workload-pinning` exists on disk at startup (`vendor/k8s.io/kubernetes/pkg/kubelet/managed/managed.go:59-66`).
3. Without the file, the kubelet never registers the resource, and the API server rejects all Node updates -- including the MCD's annotation updates needed for MCO rollout.

**Error observed:**
```
Node "..." is invalid: [status.capacity.workload.openshift.io/cores: Required value:
node does not contain resource information, this is required for clusters with
workload partitioning enabled, status.allocatable.workload.openshift.io/cores: ...]
```

**Solution:** Deliver the kubelet config file via MachineConfig first, wait for node reboots, verify the extended resource is registered, then patch the Infrastructure CR.

## Cluster Configurations

| Cluster | Install-time `cpuPartitioningMode` | Post-install action |
|---------|-------------------------------------|---------------------|
| Cluster A | `AllNodes` | None |
| Cluster B | not set (defaults to `None`) | Apply pinning MCs, wait for rollout, then patch Infrastructure CR |

## Test Sequence

### Cluster A (Day-0 AllNodes)

1. Deploy cluster with `cpuPartitioningMode: AllNodes` in install-config
2. Run `scripts/gather-data.sh pre clusterA` -- captures baseline state
3. Apply PerformanceProfile: `oc apply -f manifests/performanceprofile.yaml`
4. Wait for MCP rollout: `oc wait mcp master --for condition=Updated --timeout=30m`
5. Run `scripts/gather-data.sh post clusterA` -- captures post-PP state

### Cluster B (Day 2 patched)

1. Deploy cluster **without** `cpuPartitioningMode` in install-config
2. Run `scripts/gather-data.sh pre clusterB` -- captures baseline state
3. Enable workload partitioning: `scripts/patch-infra.sh` (handles the correct 5-step sequence):
   - a. Applies `01-master-cpu-partitioning` and `01-worker-cpu-partitioning` MCs
   - b. Waits for MCO rollout (nodes reboot, kubelet picks up the config file)
   - c. Verifies `management.workload.openshift.io/cores` is registered on all nodes
   - d. Patches `Infrastructure.Status.CPUPartitioning = AllNodes`
   - e. Forces new static pod revisions sequentially via `forceRedeploymentReason` on each operator (etcd, kubeapiserver, kubecontrollermanager, kubescheduler), waiting for each rollout to complete. The new revision produces a different manifest (revision number baked into labels/env vars/volumes), causing the kubelet to fully recreate the pod with `management.workload.openshift.io/cores` resources
4. Apply PerformanceProfile: `oc apply -f manifests/performanceprofile.yaml`
5. Wait for MCP rollout: `oc wait mcp master --for condition=Updated --timeout=30m`
6. Run `scripts/gather-data.sh post clusterB` -- captures post-PP state

### Compare

Run `scripts/diff-results.sh clusterA clusterB` to compare both post-PP states.

## Test Cases

### TC-01: Infrastructure CR

Verify the Infrastructure CR reflects the expected CPU partitioning mode.

```bash
oc get infrastructure cluster -o jsonpath='{.status.cpuPartitioning}'
```

**Expected:** Both clusters show `AllNodes`.

### TC-02: MachineConfig Inventory

List all MachineConfigs and identify differences.

```bash
oc get mc --sort-by=.metadata.name -o name
```

**Expected:**

- Both clusters have `01-master-cpu-partitioning` and `01-worker-cpu-partitioning` (Cluster A from bootstrap, Cluster B from manual apply)
- Both have `50-performance-test-profile`

### TC-03: `50-performance-test-profile` MachineConfig Content

Compare the PerformanceProfile-generated MC.

```bash
oc get mc 50-performance-test-profile -o yaml
```

**Expected:** Identical on both clusters. Since both have `Infrastructure.Status.CPUPartitioning = AllNodes`, the NTO controller includes the pinning files in both cases.

### TC-04: CRI-O Workload Pinning Config

```bash
# High-priority config (from PerformanceProfile MC)
oc debug node/<worker> -- chroot /host cat /etc/crio/crio.conf.d/99-workload-pinning.conf

# Low-priority bootstrap config (from 01-*-cpu-partitioning MC)
oc debug node/<worker> -- chroot /host cat /etc/crio/crio.conf.d/01-workload-pinning-default.conf
```

**Expected:**

- `99-workload-pinning.conf`: identical on both, cpuset `"0-3"`
- `01-workload-pinning-default.conf`: present on both (empty cpuset). Overridden by `99-*` by lexical order.

### TC-05: Kubelet Workload Pinning Config

```bash
oc debug node/<worker> -- chroot /host cat /etc/kubernetes/openshift-workload-pinning
```

**Expected:** Identical on both -- `{"management": {"cpuset": "0-3"}}`.

### TC-06: CRI-O Runtime Config

```bash
oc debug node/<worker> -- chroot /host cat /etc/crio/crio.conf.d/99-runtimes.conf
```

**Expected:** Identical -- `infra_ctr_cpuset = "0-3"` present on both.

### TC-07: Kernel Command Line

```bash
oc debug node/<worker> -- chroot /host cat /proc/cmdline
```

**Expected:** Both have `systemd.cpu_affinity=0,1,2,3 nohz=on rcu_nocbs=4-15`.

### TC-08: Systemd PID 1 CPU Affinity

```bash
oc debug node/<worker> -- chroot /host taskset -cp 1
```

**Expected:** Both show `pid 1's current affinity list: 0-3`.

### TC-09: Platform Service CPU Affinity

```bash
for svc in crio kubelet; do
  oc debug node/<worker> -- chroot /host bash -c \
    "pidof $svc | xargs -I{} taskset -cp {}"
done
```

**Expected:** Both clusters show `0-3`.

### TC-10: CRI-O Workload Class Registration

```bash
oc debug node/<worker> -- chroot /host crio config 2>/dev/null | grep -A5 'workloads.management'
```

**Expected:** Identical -- `[crio.runtime.workloads.management]` section present on both.

### TC-11: Management Pod CPU Placement

```bash
POD=$(oc get pods -n openshift-apiserver -o jsonpath='{.items[0].metadata.name}')
NODE=$(oc get pod $POD -n openshift-apiserver -o jsonpath='{.spec.nodeName}')
oc debug node/$NODE -- chroot /host bash -c \
  "crictl inspect \$(crictl ps --name openshift-apiserver -q | head -1) | jq '.info.runtimeSpec.linux.resources.cpu'"
```

**Expected:** Identical -- cpuset `"0-3"` on both.

### TC-12: Rendered MachineConfig Diff

```bash
RENDERED=$(oc get mcp worker -o jsonpath='{.status.configuration.name}')
oc get mc $RENDERED -o yaml
```

**Expected:** Identical or near-identical. Both clusters now have the `01-worker-cpu-partitioning` MC (Cluster A from bootstrap, Cluster B from manual apply), so the rendered configs should match.

### TC-13: Tuned / KubeletConfig / RuntimeClass

```bash
oc get tuned -n openshift-cluster-node-tuning-operator -o yaml
oc get kubeletconfig -o yaml
oc get runtimeclass -o yaml
```

**Expected:** Identical on both.

### TC-14: Node Extended Resources

```bash
oc get nodes -o custom-columns='NAME:.metadata.name,WL_CAPACITY:.status.capacity.management\.workload\.openshift\.io/cores,WL_ALLOCATABLE:.status.allocatable.management\.workload\.openshift\.io/cores'
```

**Expected:** Both clusters show `management.workload.openshift.io/cores` in capacity and allocatable on all nodes.

### TC-15: PerformanceProfile Deletion (Behavioral Difference)

Delete the PerformanceProfile on both clusters and check if pinning survives.

```bash
oc delete performanceprofile test-profile
# Wait for MCP rollout
oc debug node/<worker> -- chroot /host cat /etc/crio/crio.conf.d/99-workload-pinning.conf
oc debug node/<worker> -- chroot /host cat /etc/crio/crio.conf.d/01-workload-pinning-default.conf
oc debug node/<worker> -- chroot /host cat /etc/kubernetes/openshift-workload-pinning
```

**Expected:** Identical on both clusters. Since Cluster B now also has the `01-*-cpu-partitioning` MCs (manually applied), the fallback behavior is the same:

- `99-workload-pinning.conf` is gone (it was in the deleted `50-*` MC)
- `01-workload-pinning-default.conf` remains (empty cpuset)
- `openshift-workload-pinning` remains (empty cpuset)
- CRI-O stays in pinning mode with the `management` workload class registered

### TC-16: Static Pod Resource Requests

Verify that static pods (etcd, kube-apiserver, etc.) use `management.workload.openshift.io/cores` instead of `cpu` for resource requests, and have `resources.workload.openshift.io/*` per-container annotations.

```bash
# Check etcd pod resources
oc get pod -n openshift-etcd -l app=etcd -o jsonpath='{.items[0].spec.containers[0].resources}' | jq .

# Check for workload annotations
oc get pod -n openshift-etcd -l app=etcd -o jsonpath='{.items[0].metadata.annotations}' | jq 'with_entries(select(.key | startswith("resources.workload")))'

# Check for PodResizePending condition (should be absent)
oc get pod -n openshift-etcd -l app=etcd -o jsonpath='{.items[0].status.conditions[?(@.type=="PodResizePending")]}'
```

**Expected:** Identical on both. All static pod containers use `management.workload.openshift.io/cores` in requests/limits, per-container `resources.workload.openshift.io/*` annotations are present, and no `PodResizePending` condition exists.

**Note:** On Cluster B, this requires the static pod operator rollouts from Step 5 of `patch-infra.sh`. Without them, the pods retain `cpu` requests and show `PodResizePending`.

## Summary Matrix

| Item | Cluster A (day-0) | Cluster B (retrofitted) | Same? |
|------|-------------------|-------------------------|-------|
| `Infrastructure.status.cpuPartitioning` | `AllNodes` | `AllNodes` | Yes |
| `01-*-cpu-partitioning` MCs | Present (bootstrap) | Present (manually applied) | Yes |
| `50-performance-*` MC content | With pinning files | With pinning files | Yes |
| `99-workload-pinning.conf` | Present, cpuset 0-3 | Present, cpuset 0-3 | Yes |
| `01-workload-pinning-default.conf` | Present, cpuset empty | Present, cpuset empty | Yes |
| `/etc/kubernetes/openshift-workload-pinning` | cpuset 0-3 | cpuset 0-3 | Yes |
| `99-runtimes.conf` | Identical | Identical | Yes |
| Kernel cmdline | Identical | Identical | Yes |
| systemd/service affinity | Identical | Identical | Yes |
| Management pod pinning | Pinned to 0-3 | Pinned to 0-3 | Yes |
| Node extended resources | Present | Present | Yes |
| Tuned / KubeletConfig / RuntimeClass | Identical | Identical | Yes |
| Static pod resources | `mgmt.workload.openshift.io/cores` | `mgmt.workload.openshift.io/cores` (after rollout) | Yes* |
| After PP deletion | Fallback to empty pinning | Fallback to empty pinning | Yes |

\* Requires forcing static pod operator rollouts after enabling workload partitioning.