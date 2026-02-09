# AKS PoC Plan — Java Migration with Karpenter (NAP)

> **This document is the authoritative reference for all decisions in this PoC.**
> Referenced by `.github/copilot-instructions.md` and used by GitHub Copilot as grounding context.

## Purpose

Build a Proof of Concept demonstrating Azure Kubernetes Service (AKS) for a customer migrating Java applications from AWS/GCP. The customer is familiar with Karpenter on EKS and wants the same experience on AKS via **Node Autoprovision (NAP)**.

## What We Demonstrate

1. **AKS private cluster** with Microsoft-recommended add-ons
2. **Karpenter (NAP)** — automatic right-sized node provisioning with multiple NodePools
3. **KEDA** — event-driven pod autoscaling (extends HPA, supports scale-to-zero)
4. **Three-layer scaling chain**: KEDA → HPA (managed by KEDA) → Karpenter (NAP)
5. **Azure Load Testing** — polished portal dashboard for live scaling visualization
6. **Spring PetClinic Microservices** — realistic multi-service Java application with browser UI

## Architecture Summary

```
Customer's Office
  └── S2S VPN ──► Azure VNet (infra-vnet-01)
                    └── AKS Private Cluster (delegated subnet)
                          ├── System Pool: 1× Standard_B2s (burstable)
                          ├── NAP workload-pool: D/F v5 (On-demand + Spot)
                          ├── NAP burst-pool: D/F/E v5 (Spot only)
                          └── Pods: PetClinic Microservices (6 services)
                                └── Exposed via managed NGINX Ingress (public IP)

Azure Load Testing ──► Public Ingress IP ──► API Gateway ──► Backend Services
```

**Private cluster**: API server accessible only via VNet + S2S VPN. Application UI exposed via public Ingress (managed NGINX).

## Technology Stack

| Component | Technology |
|-----------|-----------|
| Language | Java 21 (Microsoft OpenJDK) |
| Framework | Spring Boot 3.x, Spring Cloud |
| Demo App | Spring PetClinic Microservices (7 services) |
| Container Registry | Azure Container Registry (Basic) |
| Kubernetes | AKS with NAP (Karpenter) |
| Pod Scaling | KEDA managed add-on (ScaledObjects) |
| Node Scaling | NAP / Karpenter |
| Networking | Azure CNI Overlay + Cilium |
| Ingress | Application Routing (managed NGINX) |
| Load Testing | Azure Load Testing (URL-based) |
| Monitoring | Azure Monitor + Container Insights |
| IaC | az CLI scripts |
| Secrets | .env file (gitignored) |

## AKS Add-ons Enabled

| Add-on | CLI Flag | Purpose |
|--------|----------|---------|
| NAP (Karpenter) | `--node-provisioning-mode Auto` | Automatic node provisioning |
| KEDA | `--enable-keda` | Event-driven pod autoscaling |
| Monitoring | `--enable-addons monitoring` | Container Insights + Managed Prometheus |
| Azure Policy | `--enable-addons azure-policy` | Governance guardrails (audit mode) |
| Key Vault Secrets Provider | `--enable-addons azure-keyvault-secrets-provider` | CSI driver for Key Vault secrets |
| Workload Identity | `--enable-oidc-issuer --enable-workload-identity` | Pod-to-Azure authentication |
| Application Routing | `--enable-app-routing` | Managed NGINX ingress controller |
| Image Cleaner | `--enable-image-cleaner` | Auto-removal of stale images from nodes |

## Karpenter NodePools

| NodePool | SKU Families | Capacity Type | CPU Limit | Weight | Purpose |
|----------|-------------|---------------|-----------|--------|---------|
| `default` | D | On-demand | (default) | — | NAP auto-created |
| `system-surge` | — | — | — | — | NAP auto-created for system pool |
| `workload-pool` | D, F (v5) | On-demand + Spot | 16 cores | 50 (higher) | Primary app workloads |
| `burst-pool` | D, F, E (v5) | Spot only | 16 cores | 10 (lower) | Overflow during load spikes |

## KEDA ScaledObjects

| Service | Triggers | Min/Max Replicas |
|---------|----------|-----------------|
| api-gateway | CPU (50% avg) | 1 / 10 |
| customers-service | CPU (50% avg) | 1 / 10 |
| vets-service | CPU (50% avg) | 1 / 10 |
| visits-service | CPU (50% avg) + Prometheus HTTP rate | 1 / 10 |

**Critical rule**: Never create a standalone HPA for a deployment that has a KEDA ScaledObject. KEDA manages the HPA internally. Define all triggers inside the ScaledObject.

## Scaling Chain Explained

```
Load increase
  → KEDA detects trigger threshold exceeded (CPU > 50% or HTTP rate > threshold)
    → KEDA updates the HPA it manages (increases desired replicas)
      → HPA creates new pod replicas
        → If pods don't fit on existing nodes → Pods go Pending
          → Karpenter detects Pending pods
            → Karpenter evaluates NodePools (workload-pool first due to higher weight)
              → Karpenter selects cheapest right-sized VM from allowed families
                → New node provisioned (~60-90 seconds)
                  → Scheduler places Pending pods on new node

Load decrease
  → KEDA detects trigger below threshold
    → KEDA updates HPA (decreases desired replicas)
      → HPA removes excess pods
        → Nodes become underutilized
          → Karpenter consolidation: drains pods, terminates empty nodes
```

