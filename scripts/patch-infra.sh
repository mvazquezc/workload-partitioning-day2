#!/bin/bash
#
# DISCLAIMER: This script is not endorsed or supported in any way by Red Hat. Use at your own risk.
#
# patch-infra.sh - Enable workload partitioning on a cluster deployed without
#                  cpuPartitioningMode: AllNodes.
#
# Usage: ./patch-infra.sh
#
# IMPORTANT: Ordering matters. This script follows the correct sequence:
#
#   1. Apply the workload pinning MachineConfigs (delivers the kubelet and
#      CRI-O config files with empty cpusets to all nodes).
#   2. Wait for MCO rollout + node reboots to complete.
#   3. After reboot, kubelet reads /etc/kubernetes/openshift-workload-pinning,
#      enables managed mode, and registers management.workload.openshift.io/cores
#      as an extended resource on the Node object.
#   4. Only THEN patch Infrastructure.Status.CPUPartitioning = AllNodes.
#
# If you patch the Infrastructure CR before the kubelet has registered the
# extended resource, the kube-apiserver will reject all Node updates with:
#
#   "node does not contain resource information, this is required for clusters
#    with workload partitioning enabled"
#
# This blocks the MCD from updating node annotations, preventing the MCO
# rollout that would deliver the config files -- a deadlock.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
MANIFESTS_DIR="${PROJECT_DIR}/manifests"

# Verify oc is available and authenticated
if ! oc whoami &>/dev/null; then
    echo "ERROR: Not authenticated to any cluster. Run 'oc login' first."
    exit 1
fi

echo "==> Current state:"
CURRENT=$(oc get infrastructure cluster -o jsonpath='{.status.cpuPartitioning}' 2>/dev/null || echo "UNSET")
echo "    cpuPartitioning: ${CURRENT}"

if [[ "$CURRENT" == "AllNodes" ]]; then
    echo ""
    echo "    Already set to AllNodes, nothing to do."
    exit 0
fi

###############################################################################
# Step 1: Apply workload pinning MachineConfigs
###############################################################################
echo ""
echo "==> Step 1: Applying workload pinning MachineConfigs"
echo "    These deliver /etc/kubernetes/openshift-workload-pinning and"
echo "    /etc/crio/crio.conf.d/01-workload-pinning-default.conf to all nodes."
echo ""

for role in master worker; do
    MC_FILE="${MANIFESTS_DIR}/01-${role}-cpu-partitioning.yaml"
    if [[ ! -f "$MC_FILE" ]]; then
        echo "ERROR: ${MC_FILE} not found."
        exit 1
    fi

    # Check if MC already exists
    if oc get mc "01-${role}-cpu-partitioning" &>/dev/null; then
        echo "    01-${role}-cpu-partitioning MC already exists, skipping."
    else
        echo "    Applying 01-${role}-cpu-partitioning MC..."
        oc apply -f "$MC_FILE"
    fi
done

###############################################################################
# Step 2: Wait for MCO rollout
###############################################################################
echo ""
echo "==> Step 2: Waiting for MachineConfigPool rollout (nodes will reboot)"
echo "    This may take 10-30 minutes depending on cluster size."
echo ""

sleep 10

for pool in master worker; do
    echo "    Waiting for ${pool} pool..."
    if ! oc wait mcp "${pool}" --for condition=Updated --timeout=120m 2>/dev/null; then
        echo "WARNING: ${pool} pool did not reach Updated state within 120 minutes."
        echo "         Check: oc get mcp ${pool} -o yaml"
        echo "         Continuing anyway -- the Infrastructure patch may fail if nodes"
        echo "         haven't rebooted yet."
    fi
done

###############################################################################
# Step 3: Verify kubelet registered the extended resource
###############################################################################
echo ""
echo "==> Step 3: Verifying kubelet registered management.workload.openshift.io/cores"

NODES=$(oc get nodes -o jsonpath='{.items[*].metadata.name}')
ALL_READY=true
for node in $NODES; do
    RESOURCE=$(oc get node "$node" -o jsonpath='{.status.capacity.management\.workload\.openshift\.io/cores}' 2>/dev/null || echo "")
    if [[ -z "$RESOURCE" ]]; then
        echo "    WARNING: ${node} does NOT have management.workload.openshift.io/cores in status.capacity"
        ALL_READY=false
    else
        echo "    OK: ${node} has management.workload.openshift.io/cores = ${RESOURCE}"
    fi
