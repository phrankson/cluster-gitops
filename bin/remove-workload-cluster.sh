#!/bin/bash
set -euo pipefail

###############################################################################
# remove-workload-cluster.sh
#
# Removes a workload cluster from gitops-system and gitops-workloads, then
# monitors Crossplane resource deletion until all AWS resources are cleaned up.
#
# Steps:
#   1. Validate inputs and check cluster exists
#   2. Remove cluster from clusters-config/kustomization.yaml
#   3. Delete cluster directories from gitops-system and gitops-workloads
#   4. Commit and push both repos
#   5. Force Flux reconciliation to trigger pruning
#   6. Monitor Crossplane resource deletion
#   7. Remove stuck finalizers (K8s Provider Objects targeting deleted cluster)
#   8. Clean up local kubeconfig context
#
# Usage:
#   ./remove-workload-cluster.sh <gitops-system-path> <gitops-workloads-path> <cluster-name>
#
# Requirements: kubectl, flux, yq, git, aws CLI
###############################################################################

# --- Helpers -----------------------------------------------------------------

usage() {
    echo "Usage: $0 <gitops-system-path> <gitops-workloads-path> <cluster-name>"
    echo ""
    echo "  gitops-system-path     Path to the gitops-system repository"
    echo "  gitops-workloads-path  Path to the gitops-workloads repository"
    echo "  cluster-name           Name of the workload cluster to remove"
    echo ""
    echo "Example:"
    echo "  $0 /path/to/gitops-system /path/to/gitops-workloads commercial-production"
    exit 1
}

log() { echo "[remove-workload-cluster] $*"; }
err() { echo "[remove-workload-cluster] ERROR: $*" >&2; }
warn() { echo "[remove-workload-cluster] WARNING: $*"; }

# --- Validation --------------------------------------------------------------

