#!/usr/bin/env bash
#
# DISCLAIMER: This script is not endorsed or supported in any way by Red Hat. Use at your own risk.
#
# unpatch-infra.sh - Revert workload partitioning from a cluster that was
#                    enabled via patch-infra.sh.
#
# Usage: ./unpatch-infra.sh
#
# IMPORTANT: Ordering matters. This script follows the correct sequence:
#
#   1. Patch Infrastructure.Status.CPUPartitioning back to "None".
#      This MUST happen first. Once the MCs are removed and nodes reboot,
#      the kubelet will no longer register management.workload.openshift.io/cores.
#      If the Infrastructure CR still says AllNodes at that point, the API server
#      will reject node updates -- the same deadlock as the forward direction.
#
#   2. Delete the 01-*-cpu-partitioning MachineConfigs.
#      This removes the kubelet and CRI-O workload pinning config files.
#      The MCO detects the change and triggers a rollout + node reboot.
#
#   3. Wait for MCO rollout to complete (nodes reboot).
#      After reboot, the kubelet starts without managed mode, static pods are
#      created with regular cpu requests, and CRI-O no longer has the management
#      workload class.
#
#   4. Force static pod revision rollouts.
#      Static pods created while managed mode was active still have
#      management.workload.openshift.io/cores resources. Forcing new revisions
#      causes the installer pod to rewrite the manifest and the kubelet to
#      recreate the pods -- this time without managed-mode rewriting.
#
#   5. Recreate MCO-delivered static pods (criometricsproxy).
#      Same as patch-infra.sh Step 6 but in reverse -- these need to be
#      recreated so the kubelet reads them without managed mode.
#
# NOTE: If a PerformanceProfile exists, the NTO controller will detect the
# Infrastructure CR change on its next reconcile and regenerate the
# 50-performance-* MC WITHOUT workload pinning files. This is automatic.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Verify oc is available and authenticated
if ! oc whoami &>/dev/null; then
    echo "ERROR: Not authenticated to any cluster. Run 'oc login' first."
    exit 1
fi

echo "==> Current state:"
CURRENT=$(oc get infrastructure cluster -o jsonpath='{.status.cpuPartitioning}' 2>/dev/null || echo "UNSET")
echo "    cpuPartitioning: ${CURRENT}"

if [[ "$CURRENT" == "None" ]]; then
    echo ""
    echo "    Already set to None."
fi

###############################################################################
# Step 1: Patch Infrastructure CR back to None
###############################################################################
echo ""
echo "==> Step 1: Patching Infrastructure CR status to cpuPartitioning: None"
echo "    This must happen BEFORE removing the MCs. If the kubelet reboots"
echo "    without the pinning config file while the API server still enforces"
echo "    AllNodes, the MCD will be unable to update node annotations."
echo ""

oc patch infrastructure cluster \
    --type merge \
    --subresource status \
    -p '{"status":{"cpuPartitioning":"None"}}'

echo ""
echo "==> Verifying patch:"
NEW=$(oc get infrastructure cluster -o jsonpath='{.status.cpuPartitioning}')
echo "    cpuPartitioning: ${NEW}"

if [[ "$NEW" != "None" ]]; then
    echo "ERROR: Patch did not take effect!"
    exit 1
fi

###############################################################################
# Step 2: Delete the 01-*-cpu-partitioning MachineConfigs
###############################################################################
echo ""
echo "==> Step 2: Deleting workload pinning MachineConfigs"
echo "    This removes /etc/kubernetes/openshift-workload-pinning and"
echo "    /etc/crio/crio.conf.d/01-workload-pinning-default.conf from nodes."
echo ""

for role in master worker; do
    MC="01-${role}-cpu-partitioning"
    if oc get mc "$MC" &>/dev/null; then
        echo "    Deleting ${MC}..."
        oc delete mc "$MC"
    else
        echo "    ${MC} not found, skipping."
    fi
done

