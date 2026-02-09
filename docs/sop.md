# Standard Operating Procedure — AKS PoC with Karpenter (NAP)

> **This is the step-by-step runbook for the entire PoC lifecycle.**
> Follow sections sequentially. Each section includes commands, explanations, and verification steps.

---

## Table of Contents

1. [Prerequisites & Authentication](#1-prerequisites--authentication)
2. [Deploy Infrastructure](#2-deploy-infrastructure)
3. [Verify Cluster & Add-ons](#3-verify-cluster--add-ons)
4. [Apply Custom Karpenter NodePools](#4-apply-custom-karpenter-nodepools)
5. [Deploy Spring PetClinic Microservices](#5-deploy-spring-petclinic-microservices)
6. [Verify Application](#6-verify-application)
7. [Apply KEDA ScaledObjects](#7-apply-keda-scaledobjects)
8. [Set Up Azure Load Testing](#8-set-up-azure-load-testing)
9. [Run the Demo — Load Test & Observe Scaling](#9-run-the-demo--load-test--observe-scaling)
10. [Teardown](#10-teardown)

---

## 1. Prerequisites & Authentication

### 1.1 Tools

All tools are pre-installed in the DevContainer. If running locally, ensure you have:

| Tool | Minimum Version | Check Command |
|------|----------------|---------------|
| Azure CLI | 2.76.0 | `az version` |
| kubectl | 1.28+ | `kubectl version --client` |
| jq | 1.6+ | `jq --version` |

### 1.2 Open the Repository

```bash
# Option A: Open in DevContainer (recommended)
# VS Code → "Reopen in Container"

# Option B: Use locally (ensure tools are installed)
cd aks-poc-java
```

### 1.3 Configure Environment

```bash
# Copy the template
cp .env.example .env

# Edit .env and fill in your subscription ID
# The only required field is SUBSCRIPTION_ID
# VNet details are pre-filled for the lab environment
```

### 1.4 Authenticate to Azure

```bash
az login --use-device-code
az account set --subscription "$(grep SUBSCRIPTION_ID .env | cut -d= -f2)"
az account show --output table
```

---

## 2. Deploy Infrastructure

### What Gets Created

| Resource | Purpose | Cost |
|----------|---------|------|
| Resource Group | Container for all PoC resources | Free |
| ACR (Basic) | Container image registry | ~$5/mo |
| Delegated Subnet | AKS nodes + API server VNet integration | Free |
| Managed Identity | AKS cluster identity | Free |
| AKS Cluster (Standard tier) | Private K8s cluster with NAP | ~$75/mo + nodes |
| System Node (1× B2s) | System workloads (CoreDNS, etc.) | ~$33/mo |
| Azure Load Testing | Load generation service | ~$1-2/test run |

### 2.1 Run the Deploy Script

```bash
./scripts/deploy-infra.sh
```

The script will:
1. Generate a random 5-character suffix (e.g., `d45j5`)
2. Create all resources with names like `aks-poc-java-d45j5`
3. Import 6 PetClinic Docker images into ACR
4. Create a delegated /24 subnet in your existing VNet
5. Create a user-assigned managed identity with Network Contributor on the VNet
6. Deploy the AKS private cluster with all add-ons (5-10 minutes)
7. Create the Azure Load Testing resource
8. Save all computed names to `.env`

### 2.2 DNS Resolution (Private Cluster)

Since this is a **private cluster**, the API server is only accessible via the VNet. If you're connected via S2S VPN and your DNS forwards to Azure DNS (`168.63.129.16`), kubectl should work automatically.

**If kubectl fails with DNS errors:**

```bash
# Option A: Add hosts file entry
source .env
PRIVATE_FQDN=$(az aks show --name "$CLUSTER_NAME" --resource-group "$RG_NAME" --query privateFqdn -o tsv)
MC_RG=$(az aks show --name "$CLUSTER_NAME" --resource-group "$RG_NAME" --query nodeResourceGroup -o tsv)
PRIVATE_IP=$(az network private-endpoint list --resource-group "$MC_RG" --query "[0].customDnsConfigs[0].ipAddresses[0]" -o tsv)
echo "$PRIVATE_IP $PRIVATE_FQDN" | sudo tee -a /etc/hosts

# Option B: Use az aks command invoke (no VPN/DNS needed)
az aks command invoke --name "$CLUSTER_NAME" --resource-group "$RG_NAME" \
  --command "kubectl get nodes"
```

### 2.3 Verify Infrastructure

```bash
source .env
echo "Cluster: $CLUSTER_NAME"
echo "ACR: $ACR_NAME"
kubectl get nodes
```

Expected: 1 node (system pool, Standard_B2s).

---

## 3. Verify Cluster & Add-ons

### 3.1 What is NAP (Node Autoprovision)?

**NAP is Microsoft's managed implementation of Karpenter for AKS.** If your customer uses Karpenter on AWS EKS, this is the equivalent experience on Azure.

**How it differs from Cluster Autoscaler:**
- **Cluster Autoscaler**: You pre-define node pools with fixed VM sizes. The autoscaler adds/removes nodes within those pools.
- **NAP/Karpenter**: You define NodePools with constraints (VM families, Spot/On-demand, CPU limits). Karpenter watches for pending pods and provisions **right-sized VMs on demand** — picking the cheapest VM that satisfies the pod's resource requests.

### 3.2 Verify NAP

```bash
# List Karpenter NodePools (auto-created by NAP)
kubectl get nodepools.karpenter.sh

# Expected output:
# NAME           NODECLASS   ...
# default        default     ...
# system-surge   default     ...
```

```bash
# Inspect the default NodePool
kubectl describe nodepool default
```

Key fields to note:
- `spec.template.spec.requirements` — which VMs are allowed (D-series, amd64, on-demand)
- `spec.disruption.consolidationPolicy` — how Karpenter manages underutilized nodes
- `status.resources` — current CPU/memory allocated

### 3.3 Verify Add-ons

```bash
# KEDA operator
kubectl get pods -n kube-system -l app=keda-operator

# Cilium (network dataplane)
kubectl get pods -n kube-system -l k8s-app=cilium

# Application Routing (managed NGINX)
kubectl get pods -n app-routing-system

# Azure Policy
kubectl get pods -n kube-system -l app=azure-policy

# Image Cleaner
kubectl get pods -n kube-system -l app=image-cleaner

# Key Vault Secrets Provider
kubectl get pods -n kube-system -l app=secrets-store-csi-driver
```

---

## 4. Apply Custom Karpenter NodePools

### 4.1 Why Multiple NodePools?

Karpenter evaluates **all NodePools** when scheduling pending pods. Each NodePool has a `weight` (higher = preferred). This lets you express policies like:

| Pool | Weight | Strategy |
|------|--------|----------|
| **workload-pool** | 50 (preferred) | D/F v5 VMs, On-demand + Spot. Best for normal workloads. |
| **burst-pool** | 10 (overflow) | D/F/E v5 VMs, **Spot only**. Wider SKU selection, cheapest option for spikes. |

When load spikes create pending pods:
1. Karpenter first tries **workload-pool** (higher weight)
2. If workload-pool's CPU limit (16 cores) is reached, overflows to **burst-pool**
3. Burst-pool uses Spot instances for 60-90% savings

### 4.2 Apply NodePools

```bash
kubectl apply -f k8s/nodepools/

# Verify — should now show 4 pools
kubectl get nodepools.karpenter.sh
```

Expected:
```
NAME             NODECLASS   ...
default          default     ...
system-surge     default     ...
workload-pool    default     ...
burst-pool       default     ...
```

Verify weight in each node pool. With bigger weight, i.e. 50, that nodepool will be used first. 

```bash
kubectl get nodepools.karpenter.sh -o custom-columns='NAME:.metadata.name,WEIGHT:.spec.weight,CPU-LIMIT:.spec.limits.cpu,MEMORY-LIMIT:.spec.limits.memory,NODECLASS:.spec.template.spec.nodeClassRef.name,READY:.status.conditions[?(@.type=="Ready")].status'
```

### 4.3 Clarification of the NodePools

`default` — NAP's catch-all pool. If no other pool can satisfy a pending pod (e.g., your custom pools hit their CPU limits), this pool handles it. No weight = lowest priority (treated as 0). No CPU/memory limits = uncapped fallback.

`system-surge` — handles system workloads (CoreDNS, kube-proxy, Cilium, KEDA, etc.). Uses a dedicated system-surge NodeClass with system-specific taints/tolerations so app pods don't land on system nodes.

`default` and `system-surge` are managed by AKS/NAP automatically.

Here's how logic of choosing NodePool will apply:

```text
workload-pool (weight 50) → first choice for app pods
burst-pool    (weight 10) → overflow, Spot-only
default       (weight 0)  → catch-all fallback if both custom pools are full
system-surge  (weight 0)  → system components only (tainted)
```

---

## 5. Deploy Spring PetClinic Microservices

### 5.1 About the Application

**Spring PetClinic Microservices** is a well-known demo application from the Spring community. It consists of 7 services:

| Service | Port | Role |
|---------|------|------|
| Config Server | 8888 | Centralized configuration (Spring Cloud Config) |
| Discovery Server | 8761 | Service registry (Eureka) |
| API Gateway | 8080 | Edge router (Spring Cloud Gateway) — **has the web UI** |
| Customers Service | 8081 | Pet owner management |
| Vets Service | 8083 | Veterinarian data |
| Visits Service | 8082 | Visit scheduling |

### 5.2 Why Deployment Order Matters

Spring Cloud services have **startup dependencies**:

```
Config Server ──► Discovery Server ──► API Gateway ──► Backend Services
     (must be Ready)     (must be Ready)     (routes to backends)
```

- **Config Server** provides externalized config to ALL other services
- **Discovery Server (Eureka)** provides service registration — other services register on startup
- If Config/Discovery are not Ready, dependent services will fail health checks and restart

### 5.3 Deploy

```bash
./scripts/deploy-apps.sh
```

The script:
1. Creates the `petclinic` namespace
2. Deploys Config Server → waits for Ready
3. Deploys Discovery Server → waits for Ready
4. Deploys API Gateway + backend services
5. Creates Ingress (managed NGINX)
6. Applies KEDA ScaledObjects
7. Applies custom Karpenter NodePools
8. Waits for Ingress IP and prints the URL

**Manual alternative** — apply each file individually:
```bash
source .env
kubectl apply -f k8s/namespace.yaml
export ACR_NAME
envsubst '${ACR_NAME}' < k8s/apps/config-server.yaml | kubectl apply -f -
kubectl wait --for=condition=available deployment/config-server -n petclinic --timeout=300s
# ... repeat for each service in order
```

---

## 6. Verify Application

### 6.1 Check Pods

```bash
kubectl get pods -n petclinic -o wide
```

All 6 pods should be `Running` with `1/1` Ready.

### 6.2 Check Ingress

```bash
kubectl get ingress -n petclinic
```

Note the `ADDRESS` column — this is the public IP for the application.

### 6.3 Open in Browser

```bash
# Get the external IP
INGRESS_IP=$(kubectl get ingress api-gateway -n petclinic -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "Open: http://$INGRESS_IP"
```

You should see the PetClinic UI:
- **Home** page with the Spring PetClinic logo
- **Owners** → Find Owners → shows pet owner list
- **Veterinarians** → shows vet list with specialties

### 6.4 Check Nodes

```bash
kubectl get nodes -o wide
```

You should see the system node (B2s) plus 1-2 NAP-provisioned nodes (likely Standard_D2as_v5 or similar) for the application pods.

---

## 7. Apply KEDA ScaledObjects

### 7.1 How KEDA, HPA, and Karpenter Work Together

This PoC demonstrates a **three-layer autoscaling architecture**:

```
Layer 1: KEDA (Event-driven pod scaling)
├── Monitors triggers: CPU utilization, Prometheus HTTP metrics
├── Creates and manages HPA objects internally
├── Unique capability: scale to zero (HPA alone cannot do this)
│
Layer 2: HPA (Managed by KEDA)
├── Handles the actual 1→N replica scaling
├── Picks the highest replica count across all triggers
│
Layer 3: Karpenter / NAP (Node scaling)
├── Detects pods in Pending state (no node capacity)
├── Evaluates NodePools by weight (higher = preferred)
├── Selects cheapest right-sized VM from allowed families
├── Provisions new node (~60-90 seconds)
└── Consolidates underutilized nodes when demand drops
```

**Critical rule**: Never create a standalone HPA for a deployment that has a KEDA ScaledObject. They will conflict and cause scaling thrashing. Define ALL triggers (CPU, memory, Prometheus) inside the KEDA ScaledObject.

### 7.2 Our KEDA Configuration

| Service | Triggers | Min | Max | Why |
|---------|----------|-----|-----|-----|
| api-gateway | CPU 50% | 1 | 10 | Gateway handles all incoming traffic — scales first |
| customers-service | CPU 50% | 1 | 10 | Backend service |
| vets-service | CPU 50% | 1 | 10 | Backend service |
| visits-service | CPU 50% + Prometheus* | 1 | 10 | Demonstrates event-driven scaling |

*The Prometheus trigger on visits-service is provided as a template. It requires additional setup (Managed Prometheus + Workload Identity for KEDA). The CPU trigger works out of the box.

### 7.3 Verify ScaledObjects

```bash
# List ScaledObjects
kubectl get scaledobjects -n petclinic

# List HPAs created by KEDA
kubectl get hpa -n petclinic

# Detailed view of a ScaledObject
kubectl describe scaledobject api-gateway-scaledobject -n petclinic
```

The `STATUS` column should show `True` (active). The `HPA` column shows the auto-created HPA name.

---

## 8. Set Up Azure Load Testing

### 8.1 What is Azure Load Testing?

Azure Load Testing is a **fully managed load-testing service**. You define the target URLs, concurrency, and duration — Azure handles the rest. Results are displayed in a live dashboard in the Azure Portal.

For this PoC, we use **URL-based testing** (no scripts needed).

### 8.2 Create a Test

1. Open **Azure Portal** → search for **Azure Load Testing**
2. Click on your resource: `aks-poc-lt-<suffix>`
3. Click **Create Test** → **URL-based test**
4. Get the Ingress IP:
   ```bash
   kubectl get ingress api-gateway -n petclinic -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
   ```
5. Configure the test:

   | Setting | Value |
   |---------|-------|
   | **URL 1** | `http://<INGRESS-IP>/api/vet/vets` |
   | **URL 2** | `http://<INGRESS-IP>/api/customer/owners` |
   | **Concurrent users** | 250 |
   | **Test duration** | 5 minutes |
   | **Ramp-up time** | 30 seconds |

6. (Optional) Under **Monitoring**, add server-side metrics:
   - Click **Add/Modify** → select your AKS cluster
   - Add metrics: `CPU Usage`, `Memory Usage`, `Pod Count`

### 8.3 Cost

Azure Load Testing charges per **Virtual User Hour (VUH)**:
- 250 users × 5 minutes = ~20.8 VUH ≈ **$3-4 per test run**
- Very affordable for PoC demos

---

## 9. Run the Demo — Load Test & Observe Scaling

### 9.1 Set Up Monitoring Views

Open **3 views** side-by-side for the demo:

**View 1 — Azure Portal**: Azure Load Testing → your test → live dashboard

**View 2 — Terminal (pod watcher)**:
```bash
kubectl get pods -n petclinic -w
```

**View 3 — Terminal (node watcher)**:
```bash
kubectl get nodes -w
```

### 9.2 Start the Load Test

Click **Run** in Azure Load Testing. Then narrate the scaling chain:

| Time | What Happens | Where to Watch |
|------|-------------|----------------|
| ~0s | Load test begins, 250 concurrent users hit the API Gateway | Azure Portal dashboard |
| ~30s | CPU exceeds 50% → KEDA scales pods from 1 → 2 → 3 | Terminal: pods appearing |
| ~60s | New pods can't fit on existing nodes → Pending state | Terminal: pods show `Pending` |
| ~90s | Karpenter selects cheapest VM from workload-pool | — |
| ~120s | New node becomes Ready → pending pods scheduled | Terminal: new node appears |
| ~150s | Response times stabilize as capacity catches up | Azure Portal: latency graph |

### 9.3 Useful Commands During Demo

```bash
# Show KEDA ScaledObjects and their current state
kubectl get scaledobjects -n petclinic

# Show HPAs managed by KEDA (current/target replicas)
kubectl get hpa -n petclinic

# Show Karpenter NodePools and allocated resources
kubectl get nodepools.karpenter.sh

# Show node details (VM SKU, zone, capacity type)
kubectl get nodes -o custom-columns='NAME:.metadata.name,SKU:.metadata.labels.node\.kubernetes\.io/instance-type,ZONE:.metadata.labels.topology\.kubernetes\.io/zone,TYPE:.metadata.labels.karpenter\.sh/capacity-type,AGE:.metadata.creationTimestamp'

# Show resource usage
kubectl top pods -n petclinic
kubectl top nodes
```

### 9.4 After the Load Test

Continue watching for 5-10 minutes after the test ends:

| Time After Test | What Happens |
|----------------|-------------|
| ~1-2 min | CPU drops below threshold → KEDA scales pods back down |
| ~3-5 min | Nodes become underutilized → Karpenter consolidation begins |
| ~5-10 min | Karpenter drains pods, cordons node, terminates VM |
| Final state | Back to minimal nodes (system + 1-2 app nodes) |

---

## 10. Teardown

### 10.1 Run the Teardown Script

```bash
./scripts/teardown.sh
```

The script will:
1. Delete the `petclinic` namespace
2. Delete custom Karpenter NodePools
3. Delete the entire resource group (AKS, ACR, identity, load test) — runs async
4. Remove the AKS subnet from the existing VNet
5. Remove the Network Contributor role assignment
6. Clean up local kubeconfig context and hosts file entries
7. Remove generated values from `.env`

### 10.2 What is Preserved

- **VNet `infra-vnet-01`** in `infra-network-rg` — **NOT deleted**
- **S2S VPN configuration** — untouched
- **`.env.example`** — template stays in the repo
- **All code and manifests** — ready for the next deployment

### 10.3 Verify Cleanup

```bash
source .env
# Should return error "ResourceGroupNotFound"
az group show --name "$RG_NAME" 2>/dev/null || echo "Resource group deleted ✓"

# Should not list the AKS subnet
az network vnet subnet list --resource-group infra-network-rg --vnet-name infra-vnet-01 \
  --query "[].name" --output tsv
```

### 10.4 Re-deploy

To rebuild everything from scratch:
```bash
# Ensure .env has only the base values (generated values were cleaned up)
./scripts/deploy-infra.sh   # Creates new resources with a new random suffix
./scripts/deploy-apps.sh    # Deploys app to the new cluster
```
