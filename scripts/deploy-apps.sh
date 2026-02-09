#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# deploy-apps.sh — Deploy Spring PetClinic Microservices to AKS
# =============================================================================
# Deployment order matters (Spring Cloud dependencies):
#   1. Namespace
#   2. Config Server       — centralized configuration
#   3. Discovery Server    — Eureka service registry
#   4. API Gateway         — Spring Cloud Gateway (edge)
#   5. Backend services    — Customers, Vets, Visits (in parallel)
#   6. Ingress             — Application Routing (managed NGINX)
#   7. KEDA ScaledObjects  — pod autoscaling
#   8. Karpenter NodePools — node autoscaling
#
# Prerequisites:
#   - AKS cluster deployed (deploy-infra.sh completed)
#   - kubectl configured with cluster credentials
#   - .env file with ACR_NAME set
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_ROOT/.env"
K8S_DIR="$PROJECT_ROOT/k8s"

# --- Load config ---
if [[ ! -f "$ENV_FILE" ]]; then
    echo "ERROR: .env file not found. Run deploy-infra.sh first."
    exit 1
fi
source "$ENV_FILE"

# --- Validate ---
if [[ -z "${ACR_NAME:-}" ]]; then
    echo "ERROR: ACR_NAME not set. Run deploy-infra.sh first."
    exit 1
fi

echo ">>> Using ACR: ${ACR_NAME}.azurecr.io"
echo ""

# --- Helper: apply manifest with ACR_NAME substitution ---
apply_manifest() {
    local file="$1"
    echo "    Applying: $(basename "$file")"
    envsubst '${ACR_NAME}' < "$file" | kubectl apply -f -
}

# --- Helper: wait for deployment ready ---
wait_for_deployment() {
    local name="$1"
    local namespace="${2:-petclinic}"
    local timeout="${3:-300s}"
    echo "    Waiting for $name to be ready (timeout: $timeout)..."
    kubectl wait --for=condition=available deployment/"$name" \
        -n "$namespace" --timeout="$timeout"
}

# =============================================================================
# 1. Create Namespace
# =============================================================================
echo ">>> Step 1/8: Creating namespace"
kubectl apply -f "$K8S_DIR/namespace.yaml"
echo ""

# =============================================================================
# 2. Deploy Config Server
# =============================================================================
echo ">>> Step 2/8: Deploying Config Server"
apply_manifest "$K8S_DIR/apps/config-server.yaml"
wait_for_deployment "config-server"
echo ""

# =============================================================================
# 3. Deploy Discovery Server (Eureka)
# =============================================================================
echo ">>> Step 3/8: Deploying Discovery Server (Eureka)"
apply_manifest "$K8S_DIR/apps/discovery-server.yaml"
wait_for_deployment "discovery-server"
echo ""

# =============================================================================
# 4. Deploy API Gateway
# =============================================================================
echo ">>> Step 4/8: Deploying API Gateway"
apply_manifest "$K8S_DIR/apps/api-gateway.yaml"
echo ""

# =============================================================================
# 5. Deploy Backend Services (parallel)
# =============================================================================
echo ">>> Step 5/8: Deploying Backend Services"
apply_manifest "$K8S_DIR/apps/customers-service.yaml"
apply_manifest "$K8S_DIR/apps/vets-service.yaml"
apply_manifest "$K8S_DIR/apps/visits-service.yaml"

echo "    Waiting for all services to be ready..."
wait_for_deployment "api-gateway"
wait_for_deployment "customers-service"
wait_for_deployment "vets-service"
wait_for_deployment "visits-service"
echo ""

# =============================================================================
# 6. Deploy Ingress
# =============================================================================
echo ">>> Step 6/8: Deploying Ingress (Application Routing)"
kubectl apply -f "$K8S_DIR/ingress/api-gateway-ingress.yaml"
echo ""

# =============================================================================
# 7. Apply KEDA ScaledObjects
# =============================================================================
echo ">>> Step 7/8: Applying KEDA ScaledObjects"
kubectl apply -f "$K8S_DIR/scaling/api-gateway-scaledobject.yaml"
kubectl apply -f "$K8S_DIR/scaling/customers-scaledobject.yaml"
kubectl apply -f "$K8S_DIR/scaling/vets-scaledobject.yaml"
kubectl apply -f "$K8S_DIR/scaling/visits-scaledobject.yaml"
echo ""

# =============================================================================
# 8. Apply Karpenter NodePools
# =============================================================================
echo ">>> Step 8/8: Applying Karpenter NodePools"
kubectl apply -f "$K8S_DIR/nodepools/workload-nodepool.yaml"
kubectl apply -f "$K8S_DIR/nodepools/burst-nodepool.yaml"
echo ""

# =============================================================================
# Summary
# =============================================================================
echo "============================================================"
echo "  Application deployment complete!"
echo "============================================================"
echo ""
echo "  Pods:"
kubectl get pods -n petclinic -o wide 2>/dev/null || echo "  (waiting for pods...)"
echo ""
echo "  Services:"
kubectl get svc -n petclinic 2>/dev/null || true
echo ""
echo "  Ingress:"
kubectl get ingress -n petclinic 2>/dev/null || true
echo ""
echo "  KEDA ScaledObjects:"
kubectl get scaledobjects -n petclinic 2>/dev/null || true
echo ""
echo "  Karpenter NodePools:"
kubectl get nodepools.karpenter.sh 2>/dev/null || true
echo ""

# Wait for ingress IP
echo ">>> Waiting for Ingress external IP (may take 1-2 minutes)..."
for i in {1..24}; do
    INGRESS_IP=$(kubectl get ingress api-gateway -n petclinic -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
    if [[ -n "$INGRESS_IP" ]]; then
        echo ""
        echo "============================================================"
        echo "  PetClinic UI: http://$INGRESS_IP"
        echo "============================================================"
        break
    fi
    echo -n "."
    sleep 5
done

if [[ -z "${INGRESS_IP:-}" ]]; then
    echo ""
    echo "  Ingress IP not yet assigned. Check with:"
    echo "    kubectl get ingress api-gateway -n petclinic"
fi
