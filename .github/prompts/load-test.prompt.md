---
mode: agent
description: "Set up and run Azure Load Testing to demonstrate scaling"
---

# Run Load Test

## Context
You are setting up Azure Load Testing to generate load on the PetClinic application and demonstrate the KEDA → HPA → Karpenter scaling chain. Follow the SOP (docs/sop.md) Sections 8-9.

## Pre-requisites
- AKS cluster is running with all services deployed
- KEDA ScaledObjects and Karpenter NodePools are applied
- Azure Load Testing resource is created (by `deploy-infra.sh`)

## Steps
1. Get the API Gateway Ingress external IP:
   ```bash
   kubectl get ingress -n petclinic
   ```

2. Open Azure Portal → Azure Load Testing → Create a URL-based test:
   - URL 1: `http://<INGRESS-IP>/api/vet/vets`
   - URL 2: `http://<INGRESS-IP>/api/customer/owners`
   - Concurrent users: 250
   - Duration: 5 minutes
   - Ramp-up: 30 seconds

3. Open monitoring views side-by-side:
   - Azure Portal: Load Testing dashboard (live metrics)
   - Terminal 1: `kubectl get pods -n petclinic -w`
   - Terminal 2: `kubectl get nodes -w`

4. Start the test and observe the scaling chain.

## What to Watch For
- **~30s**: KEDA detects high CPU / HTTP rate → scales pods
- **~60s**: Pods go Pending (nodes full)
- **~90s**: Karpenter provisions new node from workload-pool
- **~120s**: Node Ready, pods scheduled
- **After test**: KEDA scales down → Karpenter consolidates nodes

## Useful Commands During Demo
```bash
kubectl get scaledobjects -n petclinic
kubectl get hpa -n petclinic
kubectl get nodepools.karpenter.sh
kubectl top pods -n petclinic
kubectl top nodes
```
