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

Expected:
```
NAME            WEIGHT   CPU-LIMIT   MEMORY-LIMIT   NODECLASS      READY
burst-pool      10       16          64Gi           default        True
default         <none>   <none>      <none>         default        True
system-surge    <none>   <none>      <none>         system-surge   True
workload-pool   50       16          64Gi           default        True
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

> **This section is a step-by-step presenter script.**
> Read each step aloud, run the commands, and narrate what the audience should observe.
> Steps marked 🖥️ are terminal commands. Steps marked 🌐 are Azure Portal actions.

---

### 9.1 Set the Scene — What Are We Looking At?

**Say to the audience:**

> *"We have a realistic Java microservices application — Spring PetClinic — running on a private AKS cluster. It has 6 services: a Config Server for centralized configuration, a Discovery Server (Eureka) for service registration, an API Gateway that serves the web UI, and three backend services — Customers, Vets, and Visits. All container images are pulled from our private Azure Container Registry — nothing comes from the public internet."*

🖥️ **Show the running application:**

```bash
# Show all pods — 6 services, all Running
kubectl get pods -n petclinic -o wide
```

> *"Here are our 6 microservices, each running as a single replica. They're all healthy and registered with Eureka."*

🖥️ **Show the Ingress (public entry point):**

```bash
kubectl get ingress -n petclinic
```

```bash
# Get the URL
INGRESS_IP=$(kubectl get ingress api-gateway -n petclinic -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "App URL: http://$INGRESS_IP"
```

🌐 **Open the app in the browser** → click **Find Owners** → show data. Then click **Veterinarians** → show the list.

> *"This is a real Spring Boot 3 application — not a hello-world. When you clicked 'Find Owners' just now, here's what actually happened: the browser hit the API Gateway, the gateway asked Eureka — our service discovery server — 'where is customers-service right now?', Eureka replied with the pod's current IP address, and the gateway forwarded the request there. The service queried its database and returned the data. That's four hops across three microservices."*

> *"Eureka is like a phonebook for microservices. Every service registers itself on startup — 'I'm customers-service, I'm at IP 10.244.1.5, port 8081.' When pods scale up or restart and get new IPs, Eureka keeps the registry up to date. The gateway never hardcodes addresses — it always asks Eureka."*

> *"The gateway also has circuit breakers — powered by Resilience4j. If a backend service goes down or gets too slow, the circuit breaker trips, like an electrical breaker in your house. Instead of piling up requests and cascading the failure, the gateway immediately returns a fallback response. Once the backend recovers, the circuit closes and normal traffic resumes. It prevents one struggling service from taking down the whole application."*

---

### 9.2 Show the Current Cluster State — "Calm Before the Storm"

🖥️ **Show nodes:**

```bash
kubectl get nodes -o custom-columns=\
'NAME:.metadata.name,SKU:.metadata.labels.node\.kubernetes\.io/instance-type,ZONE:.metadata.labels.topology\.kubernetes\.io/zone,CAPACITY-TYPE:.metadata.labels.karpenter\.sh/capacity-type,AGE:.metadata.creationTimestamp'
```

> *"Let me walk you through what's on the screen. There are three types of nodes:"*

> *"**nodepool1** (VMSS) — this is the original system node pool we created with the cluster. It's a Standard_D2s_v5, part of a traditional VM Scale Set. Notice the CAPACITY-TYPE is `<none>` — that's because this node wasn't created by Karpenter, it's a classic AKS node pool. It runs core system workloads."*

> *"**system-surge** nodes — these were created by Karpenter automatically. The `system-surge` NodePool is managed by NAP and handles overflow for system components like CoreDNS, Cilium, KEDA operator, Azure Policy, etc. Notice they're Standard_D2als_v6 — the 'a' means AMD, the 'l' means low memory — cheapest option for system pods. All on-demand, spread across availability zones."*

> *"**workload-pool** nodes — this is where our PetClinic application runs. Karpenter provisioned these from the workload-pool we defined. Notice the CAPACITY-TYPE is `spot` — these are Spot VMs, 60-90% cheaper than on-demand. Karpenter picked Standard_D2as_v5 because it's the cheapest VM that satisfies our pods' resource requests (250m CPU, 512Mi memory per pod). We didn't tell it to use this exact SKU — Karpenter figured it out."*

🖥️ **Show current resource usage:**

```bash
kubectl top nodes
```

```bash
kubectl top pods -n petclinic --sort-by=cpu
```

**What does `m` mean in CPU?**

`m` stands for millicores (milli-CPU). It's Kubernetes' way of expressing fractions of a CPU core:

Value	Meaning
1000m	1 full CPU core
500m	0.5 cores (half a core)
250m	0.25 cores (quarter of a core)
1210m	1.21 cores

> *"CPU usage is low — each service is barely using any CPU. This is our baseline. Let's see what happens when we put this under load."*

---

### 9.3 Explain KEDA — "Here's How Pod Scaling Is Configured"

> *"Before we stress-test, let me show you how autoscaling is set up. We use a two-layer approach: KEDA for pod scaling, and Karpenter (NAP) for node scaling."*

> *"First, KEDA — it stands for Kubernetes Event-Driven Autoscaling. It's an open-source project, and on AKS it's available as a managed add-on. The key thing about KEDA: it extends the built-in Kubernetes HPA (Horizontal Pod Autoscaler). You don't create HPAs yourself — instead you create a ScaledObject, and KEDA manages the HPA for you internally. Never create a standalone HPA alongside a KEDA ScaledObject — they will conflict."*

🖥️ **Show the KEDA ScaledObjects:**

```bash
kubectl get scaledobjects -n petclinic
```

> *"We have 4 ScaledObjects — one for each service that handles user traffic. The Config Server and Discovery Server are infrastructure services that don't need to scale."*

🖥️ **Look at one ScaledObject in detail:**

```bash
kubectl describe scaledobject api-gateway-scaledobject -n petclinic
```

> *"Here's how KEDA is configured for the API Gateway: it watches CPU utilization with a threshold of 50%. When CPU goes above 50%, KEDA tells the HPA to add more replicas — up to a maximum of 10. The polling interval is 15 seconds, so KEDA checks every 15 seconds. The cooldown period is 60 seconds — meaning it waits at least a minute before scaling back down to avoid flapping (scale up and down too quickly)."*

🖥️ **Show the HPAs that KEDA created:**

```bash
kubectl get hpa -n petclinic
```

> *"See these HPAs? We didn't create them. KEDA created and manages them automatically. The TARGETS column shows current CPU vs the 50% threshold. Right now it's well below — the app is idle."*

---

### 9.4 Explain Karpenter (NAP) — "Here's How Node Scaling Is Configured"

> *"Now the second layer — Karpenter. If you've used Karpenter on AWS EKS, this is the same thing. On AKS, Microsoft calls it NAP — Node Autoprovision. Same Karpenter engine, managed by Azure."*

> *"Here's the difference between KEDA and Karpenter in plain English: **KEDA decides HOW MANY pods you need. Karpenter decides WHERE to run them.** When KEDA creates new pods and they can't fit on existing nodes, the pods go to Pending state. Karpenter watches for Pending pods and automatically provisions a new VM — picking the cheapest one that satisfies the pod's CPU and memory requirements."*

🖥️ **Show the Karpenter NodePools with weight and limits:**

```bash
kubectl get nodepools.karpenter.sh -o custom-columns=\
'NAME:.metadata.name,WEIGHT:.spec.weight,CPU-LIMIT:.spec.limits.cpu,MEMORY-LIMIT:.spec.limits.memory,NODECLASS:.spec.template.spec.nodeClassRef.name'
```

> *"We have 4 NodePools. The two that matter for this demo are workload-pool and burst-pool."*

> *"**Weight is the priority** — higher number means Karpenter tries that pool first. workload-pool has weight 50 (higher priority), burst-pool has weight 10 (lower). Think of it this way: workload-pool is our preferred pool for normal traffic; burst-pool is the overflow for spikes."*

🖥️ **Inspect the workload-pool details:**

```bash
kubectl describe nodepool workload-pool | grep -A 35 'Spec:'
```

> *"workload-pool allows D and F series v5 VMs, both on-demand and Spot instances, up to 16 CPU cores total across all nodes in this pool. When those 16 cores are full, new pods overflow to burst-pool."*

🖥️ **Inspect the burst-pool details:**

```bash
kubectl describe nodepool burst-pool | grep -A 35 'Spec:'
```

> *"burst-pool is Spot-only — that means 60-90% cheaper than on-demand. It accepts a wider range of VM families (D, F, and E) which increases the chance of finding available Spot capacity. It also has a 16-core CPU limit and a shorter consolidation timer — 30 seconds vs 60 seconds — so burst nodes get cleaned up faster when demand drops."*

> *"So the full chain is: Load increases → CPU rises above 50% → KEDA scales pods → pods go Pending if no room → Karpenter picks workload-pool first (weight 50) → if workload-pool is full, overflow to burst-pool (weight 10) → new VM provisioned in about 60-90 seconds."*

---

### 9.5 Set Up Monitoring Views

> *"Now let's set up our monitoring so we can watch the scaling chain in real time."*

Open **4 views** — 2 terminal tabs + Azure Portal + browser:

> **Why `watch` instead of `kubectl -w`?**
> The Kubernetes `-w` (watch) flag streams an event line every time *any* field on an object changes — including heartbeat updates every ~40 seconds. During a demo this floods the screen with duplicate node/pod names and makes it look like resources are being added when nothing changed. The Linux `watch` command refreshes the whole output cleanly every N seconds — no duplicates, no confusion.

**Terminal 1 — Pod watcher** (keep open side-by-side):
```bash
watch -n 5 "kubectl top pods -n petclinic 2>/dev/null | head -20; echo '---'; kubectl get pods -n petclinic"
```

This refreshes every 5 seconds and shows two sections separated by `---`:
- **Top half**: CPU and memory usage per pod (sorted by CPU)
- **Bottom half**: Pod status and readiness (you'll see new pods appear and go from `Pending` → `Running`)

**Terminal 2 — Node watcher** (keep open side-by-side):
```bash
watch -n 5 "kubectl top nodes 2>/dev/null; echo '---'; kubectl get nodes -o custom-columns='NAME:.metadata.name,STATUS:.status.conditions[-1:].type,SKU:.metadata.labels.node\.kubernetes\.io/instance-type,CAPACITY-TYPE:.metadata.labels.karpenter\.sh/capacity-type'"
```

This refreshes every 5 seconds and shows:
- **Top half**: CPU% and memory% per node — you'll see utilization climb during the test
- **Bottom half**: Node name, status, VM SKU, and whether it's on-demand or spot — you'll see new nodes appear here when Karpenter provisions them

🌐 **Azure Portal tab**: Navigate to **Azure Load Testing** → your resource (`aks-poc-lt-<suffix>`) → open your test

🌐 **Browser tab**: Keep `http://<INGRESS-IP>` open to show the app is live

> *"We have 4 views: the app in the browser, the pod watcher, the node watcher, and the Azure Load Testing dashboard. Let's add some pressure."*

---

### 9.6 Start the Load Test — "Let's Add Some Pressure"

> *"We're using Azure Load Testing — a fully managed service. We configured a URL-based test: 250 concurrent users hitting two API endpoints — /api/vet/vets and /api/customer/owners — for 5 minutes, with a 30-second ramp-up. Let's see how Karpenter and KEDA handle it."*

🌐 **Azure Portal → Azure Load Testing → your test → click "Run"**

> *"The test is starting. 250 virtual users will ramp up over 30 seconds. Watch the terminals."*

---

### 9.7 Narrate the Scaling Chain — What to Watch For

Follow this timeline and narrate as events appear:

| Time | What's Happening | What to Say | Where to Watch |
|------|-----------------|-------------|----------------|
| ~0-30s | Load ramps up, requests hitting API Gateway | *"Users are ramping up. CPU is climbing."* | Azure Portal — response time / throughput graphs |
| ~30-60s | CPU > 50% → KEDA triggers scaling | *"KEDA detected CPU above 50%. Watch the pod watcher — new pods appearing."* | Terminal 1: new pods go `Pending` → `ContainerCreating` → `Running` |
| ~60-90s | Pods can't fit → go Pending | *"Some pods are in Pending state — the existing nodes are full. Now Karpenter kicks in."* | Terminal 1: pods showing `Pending` |
| ~90-120s | Karpenter provisions a new VM | *"Watch Terminal 2 — a new node is appearing. Karpenter picked the cheapest VM from workload-pool."* | Terminal 2: new node goes `NotReady` → `Ready` |
| ~90-120s | New nodes show `<unknown>` CPU/memory | *"The new nodes show 'unknown' for CPU — that's normal. The metrics-server hasn't scraped them yet. It refreshes every 30-60 seconds."* | Terminal 2: top half shows `<unknown>` for new nodes |
| ~120-180s | Pending pods land on new node | *"The node is Ready. The Pending pods are now scheduling onto it."* | Terminal 1: `Pending` → `Running` |
| ~180s+ | System stabilizes | *"Capacity caught up. Response times are stabilizing."* | Azure Portal: latency graph flattening |

**While the test is running**, switch to a free terminal and run these commands to narrate:

🖥️ **Show pod scaling in action:**
```bash
kubectl get hpa -n petclinic
```

> *"Look at the REPLICAS column — KEDA moved the HPA target up. The api-gateway went from 1 replica to 3, customers-service went to 4, etc."*

🖥️ **Show the ScaledObjects:**
```bash
kubectl get scaledobjects -n petclinic
```

> *"All ScaledObjects show ACTIVE=True — KEDA is actively scaling."*

🖥️ **Show CPU and memory under load:**
```bash
kubectl top pods -n petclinic --sort-by=cpu
```

```bash
kubectl top nodes
```

> *"You can see CPU usage is much higher now across all pods and nodes."*

🖥️ **Show the nodes with details — which VMs did Karpenter choose?**
```bash
kubectl get nodes -o custom-columns=\
'NAME:.metadata.name,SKU:.metadata.labels.node\.kubernetes\.io/instance-type,ZONE:.metadata.labels.topology\.kubernetes\.io/zone,CAPACITY-TYPE:.metadata.labels.karpenter\.sh/capacity-type,AGE:.metadata.creationTimestamp'
```

> *"See the new nodes? Karpenter provisioned them from the workload-pool. Notice the SKU column — these are D-series or F-series v5 VMs. The capacity type shows 'on-demand' or 'spot'. Karpenter didn't pick a giant VM — it picked the smallest one that fits our pods, which is cost-efficient."*

🖥️ **Show NodePool resource consumption:**
```bash
kubectl get nodepools.karpenter.sh -o custom-columns=\
'NAME:.metadata.name,WEIGHT:.spec.weight,CPU-LIMIT:.spec.limits.cpu,CPU-USED:.status.resources.cpu,MEMORY-USED:.status.resources.memory'
```

> *"The workload-pool shows how much CPU and memory is being consumed. If this fills up to the 16-core limit, new pods will overflow to burst-pool (Spot-only, 60-90% cheaper)."*

---

### 9.8 After the Load Test Ends — "Watch the Scale-Down"

> *"The load test is done. Now watch the reverse — the cool-down. This is just as important to demonstrate because it proves we're not wasting money on idle resources."*

Continue watching terminals for 5-10 minutes. Narrate:

| Time After Test | What Happens | What to Say |
|----------------|-------------|-------------|
| ~1-2 min | CPU drops below 50% → KEDA scales pods down | *"CPU dropped. KEDA is scaling pods back to 1 replica."* |
| ~3-5 min | Nodes become underutilized → Karpenter consolidation | *"The nodes are mostly empty now. Karpenter's consolidation policy kicks in."* |
| ~5-10 min | Karpenter drains pods, terminates VMs | *"Watch Terminal 2 — nodes are disappearing. Karpenter drained the pods, cordoned the node, and terminated the VM. We're no longer paying for it."* |
| Final state | Back to 1 replica per service, minimal nodes | *"Back to baseline. System scales up automatically under load, scales back down to save money. No manual intervention required."* |

🖥️ **Verify everything scaled back down:**
```bash
kubectl get pods -n petclinic
```

```bash
kubectl get nodes -o custom-columns=\
'NAME:.metadata.name,SKU:.metadata.labels.node\.kubernetes\.io/instance-type,CAPACITY-TYPE:.metadata.labels.karpenter\.sh/capacity-type'
```

```bash
kubectl get hpa -n petclinic
```

> *"All back to 1 replica. The extra nodes are gone. Cost goes back to baseline."*

---

### 9.9 Wrap-Up Talking Points

Use these to close the demo:

> - *"**KEDA vs HPA**: KEDA extends HPA — you define a ScaledObject, KEDA manages the HPA for you. Never create a standalone HPA alongside KEDA. KEDA can also scale to zero, which HPA alone cannot do."*
> - *"**KEDA vs Karpenter**: KEDA handles pod scaling (HOW MANY pods). Karpenter handles node scaling (WHERE to run them). They work together — KEDA creates demand, Karpenter provides capacity."*
> - *"**NAP vs Cluster Autoscaler**: Cluster Autoscaler requires pre-defined node pools with fixed VM sizes. NAP (Karpenter) picks the right VM type on the fly — cheapest option that satisfies the pod requests. Much more efficient."*
> - *"**Spot savings**: The burst-pool uses Spot instances — 60-90% cheaper than on-demand. Wider SKU selection (D, F, E families) increases Spot availability. For stateless microservices, Spot is ideal."*
> - *"**Full chain**: Azure Load Testing → Ingress → 250 users → CPU rises → KEDA scales pods → pods go Pending → Karpenter provisions the cheapest right-sized VM → pods land → response times stabilize. Load drops → reverse happens automatically. No human involved."*

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