## Resource Naming Convention

All resource names use a static prefix + 5-character random suffix:

| Resource | Pattern | Example |
|----------|---------|---------|
| Resource Group | `aks-poc-java-${SUFFIX}-rg` | `aks-poc-java-d45j5-rg` |
| AKS Cluster | `aks-poc-java-${SUFFIX}` | `aks-poc-java-d45j5` |
| ACR | `akspocjava${SUFFIX}` | `akspocjavad45j5` |
| Managed Identity | `aks-poc-java-id-${SUFFIX}` | `aks-poc-java-id-d45j5` |
| Load Test | `aks-poc-lt-${SUFFIX}` | `aks-poc-lt-d45j5` |
| AKS Subnet | `aks-poc-${SUFFIX}` | `aks-poc-d45j5` |

The suffix is generated once by `deploy-infra.sh` and stored in `.env`.

## Infrastructure Details

| Parameter | Value |
|-----------|-------|
| Region | Canada Central |
| Existing VNet | `infra-vnet-01` (RG: `infra-network-rg`) |
| VNet Address Space | 192.160.0.0/12 |
| Existing Node Subnet | `infra-lab-k8s` (192.167.240.0/20) |
| New AKS Subnet | Delegated /24 in infra-vnet-01 |
| System Node Pool | 1× Standard_B2s (burstable, ~$33/mo) |
| AKS Tier | Standard (SLA-backed) |
| Cluster Access | Private (API server via VNet + S2S VPN) |

## Decisions Log

| # | Decision | Chosen | Rationale |
|---|----------|--------|-----------|
| 1 | Cluster type | **Private** | Realistic for enterprise migration from AWS/GCP. API server only via VNet + S2S VPN. |
| 2 | VNet | **Existing (infra-vnet-01)** | S2S VPN connectivity. New delegated /24 subnet for AKS. |
| 3 | API server VNet integration | **Yes (implicit)** | NAP + custom VNet mandates delegated subnet. |
| 4 | Pod autoscaling | **KEDA ScaledObjects** | KEDA extends HPA — manages HPAs internally. Supports event-driven triggers + scale-to-zero. |
| 5 | KEDA + HPA coexistence | **All triggers in ScaledObject** | Never create standalone HPA alongside ScaledObject — they conflict. |
| 6 | Node autoscaling | **NAP (Karpenter)** | Customer is familiar with Karpenter on EKS. NAP is Microsoft's managed equivalent. |
| 7 | AKS add-ons | **All recommended** | KEDA, Workload Identity, App Routing, Image Cleaner, Azure Policy, Key Vault CSI, Monitoring. |
| 8 | Ingress | **Application Routing (managed NGINX)** | Managed by AKS. No extra ALB cost. |
| 9 | System nodes | **1× Standard_B2s** | Burstable, ~$33/mo. System pods mostly idle in PoC. |
| 10 | NAP workload VMs | **D, F, E v5 families, max 16 CPU/pool** | Cost-capped. Spot in burst-pool for 60-90% savings. |
| 11 | Container registry | **ACR Basic (mandatory)** | Images via `az acr import`. NAP nodes auto-inherit pull creds. ~$5/mo. |
| 12 | Load testing | **Azure Load Testing (URL-based)** | Portal dashboard for polished demo. ~$1-2/run. No scripting needed. |
| 13 | Resource naming | **Static prefix + random suffix** | Repeatable build/teardown cycles without collisions. |
| 14 | Tags | **environment=Lab, designation=Poc, provisioner=Manual** | All Azure resources tagged for cost tracking. |
| 15 | DNS for kubectl | **Hosts file + az aks command invoke fallback** | Simplest for PoC. |
| 16 | Image source | **DockerHub → ACR import** | No builds, no Dockerfiles. `az acr import` in seconds. |
| 17 | App exposure | **Public Ingress** | Private cluster = private API server, not private services. App gets public IP. |
| 18 | Networking | **Azure CNI Overlay + Cilium** | Required by NAP. Overlay = fewer VNet IPs consumed. |

## Cost Estimate (Monthly, if running 24/7)

| Resource | Approximate Cost |
|----------|-----------------|
| AKS Standard tier | ~$75/mo |
| 1× Standard_B2s system node | ~$33/mo |
| ACR Basic | ~$5/mo |
| NAP workload nodes (variable) | ~$30-100/mo (Spot-heavy, scales to 0 when idle) |
| Azure Load Testing | ~$1-5 per test run |
| **Total (cluster idle)** | **~$113/mo** |
| **Total (during demo, 2 extra nodes)** | **~$150-200/mo** |

> **Important**: AKS clusters with NAP cannot be stopped (`az aks stop` is blocked). Use `./scripts/teardown.sh` to delete everything when done.
