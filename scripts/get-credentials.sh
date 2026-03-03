#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# get-credentials.sh — Fetch AKS kubeconfig using REST API
# ============================================================================
# Works around Azure CLI API-version mismatches by calling the
# ContainerService RP directly via `az rest`.
#
# Usage:
#   ./scripts/get-credentials.sh          # uses .env values
#   source .env && ./scripts/get-credentials.sh
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../.env"

# --- Source .env -----------------------------------------------------------
if [[ ! -f "$ENV_FILE" ]]; then
    echo ">>> ERROR: .env file not found. Run deploy-infra.sh first."
    exit 1
fi
source "$ENV_FILE"

# --- Validate required variables ------------------------------------------
for var in SUBSCRIPTION_ID RG_NAME CLUSTER_NAME; do
    if [[ -z "${!var:-}" ]]; then
        echo ">>> ERROR: $var is not set in .env. Run deploy-infra.sh first."
        exit 1
    fi
done

# --- Check Azure login ----------------------------------------------------
if ! az account show --output none 2>/dev/null; then
    echo ">>> Not logged in to Azure. Run:  az login --use-device-code"
    exit 1
fi

# --- Fetch kubeconfig via REST API ----------------------------------------
API_VERSION="2024-09-01"
URL="https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RG_NAME}/providers/Microsoft.ContainerService/managedClusters/${CLUSTER_NAME}/listClusterUserCredential?api-version=${API_VERSION}"

echo ">>> Fetching kubeconfig for cluster ${CLUSTER_NAME}..."
mkdir -p ~/.kube

az rest --method post --url "$URL" \
    --query 'kubeconfigs[0].value' -o tsv \
    | base64 -d > ~/.kube/config

chmod 600 ~/.kube/config
echo ">>> kubeconfig written to ~/.kube/config"

# --- Quick connectivity check ---------------------------------------------
if kubectl cluster-info --request-timeout=5s &>/dev/null; then
    echo ">>> kubectl connected — cluster is reachable."
else
    echo ">>> WARNING: kubeconfig saved but cluster is not reachable."
    echo "    This is expected for a private cluster without VPN connectivity."
    echo "    Use:  az aks command invoke --resource-group $RG_NAME --name $CLUSTER_NAME --command 'kubectl get nodes'"
fi
