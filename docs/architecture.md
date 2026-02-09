# Architecture — AKS PoC with Karpenter (NAP)

## Network Topology

```mermaid
graph TB
    subgraph OnPrem["Customer's Office"]
        DEV[Developer Workstation]
    end

    subgraph Azure["Azure — Canada Central"]
        subgraph VNet["infra-vnet-01 (192.160.0.0/12)"]
            VPNGW[S2S VPN Gateway]

            subgraph AKSSub["AKS Delegated Subnet (/24)"]
                subgraph AKS["AKS Private Cluster"]
                    API[API Server<br/>Private Endpoint]
                    SYS[System Pool<br/>1× Standard_B2s]
                    
                    subgraph NAP["NAP / Karpenter Managed"]
                        WP[workload-pool<br/>D/F v5<br/>On-demand + Spot]
                        BP[burst-pool<br/>D/F/E v5<br/>Spot only]
                    end
                end
            end
        end

        ACR[Azure Container<br/>Registry — Basic]
        ALT[Azure Load<br/>Testing]
        MON[Azure Monitor<br/>Container Insights]
        LB[Azure Load Balancer<br/>Public IP]
    end

    BROWSER[Browser — Demo Viewer]

    DEV -->|S2S VPN| VPNGW
    DEV -->|kubectl| API
    AKS -->|Pull images| ACR
    AKS -->|Metrics| MON
    ALT -->|HTTP Load| LB
    BROWSER -->|HTTP| LB
    LB -->|Ingress| AKS

    classDef azure fill:#0078D4,stroke:#fff,color:#fff
    classDef onprem fill:#4A4A4A,stroke:#fff,color:#fff
    classDef karpenter fill:#FF6B35,stroke:#fff,color:#fff
    class ACR,ALT,MON,LB,VPNGW azure
    class DEV,BROWSER onprem
    class WP,BP karpenter
```

## Application Architecture

```mermaid
graph LR
    subgraph External
        BROWSER[Browser]
        ALT[Azure Load Testing]
    end

    subgraph AKS["AKS Cluster — petclinic namespace"]
        subgraph Infra["Infrastructure Services"]
            CS[Config Server<br/>Port 8888]
            DS[Discovery Server<br/>Eureka — Port 8761]
        end

        subgraph Gateway["Edge"]
            GW[API Gateway<br/>Spring Cloud Gateway<br/>Port 8080]
        end

        subgraph Backend["Business Services"]
            CUST[Customers Service<br/>Port 8081]
            VETS[Vets Service<br/>Port 8083]
            VISIT[Visits Service<br/>Port 8082]
        end
    end

    BROWSER -->|HTTP| GW
    ALT -->|HTTP Load| GW
    GW -->|/api/customer/*| CUST
    GW -->|/api/vet/*| VETS
    GW -->|/api/visit/*| VISIT
    CUST -->|Register| DS
    VETS -->|Register| DS
    VISIT -->|Register| DS
    GW -->|Register| DS
    CS -.->|Config| DS
    CS -.->|Config| GW
    CS -.->|Config| CUST
    CS -.->|Config| VETS
    CS -.->|Config| VISIT

    classDef infra fill:#6C757D,stroke:#fff,color:#fff
    classDef gateway fill:#0078D4,stroke:#fff,color:#fff
    classDef backend fill:#28A745,stroke:#fff,color:#fff
    class CS,DS infra
    class GW gateway
    class CUST,VETS,VISIT backend
```

## Scaling Chain — KEDA → HPA → Karpenter

```mermaid
sequenceDiagram
    participant ALT as Azure Load Testing
    participant APP as API Gateway / Services
    participant KEDA as KEDA Operator
    participant HPA as HPA (managed by KEDA)
    participant SCHED as K8s Scheduler
    participant KARP as Karpenter (NAP)
    participant AZURE as Azure Compute

    Note over ALT,AZURE: Phase 1 — Load Increases
    ALT->>APP: 250 concurrent HTTP requests
    APP->>APP: CPU rises above 50%

    Note over KEDA,HPA: Phase 2 — Pod Scaling
    KEDA->>KEDA: Detect trigger threshold exceeded
    KEDA->>HPA: Update desired replicas (1→3)
    HPA->>SCHED: Create 2 new pod replicas

    Note over SCHED,KARP: Phase 3 — Node Scaling
    SCHED->>SCHED: Cannot place pods (nodes full)
    SCHED-->>KARP: Pods in Pending state
    KARP->>KARP: Evaluate NodePools by weight
    KARP->>KARP: Select cheapest VM (workload-pool first)
    KARP->>AZURE: Provision Standard_D2s_v5 (Spot)
    AZURE-->>KARP: Node Ready (~90s)
    SCHED->>APP: Schedule pending pods on new node

    Note over ALT,AZURE: Phase 4 — Load Decreases
    ALT->>ALT: Test ends
    APP->>APP: CPU drops below threshold
    KEDA->>HPA: Update desired replicas (3→1)
    HPA->>SCHED: Terminate excess pods
    KARP->>KARP: Detect underutilized node
    KARP->>AZURE: Drain and terminate node
```

## Karpenter NodePool Priority

```mermaid
flowchart TD
    PENDING[Pending Pod<br/>Needs: 250m CPU, 512Mi RAM] --> EVAL{Evaluate NodePools<br/>by weight}

    EVAL -->|Weight 50 — try first| WP[workload-pool<br/>D, F families v5<br/>On-demand + Spot]
    EVAL -->|Weight 10 — overflow| BP[burst-pool<br/>D, F, E families v5<br/>Spot only]

    WP --> WP_CHECK{Can satisfy<br/>pod requirements?}
    WP_CHECK -->|Yes| WP_SELECT[Select cheapest VM<br/>e.g., Standard_D2as_v5 Spot]
    WP_CHECK -->|No — CPU limit reached| BP

    BP --> BP_CHECK{Can satisfy<br/>pod requirements?}
    BP_CHECK -->|Yes| BP_SELECT[Select cheapest Spot VM<br/>e.g., Standard_E2as_v5 Spot]
    BP_CHECK -->|No — CPU limit reached| FAIL[Pod remains Pending]

    WP_SELECT --> PROVISION[Provision Node<br/>~60-90 seconds]
    BP_SELECT --> PROVISION

    classDef pool fill:#0078D4,stroke:#fff,color:#fff
    classDef decision fill:#FFC107,stroke:#333,color:#333
    classDef action fill:#28A745,stroke:#fff,color:#fff
    classDef fail fill:#DC3545,stroke:#fff,color:#fff
    class WP,BP pool
    class WP_CHECK,BP_CHECK,EVAL decision
    class WP_SELECT,BP_SELECT,PROVISION action
    class FAIL fail
```
