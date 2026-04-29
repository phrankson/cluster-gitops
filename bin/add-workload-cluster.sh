#!/bin/bash
set -euo pipefail

###############################################################################
# add-workload-cluster.sh
#
# Adds a new workload cluster to the gitops-system repository by:
#   1. Copying clusters-config/template → clusters-config/<cluster-name>
#   2. Copying clusters/template → clusters/<cluster-name>
#   3. Copying workloads/template → workloads/<cluster-name>
#   4. Replacing 'cluster-name' placeholder in all copied files
#   5. Registering the cluster in clusters-config/kustomization.yaml
#   6. Creating <cluster-name>/ directory in gitops-workloads (if path provided)
#
# Usage:
#   ./add-workload-cluster.sh <gitops-system-path> <cluster-name> [gitops-workloads-path]
#
# After running, commit and push both repos for Flux to provision the cluster.
###############################################################################

# --- Helpers -----------------------------------------------------------------

usage() {
    echo "Usage: $0 <gitops-system-path> <cluster-name> [gitops-workloads-path]"
    echo ""
    echo "  gitops-system-path     Path to the gitops-system repository"
    echo "  cluster-name           Name for the new workload cluster (lowercase, alphanumeric + hyphens)"
    echo "  gitops-workloads-path  (Optional) Path to the gitops-workloads repository"
    echo ""
    echo "Example:"
    echo "  $0 /path/to/gitops-system commercial-staging /path/to/gitops-workloads"
    exit 1
}

log() { echo "[add-workload-cluster] $*"; }
err() { echo "[add-workload-cluster] ERROR: $*" >&2; }

# --- Validation --------------------------------------------------------------

