---
mode: agent
description: "Deploy AKS cluster with Karpenter (NAP) and all add-ons"
---

# Deploy AKS Cluster

## Context
You are deploying the AKS private cluster for the Java migration PoC. Follow the SOP (docs/sop.md) Section 2.

## Steps
1. Ensure `.env` file exists with `SUBSCRIPTION_ID` and VNet details filled in.
2. Run `./scripts/deploy-infra.sh` to create all Azure infrastructure.
3. Verify the cluster is running and all add-ons are healthy.
4. Refer to docs/sop.md Section 3 for verification steps.

## Key Details
- The script generates a random suffix and computes all resource names.
- A delegated subnet is created in the existing VNet for AKS (NAP requirement).
- The cluster is private — API server only accessible via VNet.
- If `kubectl` fails with DNS errors, use `az aks command invoke` as fallback.

## Verification
```bash
kubectl get nodes
kubectl get nodepools.karpenter.sh
kubectl get pods -n kube-system | grep -E "keda|cilium|nginx|policy"
```
