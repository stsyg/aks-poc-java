#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# deploy-infra.sh — Deploy all Azure infrastructure for the AKS PoC
# =============================================================================
# This script creates:
#   1. Resource Group
#   2. Azure Container Registry (Basic)
#   3. Import PetClinic images into ACR
#   4. Delegated subnet in existing VNet
#   5. User-assigned Managed Identity + role assignment
#   6. AKS Private Cluster with NAP (Karpenter) and all add-ons
#   7. Azure Load Testing resource
#
# Prerequisites:
#   - az CLI >= 2.76.0 logged in (az login)
#   - .env file with SUBSCRIPTION_ID and VNet details
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_ROOT/.env"

# --- Load base config ---
if [[ ! -f "$ENV_FILE" ]]; then
    echo "ERROR: .env file not found. Copy .env.example to .env and fill in your values."
    exit 1
fi
source "$ENV_FILE"

# --- Validate required variables ---
for var in SUBSCRIPTION_ID LOCATION VNET_RG VNET_NAME NODE_SUBNET_NAME; do
    if [[ -z "${!var:-}" ]]; then
        echo "ERROR: $var is not set in .env"
        exit 1
    fi
done

# --- Generate random suffix (only if not already set) ---
if [[ -z "${RANDOM_SUFFIX:-}" ]]; then
    RANDOM_SUFFIX=$(head -c 256 /dev/urandom | tr -dc 'a-z0-9' | head -c 5 || true)
    echo "RANDOM_SUFFIX=$RANDOM_SUFFIX" >> "$ENV_FILE"
    echo ">>> Generated random suffix: $RANDOM_SUFFIX (saved to .env)"
else
    echo ">>> Using existing suffix: $RANDOM_SUFFIX"
fi

# --- Compute resource names ---
RG_NAME="aks-poc-java-${RANDOM_SUFFIX}-rg"
CLUSTER_NAME="aks-poc-java-${RANDOM_SUFFIX}"
ACR_NAME="akspocjava${RANDOM_SUFFIX}"
IDENTITY_NAME="aks-poc-java-id-${RANDOM_SUFFIX}"
LOAD_TEST_NAME="aks-poc-lt-${RANDOM_SUFFIX}"
NAT_GW_NAME="aks-poc-natgw-${RANDOM_SUFFIX}"
NAT_GW_PIP_NAME="aks-poc-natgw-pip-${RANDOM_SUFFIX}"
AKS_SUBNET_NAME="aks-poc-${RANDOM_SUFFIX}"
AKS_SUBNET_PREFIX="192.167.224.0/24"

TAGS="environment=Lab designation=Poc provisioner=Manual"

echo ">>> Resource names:"
echo "    Resource Group:    $RG_NAME"
echo "    AKS Cluster:       $CLUSTER_NAME"
echo "    ACR:               $ACR_NAME"
echo "    Managed Identity:  $IDENTITY_NAME"
echo "    Load Test:         $LOAD_TEST_NAME"
echo "    AKS Subnet:        $AKS_SUBNET_NAME ($AKS_SUBNET_PREFIX)"
echo ""

# --- Set subscription ---
echo ">>> Setting subscription to $SUBSCRIPTION_ID"
az account set --subscription "$SUBSCRIPTION_ID"

# =============================================================================
# 1. Create Resource Group
# =============================================================================
echo ">>> Creating resource group: $RG_NAME"
az group create \
    --name "$RG_NAME" \
    --location "$LOCATION" \
    --tags $TAGS \
    --output none

# =============================================================================
# 2. Create Azure Container Registry
# =============================================================================
echo ">>> Creating ACR: $ACR_NAME"
az acr create \
    --name "$ACR_NAME" \
    --resource-group "$RG_NAME" \
    --sku Basic \
    --tags $TAGS \
    --output none

# =============================================================================
# 3. Import PetClinic images into ACR
# =============================================================================
echo ">>> Importing PetClinic images into ACR (this may take a few minutes)..."
SERVICES=(
    "config-server"
    "discovery-server"
    "api-gateway"
    "customers-service"
    "vets-service"
    "visits-service"
)

for svc in "${SERVICES[@]}"; do
    echo "    Importing spring-petclinic-${svc}..."
    az acr import \
        --name "$ACR_NAME" \
        --source "docker.io/springcommunity/spring-petclinic-${svc}:latest" \
        --image "spring-petclinic-${svc}:latest" \
        --no-wait \
        --output none || echo "    WARNING: Import may already exist for ${svc}"
done
echo ">>> Waiting for image imports to complete..."
sleep 30

# =============================================================================
# 4. Create NAT Gateway, Public IP, and subnet in existing VNet
# =============================================================================
echo ">>> Checking for available subnet range in $VNET_NAME..."
echo "    Existing subnets:"
az network vnet subnet list \
    --resource-group "$VNET_RG" \
    --vnet-name "$VNET_NAME" \
    --query "[].{Name:name, Prefix:addressPrefix}" \
    --output table

echo ">>> Creating public IP for NAT gateway: $NAT_GW_PIP_NAME"
az network public-ip create \
    --resource-group "$RG_NAME" \
    --name "$NAT_GW_PIP_NAME" \
    --location "$LOCATION" \
    --sku Standard \
    --tags $TAGS \
    --output none

echo ">>> Creating NAT gateway: $NAT_GW_NAME"
az network nat gateway create \
    --resource-group "$RG_NAME" \
    --name "$NAT_GW_NAME" \
    --location "$LOCATION" \
    --public-ip-addresses "$NAT_GW_PIP_NAME" \
    --tags $TAGS \
    --output none

NAT_GW_ID=$(az network nat gateway show \
    --resource-group "$RG_NAME" \
    --name "$NAT_GW_NAME" \
    --query id --output tsv)

