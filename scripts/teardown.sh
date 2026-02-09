#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# teardown.sh — Destroy all PoC resources
# =============================================================================
# This script removes:
#   1. petclinic namespace (all app resources)
#   2. Custom Karpenter NodePools
#   3. Resource group (AKS, ACR, identity, load test)
#   4. AKS subnet from existing VNet
#   5. Role assignment on VNet
#   6. Local kubeconfig context
#   7. Hosts file entry (if added)
#
# IMPORTANT: The existing VNet (infra-vnet-01) is NOT deleted.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_ROOT/.env"

# --- Load config ---
if [[ ! -f "$ENV_FILE" ]]; then
    echo "ERROR: .env file not found. Nothing to tear down."
    exit 1
fi
source "$ENV_FILE"

# --- Validate ---
for var in RG_NAME CLUSTER_NAME VNET_RG VNET_NAME AKS_SUBNET_NAME SUBSCRIPTION_ID; do
    if [[ -z "${!var:-}" ]]; then
        echo "ERROR: $var is not set in .env. Was deploy-infra.sh run?"
        exit 1
    fi
done

echo "============================================================"
echo "  TEARDOWN — Destroying all PoC resources"
echo "============================================================"
echo "  Resource Group:   $RG_NAME"
echo "  AKS Cluster:      $CLUSTER_NAME"
echo "  AKS Subnet:       $AKS_SUBNET_NAME"
echo "  VNet (preserved): $VNET_NAME"
echo ""
read -p "  Are you sure? Type 'yes' to confirm: " CONFIRM
if [[ "$CONFIRM" != "yes" ]]; then
    echo "  Cancelled."
    exit 0
fi
echo ""

# =============================================================================
# 1. Delete K8s resources (if kubectl is accessible)
# =============================================================================
echo ">>> Deleting Kubernetes resources..."
kubectl delete namespace petclinic --ignore-not-found --timeout=60s 2>/dev/null || \
    echo "    Skipped (kubectl not accessible — cluster may already be deleting)"

kubectl delete nodepools.karpenter.sh workload-pool burst-pool --ignore-not-found 2>/dev/null || \
    echo "    Skipped NodePool deletion"

# =============================================================================
# 2. Delete Resource Group (AKS, ACR, identity, load test — everything)
# =============================================================================
echo ">>> Deleting resource group: $RG_NAME (this runs in background)..."
az group delete \
    --name "$RG_NAME" \
    --yes \
    --no-wait \
    --output none 2>/dev/null || echo "    Resource group may already be deleted"

# =============================================================================
# 3. Delete AKS subnet from existing VNet
# =============================================================================
echo ">>> Deleting AKS subnet: $AKS_SUBNET_NAME from $VNET_NAME"
echo "    Waiting for AKS resources to release subnet (may take a few minutes)..."
for i in {1..30}; do
    az network vnet subnet delete \
        --resource-group "$VNET_RG" \
        --vnet-name "$VNET_NAME" \
        --name "$AKS_SUBNET_NAME" \
        --output none 2>/dev/null && break
    echo -n "."
    sleep 10
done
echo ""
echo "    Subnet deleted (or was already removed)"

# =============================================================================
# 4. Remove role assignment
# =============================================================================
echo ">>> Removing role assignment on VNet..."
if [[ -n "${IDENTITY_PRINCIPAL_ID:-}" ]]; then
    VNET_ID="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$VNET_RG/providers/Microsoft.Network/virtualNetworks/$VNET_NAME"
    az role assignment delete \
        --assignee "$IDENTITY_PRINCIPAL_ID" \
        --role "Network Contributor" \
        --scope "$VNET_ID" \
        --output none 2>/dev/null || echo "    Role assignment may already be deleted"
else
    echo "    Skipped (IDENTITY_PRINCIPAL_ID not set)"
fi

# =============================================================================
# 5. Clean up local config
# =============================================================================
echo ">>> Cleaning up local kubeconfig context..."
kubectl config delete-context "$CLUSTER_NAME" 2>/dev/null || true
kubectl config delete-cluster "$CLUSTER_NAME" 2>/dev/null || true
kubectl config delete-user "clusterUser_${RG_NAME}_${CLUSTER_NAME}" 2>/dev/null || true

# Remove hosts file entry if present
if [[ -n "${PRIVATE_FQDN:-}" ]]; then
    echo ">>> Removing hosts file entry for $PRIVATE_FQDN..."
    sudo sed -i "/$PRIVATE_FQDN/d" /etc/hosts 2>/dev/null || true
fi

# =============================================================================
# 6. Clean up .env (remove generated values)
# =============================================================================
echo ">>> Cleaning generated values from .env..."
# Keep only lines before the generated section marker
if grep -q "Generated by deploy-infra.sh" "$ENV_FILE"; then
    sed -i '/# === Generated by deploy-infra.sh/,$d' "$ENV_FILE"
    echo "    Removed generated values from .env"
fi

echo ""
echo "============================================================"
echo "  Teardown complete!"
echo "============================================================"
echo "  - Resource group '$RG_NAME' is being deleted (background)"
echo "  - AKS subnet removed from $VNET_NAME"
echo "  - VNet $VNET_NAME in $VNET_RG is PRESERVED"
echo ""
echo "  Verify deletion:"
echo "    az group show --name $RG_NAME 2>/dev/null || echo 'Deleted'"
echo "============================================================"