done

if [[ "$ALL_READY" != "true" ]]; then
    echo ""
    echo "ERROR: Not all nodes have registered the workload extended resource."
    echo "       The kubelet needs /etc/kubernetes/openshift-workload-pinning to exist"
    echo "       at startup. Ensure the MCO rollout completed and nodes rebooted."
    echo "       DO NOT patch the Infrastructure CR until this is resolved."
    exit 1
fi

###############################################################################
# Step 4: Patch Infrastructure CR
###############################################################################
echo ""
echo "==> Step 4: Patching Infrastructure CR status to cpuPartitioning: AllNodes"
oc patch infrastructure cluster \
    --type merge \
    --subresource status \
    -p '{"status":{"cpuPartitioning":"AllNodes"}}'

echo ""
echo "==> Verifying patch:"
NEW=$(oc get infrastructure cluster -o jsonpath='{.status.cpuPartitioning}')
echo "    cpuPartitioning: ${NEW}"

if [[ "$NEW" != "AllNodes" ]]; then
    echo "ERROR: Patch did not take effect!"
    exit 1
fi

###############################################################################
# Step 5: Force static pod revision rollouts
###############################################################################
echo ""
echo "==> Step 5: Forcing static pod revision rollouts"
echo "    The kubelet rewrites static pod CPU requests from 'cpu' to"
echo "    'management.workload.openshift.io/cores' at file read time."
echo "    Static pods created before managed mode was enabled still have"
echo "    the old 'cpu' resource requests. In-place resize of static pods"
echo "    is not supported by Kubernetes, so the pods must be fully recreated."
echo ""
echo "    Forcing a new revision via forceRedeploymentReason causes the"
echo "    operator's installer pod to delete and rewrite the manifest with"
echo "    a new revision number. The kubelet detects the content change,"
echo "    recreates the pod, and applies managed-mode resource rewriting."
echo ""

REASON="workload-partitioning-$(date +%s)"

# Force new revisions -- each operator is patched sequentially and we wait
# for it to fully roll out before proceeding to the next, to avoid
# disrupting multiple control plane components simultaneously.
for operator in etcd kubeapiserver kubecontrollermanager kubescheduler; do
    # Use a unique reason per operator to guarantee a change
    OP_REASON="${REASON}-${operator}"

    # Map operator resource name to cluster operator name
    case "$operator" in
        etcd) CO_NAME="etcd" ;;
        kubeapiserver) CO_NAME="kube-apiserver" ;;
        kubecontrollermanager) CO_NAME="kube-controller-manager" ;;
        kubescheduler) CO_NAME="kube-scheduler" ;;
    esac

    # Get current revision before patching
    CURRENT_REV=$(oc get "${operator}" cluster -o jsonpath='{.status.latestAvailableRevision}' 2>/dev/null || echo "unknown")
    echo "    ${operator}: current revision=${CURRENT_REV}, patching with reason=${OP_REASON}..."

    oc patch "${operator}" cluster --type merge \
        -p "{\"spec\":{\"forceRedeploymentReason\":\"${OP_REASON}\"}}" 2>/dev/null || {
        echo "    WARNING: Could not patch ${operator}."
        continue
    }

    # Wait for the revision to increment (new revision created)
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
        echo "             Current forceRedeploymentReason may be identical to previous value."
        continue
    fi

    # Wait for all nodes to reach the new revision
    echo "    Waiting for ${CO_NAME} rollout to complete..."
    if ! oc wait co "${CO_NAME}" --for condition=Progressing=True --timeout=5m 2>/dev/null; then
        echo "    (Progressing did not become True -- rollout may have completed very quickly)"
    fi
    if ! oc wait co "${CO_NAME}" --for condition=Progressing=False --timeout=40m 2>/dev/null; then
        echo "    WARNING: ${CO_NAME} rollout may still be in progress."
    fi

    # Verify node revisions match
    NODE_REVS=$(oc get "${operator}" cluster -o jsonpath='{range .status.nodeStatuses[*]}{.nodeName}={.currentRevision}{" "}{end}' 2>/dev/null || echo "unknown")
    echo "    ${operator} rollout complete. Node revisions: ${NODE_REVS}"
    echo ""