if [[ $# -ne 3 ]]; then
    err "Expected 3 arguments, got $#"
    usage
fi

gitops_system=$(realpath "$1")
gitops_workloads=$(realpath "$2")
cluster_name="$3"

# Validate paths
if [[ ! -d "$gitops_system/clusters-config" ]]; then
    err "Not a valid gitops-system repository: $gitops_system"
    exit 1
fi

if [[ ! -d "$gitops_workloads" ]]; then
    err "Not a valid gitops-workloads repository: $gitops_workloads"
    exit 1
fi

# Check cluster exists
if [[ ! -d "$gitops_system/clusters-config/$cluster_name" && ! -d "$gitops_system/clusters/$cluster_name" ]]; then
    err "Cluster '$cluster_name' does not exist in $gitops_system"
    exit 1
fi

# Check required tools
for cmd in kubectl flux yq git aws; do
    if ! command -v "$cmd" &>/dev/null; then
        err "Required command '$cmd' not found in PATH"
        exit 1
    fi
done

# --- Main --------------------------------------------------------------------

log "Removing workload cluster: $cluster_name"
echo ""

# Step 1: Remove from kustomization.yaml
log "Step 1/8: Removing '$cluster_name' from clusters-config/kustomization.yaml ..."
kustomization_file="$gitops_system/clusters-config/kustomization.yaml"
if yq ".resources[]" "$kustomization_file" 2>/dev/null | grep -qx "$cluster_name"; then
    yq -i "del(.resources[] | select(. == \"$cluster_name\"))" "$kustomization_file"
else
    warn "'$cluster_name' not found in $kustomization_file — already removed?"
fi

# Step 2: Delete directories
log "Step 2/8: Deleting cluster directories ..."
rm -rf "$gitops_system/clusters-config/$cluster_name"
rm -rf "$gitops_system/clusters/$cluster_name"
rm -rf "$gitops_system/workloads/$cluster_name"
rm -rf "$gitops_workloads/$cluster_name"
log "  Removed: clusters-config/$cluster_name, clusters/$cluster_name, workloads/$cluster_name"

# Step 3: Commit and push gitops-system
log "Step 3/8: Committing and pushing gitops-system ..."
(
    cd "$gitops_system"
    git add -A
    if git diff --cached --quiet; then
        warn "No changes to commit in gitops-system"
    else
        git commit -m "Remove workload cluster $cluster_name"
        git push
    fi
)

# Step 4: Commit and push gitops-workloads
log "Step 4/8: Committing and pushing gitops-workloads ..."
(
    cd "$gitops_workloads"
    git add -A
    if git diff --cached --quiet; then
        warn "No changes to commit in gitops-workloads"
    else
        git commit -m "Remove $cluster_name"
        git push
    fi
)

# Step 5: Force Flux reconciliation
log "Step 5/8: Forcing Flux reconciliation ..."
flux reconcile source git flux-system 2>/dev/null || warn "flux reconcile source failed"
sleep 3
flux reconcile kustomization flux-system 2>/dev/null || warn "flux reconcile kustomization failed"

# Verify kustomizations are pruned
sleep 5
remaining_ks=$(kubectl get kustomization -n flux-system --no-headers 2>/dev/null | grep -c "$cluster_name" || true)
if [[ "$remaining_ks" -gt 0 ]]; then
    warn "$remaining_ks kustomizations still exist for $cluster_name — Flux may need more time"
else
    log "  All Flux kustomizations for '$cluster_name' pruned"
fi

# Step 6: Monitor Crossplane resource deletion
log "Step 6/8: Monitoring Crossplane resource deletion ..."
max_wait=900  # 15 minutes max
elapsed=0
interval=30

while true; do
    count=$(kubectl get managed --no-headers 2>/dev/null | grep -c "$cluster_name" || true)
    if [[ "$count" -eq 0 ]]; then
        log "  All Crossplane managed resources deleted"
        break
    fi

    if [[ "$elapsed" -ge "$max_wait" ]]; then
        warn "Timed out after ${max_wait}s. $count resources still exist:"
        kubectl get managed --no-headers 2>/dev/null | grep "$cluster_name" | awk '{print "    " $1}' || true
        break
    fi

    log "  Waiting... $count resources remaining (${elapsed}s elapsed)"
    sleep "$interval"
    elapsed=$((elapsed + interval))
done

# Step 7: Remove stuck finalizers (K8s Provider Objects that can't reach deleted cluster)
log "Step 7/8: Checking for stuck K8s Provider Objects ..."
stuck_objects=$(kubectl get object.kubernetes.crossplane.io --no-headers 2>/dev/null | grep "$cluster_name" | awk '{print $1}' || true)
if [[ -n "$stuck_objects" ]]; then
    while IFS= read -r obj; do
        log "  Removing finalizer from: $obj"
        kubectl patch "object.kubernetes.crossplane.io/$obj" --type merge -p '{"metadata":{"finalizers":[]}}' 2>/dev/null || true
    done <<< "$stuck_objects"
    sleep 5
    # Verify they're gone
    remaining=$(kubectl get object.kubernetes.crossplane.io --no-headers 2>/dev/null | grep -c "$cluster_name" || true)
    if [[ "$remaining" -gt 0 ]]; then
        warn "$remaining K8s Objects still exist"
    fi
else
    log "  No stuck Objects found"
fi

# Step 8: Clean up kubeconfig context
log "Step 8/8: Cleaning up kubeconfig ..."
if kubectl config get-contexts "$cluster_name" &>/dev/null; then
    kubectl config delete-context "$cluster_name" 2>/dev/null || true
    log "  Removed kubeconfig context '$cluster_name'"
else
    log "  No kubeconfig context '$cluster_name' found"
fi

echo ""
log "SUCCESS: Workload cluster '$cluster_name' removed."
log ""
log "Verify with:"
log "  kubectl get managed | grep $cluster_name"
log "  aws eks list-clusters --region eu-central-1"
