# Workload Partitioning: cpushares Injection Behavior

How the `resources.workload.openshift.io/<container>` annotation (containing
`cpushares`) is injected depending on the pod's QoS class and whether the
container defines a CPU request.

There are two independent code paths: the **kube-apiserver admission plugin**
(for dynamically-created pods) and the **kubelet** (for static pods).

## API Server Admission Plugin

| Pod QoS | Container has CPU request? | Result | Code reference |
|---|---|---|---|
| **BestEffort** | No cpu or memory requests | `cpushares: 2` hardcoded | [admission.go:359-361](https://github.com/openshift/kubernetes/blob/release-4.20/openshift-kube-apiserver/admission/autoscaling/managementcpusoverride/admission.go#L359-L361) |
| **Burstable** | Yes | cpushares calculated, CPU moved to workload resource | [admission.go:377-406](https://github.com/openshift/kubernetes/blob/release-4.20/openshift-kube-apiserver/admission/autoscaling/managementcpusoverride/admission.go#L377-L406) |
| **Burstable** | No (memory only) | **Skipped** -- no annotation | [admission.go:372-375](https://github.com/openshift/kubernetes/blob/release-4.20/openshift-kube-apiserver/admission/autoscaling/managementcpusoverride/admission.go#L372-L375) |
| **Guaranteed** | Yes (cpu and memory) | Entire pod skipped | [admission.go:254-258](https://github.com/openshift/kubernetes/blob/release-4.20/openshift-kube-apiserver/admission/autoscaling/managementcpusoverride/admission.go#L254-L258) |

## Kubelet Static Pod Path

| Pod QoS | Container has CPU request? | Result | Code reference |
|---|---|---|---|
| **BestEffort** | No cpu or memory requests | No annotation injected (silently skipped) | [managed.go:155-158](https://github.com/openshift/kubernetes/blob/release-4.20/pkg/kubelet/managed/managed.go#L155-L158) |
| **Burstable** | Yes | cpushares calculated, CPU moved to workload resource | [managed.go:189-215](https://github.com/openshift/kubernetes/blob/release-4.20/pkg/kubelet/managed/managed.go#L189-L215) |
| **Burstable** | No (memory only) | **Error** (`does not have cpu requests`) | [managed.go:179-180](https://github.com/openshift/kubernetes/blob/release-4.20/pkg/kubelet/managed/managed.go#L179-L180) |
| **Guaranteed** | Yes (cpu and memory) | Skipped; workload annotations stripped | [managed.go:137-141](https://github.com/openshift/kubernetes/blob/release-4.20/pkg/kubelet/managed/managed.go#L137-L141) |

## cpushares Formula

Shared by both paths:

```
shares = (milliCPU * 1024) / 1000
```

Clamped to `[2, 262144]`. When `milliCPU == 0`, returns `2` (Linux kernel
minimum for `cpu.shares`).

- Admission plugin: [helpers_linux.go:88-104](https://github.com/openshift/kubernetes/blob/release-4.20/pkg/kubelet/cm/helpers_linux.go#L88-L104)
- Kubelet: [cpu_shares.go:1-30](https://github.com/openshift/kubernetes/blob/release-4.20/pkg/kubelet/managed/cpu_shares.go#L1-L30)

## Containers Without CPU Requests Are Not Pinned to Reserved Cores

CRI-O's cpuset pinning is driven by the `management.workload.openshift.io/cores`
**resource request** on the container, not by the per-container annotation. The
`resources.workload.openshift.io/<container>` annotation only tells CRI-O the
cpushares value for cgroup configuration. Without the resource request, CRI-O
does not recognize the container as belonging to the management workload class.

Only the Burstable-with-CPU path adds this resource request: it deletes the
original `cpu` request and replaces it with `management.workload.openshift.io/cores`
([admission.go:393-404](https://github.com/openshift/kubernetes/blob/release-4.20/openshift-kube-apiserver/admission/autoscaling/managementcpusoverride/admission.go#L393-L404)).
The BestEffort path adds the annotation but `continue`s immediately, never
reaching the resource replacement
([admission.go:359-362](https://github.com/openshift/kubernetes/blob/release-4.20/openshift-kube-apiserver/admission/autoscaling/managementcpusoverride/admission.go#L359-L362)).
The Burstable memory-only path skips the container entirely
([admission.go:373-374](https://github.com/openshift/kubernetes/blob/release-4.20/openshift-kube-apiserver/admission/autoscaling/managementcpusoverride/admission.go#L373-L374)).

| Case | Gets annotation? | Gets `management.workload.openshift.io/cores` resource? | Pinned to reserved cpuset? |
|---|---|---|---|
| **BestEffort** | Yes (`cpushares: 2`) | No | **No** |
| **Burstable** (memory only) | No | No | **No** |
| **Burstable** (with CPU) | Yes (calculated) | Yes | **Yes** |
| **Guaranteed** | No | No | **No** |

The `target.workload.openshift.io/management` annotation on the **pod** is
necessary but not sufficient. What actually drives CRI-O's cpuset pinning is
the `management.workload.openshift.io/cores` resource request on each
container. Containers without a CPU request never get that resource, so they
inherit the **default cpuset** from their parent cgroup, which includes all
CPUs (reserved + isolated). This means those containers can schedule threads
on isolated cores meant for the application workload.