done

echo "    Verifying static pods use management.workload.openshift.io/cores..."
WP_ISSUES=false
for ns in openshift-etcd openshift-kube-apiserver openshift-kube-controller-manager openshift-kube-scheduler; do
    # Check if any pod in the namespace still uses regular cpu requests
    CPU_PODS=$(oc get pods -n "$ns" -o json 2>/dev/null | jq -r '
        .items[] |
        select(.metadata.annotations["target.workload.openshift.io/management"] != null) |
        select(.spec.containers[].resources.requests.cpu != null) |
        .metadata.name
    ' 2>/dev/null || true)
    if [[ -n "$CPU_PODS" ]]; then
        echo "    WARNING: Pods in ${ns} still using cpu requests:"
        echo "$CPU_PODS" | sed 's/^/      /'
        WP_ISSUES=true
    fi
done

# Also check for PodResizePending
RESIZE_FOUND=false
for ns in openshift-etcd openshift-kube-apiserver openshift-kube-controller-manager openshift-kube-scheduler; do
    PENDING=$(oc get pods -n "$ns" -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .status.conditions[?(@.type=="PodResizePending")]}{.message}{end}{"\n"}{end}' 2>/dev/null | grep -v '^$' | grep -v $'\t$' || true)
    if [[ -n "$PENDING" ]]; then
        echo "    WARNING: PodResizePending still present in ${ns}:"
        echo "$PENDING" | sed 's/^/      /'
        RESIZE_FOUND=true
    fi
done

if [[ "$WP_ISSUES" == "false" && "$RESIZE_FOUND" == "false" ]]; then
    echo "    OK: All operator-managed static pods use management.workload.openshift.io/cores, no PodResizePending."
fi

###############################################################################
# Step 6: Fix MCO-delivered static pods (criometricsproxy)
###############################################################################
echo ""
echo "==> Step 6: Recreating MCO-delivered static pods"
echo "    Some static pods (e.g., criometricsproxy) are delivered by the MCO"
echo "    as ignition files, not managed by revisioned operators. These cannot"
echo "    be fixed via forceRedeploymentReason. We recreate them by temporarily"
echo "    moving the manifest out of /etc/kubernetes/manifests/ and back."
echo ""

NODES=$(oc get nodes -o jsonpath='{.items[*].metadata.name}')
for node in $NODES; do
    echo "    Checking ${node} for non-WP static pods..."
    # Find static pods that still use cpu requests (not management.workload.openshift.io/cores)
    STALE_MANIFESTS=$(oc debug "node/${node}" --quiet -- chroot /host bash -c '
        for f in /etc/kubernetes/manifests/*.yaml; do
            [ -f "$f" ] || continue
            basename="$(basename "$f" .yaml)"
            # Skip operator-managed pods (already handled by forceRedeploymentReason)
            case "$basename" in
                etcd-pod|kube-apiserver-pod|kube-controller-manager-pod|kube-scheduler-pod) continue ;;
            esac
            # Check if this manifest has the workload annotation
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
    oc debug "node/${node}" --quiet -- chroot /host bash -c "
        for f in ${STALE_MANIFESTS}; do
            [ -f \"\$f\" ] || continue
            tmp=\"/etc/kubernetes/\$(basename \"\$f\").tmp\"
            mv \"\$f\" \"\$tmp\"
        done
        sleep 10
        for f in ${STALE_MANIFESTS}; do
            [ -f \"\$f\" ] && continue
            tmp=\"/etc/kubernetes/\$(basename \"\$f\").tmp\"
            [ -f \"\$tmp\" ] && mv \"\$tmp\" \"\$f\"
        done
    " 2>/dev/null || echo "    WARNING: Failed to recreate static pods on ${node}."
done

echo ""
echo "    Waiting for pods to stabilize..."
sleep 15

echo ""
echo "==> Done. The cluster is now in workload partitioning mode."
echo ""
echo "    Next steps:"
echo "    1. Apply the PerformanceProfile:  oc apply -f manifests/performanceprofile.yaml"
echo "    2. Wait for MCP rollout:          oc wait mcp master --for condition=Updated --timeout=120m"
echo "    3. The NTO controller will generate 50-performance-* MCs with actual"
echo "       reserved CPU pinning configs that override the empty-cpuset defaults."