echo ">>> Creating subnet: $AKS_SUBNET_NAME ($AKS_SUBNET_PREFIX)"
echo "    NOTE: If this prefix conflicts with an existing subnet, edit AKS_SUBNET_PREFIX in this script."
az network vnet subnet create \
    --resource-group "$VNET_RG" \
    --vnet-name "$VNET_NAME" \
    --name "$AKS_SUBNET_NAME" \
    --address-prefixes "$AKS_SUBNET_PREFIX" \
    --nat-gateway "$NAT_GW_ID" \
    --output none

SUBNET_ID=$(az network vnet subnet show \
    --resource-group "$VNET_RG" \
    --vnet-name "$VNET_NAME" \
    --name "$AKS_SUBNET_NAME" \
    --query id --output tsv)

# =============================================================================
# 5. Create Managed Identity + Role Assignment
# =============================================================================
echo ">>> Creating managed identity: $IDENTITY_NAME"
az identity create \
    --name "$IDENTITY_NAME" \
    --resource-group "$RG_NAME" \
    --location "$LOCATION" \
    --tags $TAGS \
    --output none

IDENTITY_ID=$(az identity show \
    --name "$IDENTITY_NAME" \
    --resource-group "$RG_NAME" \
    --query id --output tsv)

IDENTITY_PRINCIPAL_ID=$(az identity show \
    --name "$IDENTITY_NAME" \
    --resource-group "$RG_NAME" \
    --query principalId --output tsv)

echo ">>> Assigning Network Contributor on VNet: $VNET_NAME"
VNET_ID="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$VNET_RG/providers/Microsoft.Network/virtualNetworks/$VNET_NAME"
az role assignment create \
    --scope "$VNET_ID" \
    --role "Network Contributor" \
    --assignee-object-id "$IDENTITY_PRINCIPAL_ID" \
    --assignee-principal-type ServicePrincipal \
    --output none

# Wait for role assignment propagation
echo ">>> Waiting for role assignment to propagate (15s)..."
sleep 15

# =============================================================================
# 6. Create AKS Private Cluster with NAP and all add-ons
# =============================================================================
echo ">>> Creating AKS private cluster: $CLUSTER_NAME"
echo "    This will take 5-10 minutes..."
az aks create \
    --name "$CLUSTER_NAME" \
    --resource-group "$RG_NAME" \
    --location "$LOCATION" \
    --tier standard \
    --node-provisioning-mode Auto \
    --network-plugin azure \
    --network-plugin-mode overlay \
    --network-dataplane cilium \
    --outbound-type userAssignedNATGateway \
    --enable-private-cluster \
    --private-dns-zone none \
    --assign-identity "$IDENTITY_ID" \
    --vnet-subnet-id "$SUBNET_ID" \
    --attach-acr "$ACR_NAME" \
    --node-count 1 \
    --node-vm-size Standard_D2s_v5 \
    --enable-oidc-issuer \
    --enable-workload-identity \
    --enable-keda \
    --enable-app-routing \
    --enable-image-cleaner \
    --enable-addons monitoring,azure-policy,azure-keyvault-secrets-provider \
    --generate-ssh-keys \
    --tags $TAGS \
    --output none

echo ">>> Getting cluster credentials..."
az aks get-credentials \
    --name "$CLUSTER_NAME" \
    --resource-group "$RG_NAME" \
    --overwrite-existing

# =============================================================================
# 7. Create Azure Load Testing resource
# =============================================================================
echo ">>> Creating Azure Load Testing: $LOAD_TEST_NAME"
az load create \
    --name "$LOAD_TEST_NAME" \
    --resource-group "$RG_NAME" \
    --location "$LOCATION" \
    --tags $TAGS \
    --output none || echo "    WARNING: az load extension may need to be installed: az extension add --name load"

# =============================================================================
# 8. Get private cluster connection info
# =============================================================================
PRIVATE_FQDN=$(az aks show \
    --name "$CLUSTER_NAME" \
    --resource-group "$RG_NAME" \
    --query privateFqdn --output tsv 2>/dev/null || echo "")

# =============================================================================
# Save all computed values to .env
# =============================================================================
echo ">>> Saving computed values to .env"
cat >> "$ENV_FILE" << EOF

# === Generated by deploy-infra.sh ($(date -Iseconds)) ===
RANDOM_SUFFIX=$RANDOM_SUFFIX
RG_NAME=$RG_NAME
CLUSTER_NAME=$CLUSTER_NAME
ACR_NAME=$ACR_NAME
IDENTITY_NAME=$IDENTITY_NAME
LOAD_TEST_NAME=$LOAD_TEST_NAME
AKS_SUBNET_NAME=$AKS_SUBNET_NAME
IDENTITY_ID=$IDENTITY_ID
IDENTITY_PRINCIPAL_ID=$IDENTITY_PRINCIPAL_ID
SUBNET_ID=$SUBNET_ID
PRIVATE_FQDN=$PRIVATE_FQDN
EOF

echo ""
echo "============================================================"
echo "  Infrastructure deployment complete!"
echo "============================================================"
echo "  Resource Group:   $RG_NAME"
echo "  AKS Cluster:      $CLUSTER_NAME (private)"
echo "  ACR:              $ACR_NAME"
echo "  Load Testing:     $LOAD_TEST_NAME"
echo "  Private FQDN:     $PRIVATE_FQDN"
echo ""
echo "  Next steps:"
echo "    1. Verify kubectl access:"
echo "       kubectl get nodes"
echo ""
echo "    2. If DNS fails (private cluster), add hosts entry:"
echo "       See docs/sop.md Section 2 — DNS Resolution"
echo ""
echo "    3. Deploy the application:"
echo "       ./scripts/deploy-apps.sh"
echo "============================================================"
