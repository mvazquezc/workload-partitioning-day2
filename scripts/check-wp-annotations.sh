#!/usr/bin/env bash
#
# DISCLAIMER: This script is not endorsed or supported in any way by Red Hat. Use at your own risk.
#
# check-wp-annotations.sh - Audit workload partitioning annotations across the cluster.
#
# For each namespace:
#   IS MGMT        namespace has label workload.openshift.io/allowed=management
#
# For each pod in that namespace:
#   MGMT SCHED     pod carries target.workload.openshift.io/management annotation
#   WKLD ANNOTS    pod carries at least one resources.workload.openshift.io/* annotation
#   CORES REQ      every container requests management.workload.openshift.io/cores and no cpu
#
# Lines are printed in red when the namespace IS management but the pod is
# missing MGMT SCHED or WKLD ANNOTS.
#
# Namespaces with no pods are omitted.
#
# Exit codes:
#   0  No issues found
#   1  One or more red lines

set -euo pipefail

if ! oc whoami &>/dev/null; then
    echo "ERROR: Not authenticated. Run 'oc login' first." >&2
    exit 1
fi

RED=$'\033[0;31m'
NC=$'\033[0m'

# Column widths
W_NS=52
W_MGMT=8
W_POD=70
W_SCHED=11
W_ANNOTS=12
W_CORES=9

TOTAL_W=$(( W_NS + W_MGMT + W_POD + W_SCHED + W_ANNOTS + W_CORES + 10 ))
SEP=$(printf '%.0s─' $(seq 1 $TOTAL_W))

print_row() {
    # args: namespace is_mgmt pod mgmt_sched wkld_annots cores_req color
    local line
    line=$(printf "%-${W_NS}s  %-${W_MGMT}s  %-${W_POD}s  %-${W_SCHED}s  %-${W_ANNOTS}s  %s" \
        "$1" "$2" "$3" "$4" "$5" "$6")
    if [[ -n "$7" ]]; then
        echo "${7}${line}${NC}"
    else
        echo "$line"
    fi
}

echo ""
print_row "NAMESPACE" "IS MGMT" "POD" "MGMT SCHED" "WKLD ANNOTS" "CORES REQ" ""
echo "$SEP"

ISSUES=0
TOTAL_PODS=0

# Use $'\x1f' (ASCII unit separator) as the field delimiter inside jq output
# so that tabs or spaces in values never break the read.
FS=$'\x1f'

while IFS= read -r ns; do

    # </dev/null on every oc call prevents it from consuming the outer
    # loop's stdin (the process substitution feeding namespace names).

    # --- Namespace: is it labeled as management? ---
    NS_JSON=$(oc get ns "$ns" -o json </dev/null 2>/dev/null) || continue

    is_mgmt=$(echo "$NS_JSON" | jq -r '
        if .metadata.annotations["workload.openshift.io/allowed"] == "management"
        then "yes" else "no" end')

    # --- Pods ---
    PODS_JSON=$(oc -n "$ns" get pods -o json </dev/null 2>/dev/null) || continue
    pod_count=$(echo "$PODS_JSON" | jq '.items | length')
    [[ "$pod_count" -eq 0 ]] && continue

    while IFS="$FS" read -r pod_name mgmt_sched wkld_annots cores_req; do
        TOTAL_PODS=$(( TOTAL_PODS + 1 ))

        color=""
        if [[ "$is_mgmt" == "yes" && \
              ("$mgmt_sched" == "no" || "$wkld_annots" == "no") ]]; then
            color="$RED"
            ISSUES=$(( ISSUES + 1 ))
        fi

        print_row "$ns" "$is_mgmt" "$pod_name" \
                  "$mgmt_sched" "$wkld_annots" "$cores_req" "$color"

    done < <(echo "$PODS_JSON" | jq -r --arg fs "$FS" '
        .items[] | select(.status.phase != "Succeeded" and .status.phase != "Failed") | [

            # Pod name
            .metadata.name,

            # MGMT SCHED: pod has target.workload.openshift.io/management annotation
            (if .metadata.annotations["target.workload.openshift.io/management"] != null
             then "yes" else "no" end),

            # WKLD ANNOTS: pod has at least one resources.workload.openshift.io/* annotation
            (if [ (.metadata.annotations // {}) | keys[] |
                  select(startswith("resources.workload.openshift.io/")) ] | length > 0
             then "yes" else "no" end),

            # CORES REQ: every container requests management.workload.openshift.io/cores
            #            and does NOT request cpu
            (if (.spec.containers | length) == 0 then "no"
             else
               [ .spec.containers[] |
                 (.resources.requests // {}) |
                 ( has("management.workload.openshift.io/cores") and
                   (has("cpu") | not) )
               ] | all | if . then "yes" else "no" end
             end)

        ] | join($fs)')

done < <(oc get ns -o name </dev/null 2>/dev/null | sed 's|^namespace/||' | sort)

echo "$SEP"
if [[ $ISSUES -eq 0 ]]; then
    printf "  %d pods checked  ·  no issues\n\n" "$TOTAL_PODS"
else
    printf "  %d pods checked  ·  %s%d pods in management namespaces missing expected annotations%s\n\n" \
        "$TOTAL_PODS" "$RED" "$ISSUES" "$NC"
fi

[[ $ISSUES -eq 0 ]] && exit 0 || exit 1
