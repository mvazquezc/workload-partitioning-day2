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
