---
mode: agent
description: "Deploy Spring PetClinic Microservices to AKS"
---

# Deploy Application

## Context
You are deploying the Spring PetClinic Microservices to the AKS cluster. Follow the SOP (docs/sop.md) Section 5.

## Steps
1. Ensure the cluster is running and you have `kubectl` access.
2. Run `./scripts/deploy-apps.sh` to deploy all services in the correct order.
3. Verify all pods are running and the application is accessible.

## Deployment Order (Critical)
The order matters due to Spring Cloud dependencies:
1. **Namespace** (`petclinic`)
2. **Config Server** — must be Ready before other services start
3. **Discovery Server (Eureka)** — depends on Config Server
4. **API Gateway** — depends on Discovery Server
5. **Customers, Vets, Visits services** — depend on Config + Discovery

## Key Details
- Images come from ACR (imported via `az acr import`, not built from source).
- The `deploy-apps.sh` script substitutes `$ACR_NAME` into manifests using `envsubst`.
- Resource requests are intentionally tight (250m CPU, 512Mi memory) to trigger scaling faster.
- API Gateway is exposed via Ingress (Application Routing / managed NGINX).

## Verification
```bash
kubectl get pods -n petclinic
kubectl get svc -n petclinic
kubectl get ingress -n petclinic
# Open the Ingress external IP in a browser
```
