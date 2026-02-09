---
mode: agent
description: "Troubleshoot scaling, DNS, pod, and node issues"
---

# Troubleshoot Issues

## Common Issues

### 1. kubectl cannot connect (DNS resolution failed)
The cluster is private. The API server FQDN resolves only within the VNet.

**Quick fix — add hosts entry:**
```bash
source .env
PRIVATE_FQDN=$(az aks show --name "$CLUSTER_NAME" --resource-group "$RG_NAME" --query privateFqdn -o tsv)
# Get the private endpoint IP from the managed resource group
MC_RG=$(az aks show --name "$CLUSTER_NAME" --resource-group "$RG_NAME" --query nodeResourceGroup -o tsv)
PRIVATE_IP=$(az network private-endpoint list --resource-group "$MC_RG" --query "[0].customDnsConfigs[0].ipAddresses[0]" -o tsv)
echo "$PRIVATE_IP $PRIVATE_FQDN" | sudo tee -a /etc/hosts
```

**Alternative — use az aks command invoke:**
```bash
az aks command invoke --name "$CLUSTER_NAME" --resource-group "$RG_NAME" \
  --command "kubectl get nodes"
```

### 2. Pods stuck in Pending
Check if Karpenter is failing to provision nodes:
```bash
kubectl describe pod <pod-name> -n petclinic
kubectl get events -n petclinic --sort-by='.lastTimestamp'
kubectl get nodepools.karpenter.sh
kubectl describe nodepool workload-pool
```
Common causes: NodePool CPU limit reached, no matching VM SKUs available in region, Spot capacity unavailable.

### 3. Pods CrashLoopBackOff
Spring Cloud services have startup dependencies. Check if Config Server and Discovery Server are running:
```bash
kubectl get pods -n petclinic -l app=config-server
kubectl get pods -n petclinic -l app=discovery-server
kubectl logs -n petclinic -l app=<failing-service> --tail=50
```

### 4. KEDA ScaledObject not scaling
```bash
kubectl get scaledobjects -n petclinic
kubectl describe scaledobject <name> -n petclinic
kubectl get hpa -n petclinic
kubectl logs -n kube-system -l app=keda-operator --tail=50
```

### 5. Ingress not getting external IP
```bash
kubectl get ingress -n petclinic
kubectl get pods -n app-routing-system
kubectl describe ingress api-gateway -n petclinic
```

### 6. ACR image pull failures
```bash
kubectl describe pod <pod-name> -n petclinic | grep -A5 Events
# Verify ACR attachment
az aks check-acr --name "$CLUSTER_NAME" --resource-group "$RG_NAME" --acr "$ACR_NAME.azurecr.io"
```