###############################################################################
# Step 3: Wait for MCO rollout
###############################################################################
echo ""
echo "==> Step 3: Waiting for MachineConfigPool rollout (nodes will reboot)"
echo "    This may take 10-30 minutes depending on cluster size."
echo ""

sleep 10

for pool in master worker; do
    # Check if the pool has nodes before waiting
    NODE_COUNT=$(oc get mcp "$pool" -o jsonpath='{.status.machineCount}' 2>/dev/null || echo "0")
    if [[ "$NODE_COUNT" -eq 0 ]]; then
        echo "    ${pool} pool has no nodes, skipping."
        continue
    fi
    echo "    Waiting for ${pool} pool..."
    if ! oc wait mcp "${pool}" --for condition=Updated --timeout=45m 2>/dev/null; then
        echo "WARNING: ${pool} pool did not reach Updated state within 45 minutes."
        echo "         Check: oc get mcp ${pool} -o yaml"
    fi
done

###############################################################################
# Step 4: Force static pod revision rollouts
###############################################################################
echo ""
echo "==> Step 4: Forcing static pod revision rollouts"
echo "    Static pods created while managed mode was active still have"
echo "    management.workload.openshift.io/cores resources. Forcing new"
echo "    revisions causes the kubelet to recreate them with regular cpu."
echo ""

REASON="revert-workload-partitioning-$(date +%s)"

for operator in etcd kubeapiserver kubecontrollermanager kubescheduler; do
    OP_REASON="${REASON}-${operator}"

    case "$operator" in
        etcd) CO_NAME="etcd" ;;
        kubeapiserver) CO_NAME="kube-apiserver" ;;
        kubecontrollermanager) CO_NAME="kube-controller-manager" ;;
        kubescheduler) CO_NAME="kube-scheduler" ;;
    esac

    CURRENT_REV=$(oc get "${operator}" cluster -o jsonpath='{.status.latestAvailableRevision}' 2>/dev/null || echo "unknown")
    echo "    ${operator}: current revision=${CURRENT_REV}, patching with reason=${OP_REASON}..."

    oc patch "${operator}" cluster --type merge \
        -p "{\"spec\":{\"forceRedeploymentReason\":\"${OP_REASON}\"}}" 2>/dev/null || {
        echo "    WARNING: Could not patch ${operator}."
        continue
    }

    echo "    Waiting for new revision to be created..."
    for i in $(seq 1 60); do
        NEW_REV=$(oc get "${operator}" cluster -o jsonpath='{.status.latestAvailableRevision}' 2>/dev/null || echo "unknown")
        if [[ "$NEW_REV" != "$CURRENT_REV" && "$NEW_REV" != "unknown" ]]; then
            echo "    New revision ${NEW_REV} created (was ${CURRENT_REV})."
            break
        fi
        sleep 5
    done
    if [[ "$NEW_REV" == "$CURRENT_REV" ]]; then
        echo "    WARNING: No new revision created for ${operator} after 5 minutes."
        continue
    fi

    echo "    Waiting for ${CO_NAME} rollout to complete..."
    if ! oc wait co "${CO_NAME}" --for condition=Progressing=True --timeout=2m 2>/dev/null; then
        echo "    (Progressing did not become True -- rollout may have completed very quickly)"
    fi
    if ! oc wait co "${CO_NAME}" --for condition=Progressing=False --timeout=20m 2>/dev/null; then
        echo "    WARNING: ${CO_NAME} rollout may still be in progress."
    fi

    NODE_REVS=$(oc get "${operator}" cluster -o jsonpath='{range .status.nodeStatuses[*]}{.nodeName}={.currentRevision}{" "}{end}' 2>/dev/null || echo "unknown")
    echo "    ${operator} rollout complete. Node revisions: ${NODE_REVS}"
    echo ""
done

###############################################################################
# Step 5: Recreate MCO-delivered static pods
###############################################################################
echo ""
echo "==> Step 5: Recreating MCO-delivered static pods"
echo "    Pods like criometricsproxy need a manifest move-out/move-back"
echo "    so the kubelet recreates them without managed-mode rewriting."
echo ""

