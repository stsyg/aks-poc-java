---
applyTo: "**/*.yaml,**/k8s/**"
---

# Kubernetes Manifest Instructions

## General Rules
- All resources go in the `petclinic` namespace (except NodePools which are cluster-scoped).
- Always set **resource requests AND limits** on every container.
- Always include **readinessProbe** and **livenessProbe** (use `/actuator/health` for Spring Boot apps).
- Use standard labels: `app`, `version`, `component`.

## Container Images
- Reference images from ACR: `${ACR_NAME}.azurecr.io/spring-petclinic-<service>:latest`
- Use `envsubst` or `sed` for ACR name substitution — never hardcode the registry.
- Never reference DockerHub (`docker.io`) directly in manifests.

## Scaling
- Use **KEDA ScaledObjects** for pod autoscaling — never create standalone HPA resources.
- Define all triggers (CPU, memory, Prometheus) inside the ScaledObject spec.
- KEDA creates and manages the HPA internally.
- Set `minReplicaCount: 1` and `maxReplicaCount: 10` for PoC.

## Karpenter NodePools
- NodePools are cluster-scoped (no namespace).
- Use `karpenter.sh/v1` API version.
- Reference `nodeClassRef: name: default` (auto-created AKSNodeClass).
- Constrain SKU families using `karpenter.azure.com/sku-family`.
- Set `spec.limits.cpu` to cap maximum scaling.
- Use `weight` for priority (higher = preferred).

## Ingress
- Use Application Routing (managed NGINX) via `ingressClassName: webapprouting-nginx`.
- The `webapprouting-nginx` IngressClass is provided by the AKS Application Routing add-on.

## Naming
- Deployment and Service names should match the Spring Boot application name.
- Use lowercase kebab-case for all K8s resource names.
