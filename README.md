# AKS PoC — Java Migration with Karpenter (NAP)

Proof of Concept demonstrating Azure Kubernetes Service for migrating Java applications. Features **Karpenter (NAP)** for automatic node provisioning, **KEDA** for event-driven pod autoscaling, and **Azure Load Testing** for live scaling demos.

## Quick Start

```bash
# 1. Configure
cp .env.example .env
# Edit .env → set SUBSCRIPTION_ID

# 2. Authenticate
az login && az account set --subscription "$(grep SUBSCRIPTION_ID .env | cut -d= -f2)"

# 3. Deploy infrastructure (~10 min)
./scripts/deploy-infra.sh

# 4. Deploy application (~5 min)
./scripts/deploy-apps.sh

# 5. Open PetClinic in browser
kubectl get ingress api-gateway -n petclinic

# 6. Teardown when done
./scripts/teardown.sh
```

## What's Inside

| Component | Description |
|-----------|-------------|
| **AKS Private Cluster** | Standard tier, Azure CNI Overlay + Cilium, all recommended add-ons |
| **Karpenter (NAP)** | 2 custom NodePools: workload (On-demand+Spot) and burst (Spot-only) |
| **KEDA** | ScaledObjects for all services (CPU trigger + Prometheus template) |
| **Spring PetClinic** | 7-service Java microservice app with web UI |
| **Azure Load Testing** | URL-based load tests with portal dashboard |
| **DevContainer** | az CLI, kubectl, Java 21, Maven, jq — everything pre-installed |

## Scaling Demo

The three-layer scaling chain:

```
KEDA (pod autoscaling) → HPA (managed by KEDA) → Karpenter/NAP (node provisioning)
```

1. Azure Load Testing sends 250 concurrent users to the app
2. KEDA detects CPU > 50%, scales pods from 1 → N
3. Pods go Pending (nodes full) → Karpenter provisions right-sized VMs
4. New nodes Ready in ~90s → pods scheduled
5. Load stops → KEDA scales down → Karpenter consolidates nodes

## Documentation

| Doc | Description |
|-----|-------------|
| [docs/sop.md](docs/sop.md) | **Start here** — Step-by-step Standard Operating Procedure |
| [docs/plan.md](docs/plan.md) | Architecture decisions and technology choices |
| [docs/architecture.md](docs/architecture.md) | Mermaid diagrams (network, app, scaling chain) |

## Repository Structure

```
.devcontainer/          DevContainer configuration
.github/                Copilot instructions and prompt files
docs/                   SOP, plan, architecture diagrams
k8s/
  namespace.yaml        petclinic namespace
  nodepools/            Karpenter NodePool definitions
  apps/                 Deployment + Service manifests (6 services)
  scaling/              KEDA ScaledObject definitions
  ingress/              Application Routing ingress
scripts/
  deploy-infra.sh       Create all Azure infrastructure
  deploy-apps.sh        Deploy PetClinic to AKS
  teardown.sh           Destroy everything
.env.example            Environment variable template
```

## Cost

| Running State | Approximate Monthly Cost |
|--------------|-------------------------|
| Cluster idle (system node only) | ~$113/mo |
| During demo (2-3 extra nodes) | ~$150-200/mo |
| After teardown | $0 |

> **Note**: AKS clusters with NAP cannot be stopped. Run `./scripts/teardown.sh` to delete and stop billing.