NODES=$(oc get nodes -o jsonpath='{.items[*].metadata.name}')
for node in $NODES; do
    echo "    Checking ${node} for workload-annotated MCO static pods..."
    STALE_MANIFESTS=$(oc debug "node/${node}" --quiet -- chroot /host bash -c '
        for f in /etc/kubernetes/manifests/*.yaml; do
            [ -f "$f" ] || continue
            basename="$(basename "$f" .yaml)"
            case "$basename" in
                etcd-pod|kube-apiserver-pod|kube-controller-manager-pod|kube-scheduler-pod) continue ;;
            esac
            if grep -q "target.workload.openshift.io/management" "$f" 2>/dev/null; then
                echo "$f"
            fi
        done
    ' 2>/dev/null || true)

    if [[ -z "$STALE_MANIFESTS" ]]; then
        echo "    ${node}: no MCO-delivered workload-annotated static pods found."
        continue
    fi

    echo "    ${node}: recreating: ${STALE_MANIFESTS}"
    # Collapse newlines to spaces so the list is valid inside a for-loop in bash -c
    STALE_MANIFESTS_FLAT=$(echo "$STALE_MANIFESTS" | tr '\n' ' ')
    oc debug "node/${node}" --quiet -- chroot /host bash -c "
        for f in ${STALE_MANIFESTS_FLAT}; do
            [ -f \"\$f\" ] || continue
            tmp=\"/etc/kubernetes/\$(basename \"\$f\").tmp\"
            mv \"\$f\" \"\$tmp\"
        done
        sleep 10
        for f in ${STALE_MANIFESTS_FLAT}; do
            [ -f \"\$f\" ] && continue
            tmp=\"/etc/kubernetes/\$(basename \"\$f\").tmp\"
            [ -f \"\$tmp\" ] && mv \"\$tmp\" \"\$f\"
        done
    " 2>/dev/null || echo "    WARNING: Failed to recreate static pods on ${node}."
done

echo ""
echo "    Waiting for pods to stabilize..."
sleep 15

###############################################################################
# Step 6: Restart all Deployment/DaemonSet/StatefulSet workloads in WP-labeled
#          namespaces so the admission webhook strips the WP annotations
###############################################################################
echo ""
echo "==> Step 6: Restarting workloads in all WP-labeled namespaces"
echo "    Now that cpuPartitioning=None, the kube-apiserver WP admission plugin"
echo "    strips target.workload.openshift.io/management from newly created pods."
echo "    On SNO the node reboot (Step 3) already restarted all pods; this step"
echo "    catches single-replica Deployments that may have migrated to non-rebooted"
echo "    nodes in multi-node clusters."
echo ""
echo "    Static pod namespaces are skipped -- already handled by Step 4."
echo ""

WP_NAMESPACES=$(oc get namespaces -o json 2>/dev/null | \
    jq -r '.items[] | select(.metadata.annotations["workload.openshift.io/allowed"] == "management") | .metadata.name' | sort)

for ns in $WP_NAMESPACES; do

    DEPLOYMENTS=$(oc get deployment   -n "$ns" -o name 2>/dev/null || true)
    DAEMONSETS=$(oc get daemonset     -n "$ns" -o name 2>/dev/null || true)
    STATEFULSETS=$(oc get statefulset -n "$ns" -o name 2>/dev/null || true)

    if [[ -z "$DEPLOYMENTS$DAEMONSETS$STATEFULSETS" ]]; then
        echo "    ${ns}: no workloads, skipping."
        continue
    fi

    echo "    ${ns}: restarting..."
    [[ -n "$DEPLOYMENTS"  ]] && oc rollout restart deployment   -n "$ns" 2>/dev/null || true
    [[ -n "$DAEMONSETS"   ]] && oc rollout restart daemonset    -n "$ns" 2>/dev/null || true
    [[ -n "$STATEFULSETS" ]] && oc rollout restart statefulset  -n "$ns" 2>/dev/null || true

    for res in $DEPLOYMENTS $DAEMONSETS $STATEFULSETS; do
        if ! oc rollout status "$res" -n "$ns" --timeout=10m 2>/dev/null; then
            echo "    WARNING: ${ns}/${res} did not settle within 10m -- check manually."
        fi
    done
    echo "    ${ns}: done."
done

echo ""
echo "    Verifying WP annotations stripped from workload-managed pods..."
STILL_ANNOTATED=()
for ns in $WP_NAMESPACES; do
    ANNOTATED=$(oc get pods -n "$ns" -o json 2>/dev/null | jq -r '
        .items[] |
        select(.metadata.ownerReferences != null) |
        select([.metadata.ownerReferences[].kind] | any(. == "ReplicaSet" or . == "DaemonSet" or . == "StatefulSet")) |
        select(.metadata.annotations["target.workload.openshift.io/management"] != null) |
        .metadata.name
    ' 2>/dev/null || true)
    if [[ -n "$ANNOTATED" ]]; then
        echo "    STILL ANNOTATED in ${ns}: $(echo "$ANNOTATED" | tr '\n' ' ')"
        STILL_ANNOTATED+=("$ns")
    fi
done
if [[ ${#STILL_ANNOTATED[@]} -eq 0 ]]; then
    echo "    OK: No workload-managed pods in WP-labeled namespaces retain the target annotation."
fi

###############################################################################
# Verification
###############################################################################
echo ""
echo "==> Verifying revert..."

echo ""
echo "    Infrastructure CR:"
echo "    cpuPartitioning: $(oc get infrastructure cluster -o jsonpath='{.status.cpuPartitioning}')"

echo ""
echo "    01-*-cpu-partitioning MCs:"
for role in master worker; do
    if oc get mc "01-${role}-cpu-partitioning" &>/dev/null 2>&1; then
        echo "    WARNING: 01-${role}-cpu-partitioning still exists!"
    else
        echo "    01-${role}-cpu-partitioning: DELETED"
    fi
done

echo ""
echo "    Checking for static pods still using management.workload.openshift.io/cores..."
WP_FOUND=false
for ns in openshift-etcd openshift-kube-apiserver openshift-kube-controller-manager openshift-kube-scheduler; do
    WP_PODS=$(oc get pods -n "$ns" -o json 2>/dev/null | jq -r '
        .items[] |
        select(.spec.containers[].resources.requests["management.workload.openshift.io/cores"] != null) |
        .metadata.name
    ' 2>/dev/null || true)
    if [[ -n "$WP_PODS" ]]; then
        echo "    WARNING: Pods in ${ns} still using management.workload.openshift.io/cores:"
        echo "$WP_PODS" | sed 's/^/      /'
        WP_FOUND=true
    fi
done

RESIZE_FOUND=false
for ns in openshift-etcd openshift-kube-apiserver openshift-kube-controller-manager openshift-kube-scheduler; do
    PENDING=$(oc get pods -n "$ns" -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .status.conditions[?(@.type=="PodResizePending")]}{.message}{end}{"\n"}{end}' 2>/dev/null | grep -v '^$' | grep -v $'\t$' || true)
    if [[ -n "$PENDING" ]]; then
        echo "    WARNING: PodResizePending still present in ${ns}:"
        echo "$PENDING" | sed 's/^/      /'
        RESIZE_FOUND=true
    fi
done

if [[ "$WP_FOUND" == "false" && "$RESIZE_FOUND" == "false" ]]; then
    echo "    OK: All static pods use regular cpu requests, no PodResizePending."
fi

echo ""
echo "==> Done. Workload partitioning has been reverted."
echo ""
echo "    Note: If a PerformanceProfile exists, the NTO controller will have"
echo "    regenerated the 50-performance-* MC without workload pinning files."
echo "    CPU isolation (reserved/isolated) via the PerformanceProfile is still"
echo "    active -- only the management pod pinning mechanism has been removed."