if [[ $# -lt 2 || $# -gt 3 ]]; then
    err "Expected 2 or 3 arguments, got $#"
    usage
fi

gitops_system=$(realpath "$1")
cluster_name="$2"
gitops_workloads="${3:-}"
if [[ -n "$gitops_workloads" ]]; then
    gitops_workloads=$(realpath "$gitops_workloads")
fi

# Validate cluster name (RFC 1123 subdomain: lowercase alphanumeric + hyphens, max 63 chars)
if [[ ! "$cluster_name" =~ ^[a-z][a-z0-9-]{0,61}[a-z0-9]$ ]]; then
    err "Invalid cluster name '$cluster_name'"
    err "Must be lowercase, start with a letter, contain only [a-z0-9-], and be 2-63 characters."
    exit 1
fi

# Validate gitops-system path
if [[ ! -d "$gitops_system/clusters-config/template" ]]; then
    err "Directory not found: $gitops_system/clusters-config/template"
    err "Is '$1' a valid gitops-system repository?"
    exit 1
fi

if [[ ! -d "$gitops_system/clusters/template" ]]; then
    err "Directory not found: $gitops_system/clusters/template"
    exit 1
fi

if [[ ! -d "$gitops_system/workloads/template" ]]; then
    err "Directory not found: $gitops_system/workloads/template"
    exit 1
fi

# Validate gitops-workloads path if provided
if [[ -n "$gitops_workloads" ]]; then
    if [[ ! -d "$gitops_workloads" ]]; then
        err "Directory not found: $gitops_workloads"
        exit 1
    fi
    if [[ ! -d "$gitops_workloads/template" ]]; then
        err "Directory not found: $gitops_workloads/template"
        err "Is '$3' a valid gitops-workloads repository?"
        exit 1
    fi
fi

# Check if cluster already exists
if [[ -d "$gitops_system/clusters-config/$cluster_name" ]]; then
    err "Cluster '$cluster_name' already exists at $gitops_system/clusters-config/$cluster_name"
    exit 1
fi

if [[ -d "$gitops_system/clusters/$cluster_name" ]]; then
    err "Cluster '$cluster_name' already exists at $gitops_system/clusters/$cluster_name"
    exit 1
fi

# Check required tools
for cmd in yq sed grep; do
    if ! command -v "$cmd" &>/dev/null; then
        err "Required command '$cmd' not found in PATH"
        exit 1
    fi
done

# --- Main --------------------------------------------------------------------

log "Adding workload cluster: $cluster_name"
log "gitops-system path: $gitops_system"
echo ""

# Step 1: Copy clusters-config template
log "Step 1/6: Creating clusters-config/$cluster_name ..."
mkdir -p "$gitops_system/clusters-config/$cluster_name"
cp -R "$gitops_system/clusters-config/template/"* "$gitops_system/clusters-config/$cluster_name/"

# Step 2: Copy clusters template
log "Step 2/6: Creating clusters/$cluster_name ..."
mkdir -p "$gitops_system/clusters/$cluster_name"
cp -R "$gitops_system/clusters/template/"* "$gitops_system/clusters/$cluster_name/"

# Step 3: Copy workloads template
log "Step 3/6: Creating workloads/$cluster_name ..."
mkdir -p "$gitops_system/workloads/$cluster_name"
cp -R "$gitops_system/workloads/template/"* "$gitops_system/workloads/$cluster_name/"

# Step 4: Replace placeholder 'cluster-name' with actual cluster name
log "Step 4/6: Replacing 'cluster-name' placeholder with '$cluster_name' ..."

replace_placeholder() {
    local dir="$1"
    local files
    files=$(grep -RiIl 'cluster-name' "$dir" 2>/dev/null || true)
    if [[ -n "$files" ]]; then
        echo "$files" | while IFS= read -r f; do
            sed -i '' "s/cluster-name/$cluster_name/g" "$f"
        done
    fi
}

replace_placeholder "$gitops_system/clusters-config/$cluster_name"
replace_placeholder "$gitops_system/clusters/$cluster_name"
replace_placeholder "$gitops_system/workloads/$cluster_name"

# Step 5: Register cluster in clusters-config/kustomization.yaml
log "Step 5/6: Registering '$cluster_name' in clusters-config/kustomization.yaml ..."

kustomization_file="$gitops_system/clusters-config/kustomization.yaml"
if [[ ! -f "$kustomization_file" ]]; then
    err "File not found: $kustomization_file"
    exit 1
fi

# Check if already registered (defensive)
if yq ".resources[]" "$kustomization_file" 2>/dev/null | grep -qx "$cluster_name"; then
    log "WARNING: '$cluster_name' already in $kustomization_file — skipping"
else
    yq -i ".resources += [\"$cluster_name\"]" "$kustomization_file"
fi

# Step 6: Create cluster directory in gitops-workloads (if path provided)
if [[ -n "$gitops_workloads" ]]; then
    log "Step 6/6: Creating $cluster_name/ in gitops-workloads ..."
    if [[ -d "$gitops_workloads/$cluster_name" ]]; then
        log "WARNING: '$gitops_workloads/$cluster_name' already exists — skipping"
    else
        mkdir -p "$gitops_workloads/$cluster_name"
        cp "$gitops_workloads/template/kustomization.yaml" "$gitops_workloads/$cluster_name/kustomization.yaml"
    fi
else
    log "Step 6/6: Skipping gitops-workloads (no path provided)"
    log "  NOTE: You must manually create '$cluster_name/' in gitops-workloads before the"
    log "        workloads kustomization can reconcile."
fi

echo ""
log "SUCCESS: Workload cluster '$cluster_name' added."
log ""
log "Next steps:"
log "  1. Review the generated files:"
log "       $gitops_system/clusters-config/$cluster_name/"
log "       $gitops_system/clusters/$cluster_name/"
log "       $gitops_system/workloads/$cluster_name/"
if [[ -n "$gitops_workloads" ]]; then
log "       $gitops_workloads/$cluster_name/"
fi
log "  2. Verify the EKS cluster definition:"
log "       $gitops_system/clusters-config/$cluster_name/def/eks-cluster.yaml"
log "     (adjust VPC CIDR, AZs, K8s version, worker count as needed)"
log "  3. Commit and push:"
log "       cd $gitops_system && git add -A && git commit -m 'Add workload cluster $cluster_name' && git push"
if [[ -n "$gitops_workloads" ]]; then
log "       cd $gitops_workloads && git add -A && git commit -m 'Add $cluster_name cluster dir' && git push"
fi
log "  4. Monitor Flux reconciliation:"
log "       kubectl get kustomization -n flux-system | grep $cluster_name"
