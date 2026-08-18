# Diagram 1 — Implemented architecture with trust tiers, identity and policy

This diagram reflects what is deployed, not only what was proposed. Every edge shown as denied is
an actual NetworkPolicy outcome verified by `scripts/60-test-networkpolicy.sh`.

```mermaid
graph TB
  subgraph EXT["External"]
    U["Customer browser / curl"]
    NET["Public internet<br/>+ 169.254.169.254 metadata"]
  end

  subgraph K3S["K3s cluster - namespace: shop (Pod Security: restricted)"]
    subgraph PUB["PUBLIC tier"]
      ING["Traefik Ingress<br/>single controlled entry point<br/>rate-limit middleware: average 5, burst 10"]
      GW["gateway - NGINX non-root, 2 replicas<br/>SA: gateway-sa, no token<br/>serves UI, exposes only /api/checkout<br/>mints or propagates X-Request-ID"]
    end

    subgraph INT["INTERNAL tier - no external route"]
      CO["checkout-fn (2)<br/>SA: checkout-sa, no token<br/>composition, 1500 ms timeout budget<br/>critical vs non-critical policy"]
      PR["pricing-fn (2)<br/>SA: pricing-sa, no token<br/>tax and total"]
      IN["inventory-fn (2)<br/>SA: inventory-sa, no token<br/>owns the stock data"]
    end

    subgraph PROT["PROTECTED tier - data"]
      PG[("postgres 16<br/>SA: postgres-sa, no token<br/>PVC 2Gi, RWO")]
    end

    CFG["ConfigMap<br/>platform-config, gateway-config"]
    SEC["Secret: db-credentials<br/>generated at deploy time"]
    DNS["kube-dns<br/>the single egress exception"]
  end

  U -->|HTTP| ING
  ING -->|"ingress: kube-system only"| GW
  GW -->|"ingress: from gateway only"| CO
  CO -->|"from checkout only"| PR
  CO -->|"from checkout only"| IN
  IN -->|"from inventory only"| PG

  CFG -.->|env| GW
  CFG -.->|env| CO
  CFG -.->|env| IN
  SEC -.->|env| IN
  SEC -.->|env| PG

  GW -.->|DENIED| PR
  GW -.->|DENIED| PG
  PR -.->|DENIED| PG
  CO -.->|DENIED| PG

  GW -.->|"EGRESS DENIED"| NET
  CO -.->|"EGRESS DENIED"| NET
  PR -.->|"EGRESS DENIED"| NET
  IN -.->|"EGRESS DENIED"| NET

  GW -->|allowed| DNS
  CO -->|allowed| DNS
  IN -->|allowed| DNS

  classDef pub fill:#e8f0fe,stroke:#4285f4,stroke-width:2px
  classDef int fill:#e6f4ea,stroke:#34a853,stroke-width:2px
  classDef prot fill:#fce8e6,stroke:#ea4335,stroke-width:2px
  classDef cfg fill:#fef7e0,stroke:#fbbc04
  classDef ext fill:#f1f3f4,stroke:#5f6368,stroke-dasharray:4 3
  class ING,GW pub
  class CO,PR,IN int
  class PG prot
  class CFG,SEC,DNS cfg
  class NET ext
```

**How to read it.** Solid arrows are the only permitted paths. Dotted `DENIED` edges are routes
that exist on the flat pod network but are refused by policy — the six lateral cases (B1–B6) and
the four attacker-pod cases (C1–C4). Dotted `EGRESS DENIED` edges are the five outbound cases
(D1–D5), including the cloud metadata endpoint reachable from the workload that holds the database
credentials. DNS is the one deliberate egress exception; without it service discovery fails and the
resulting outage looks like an application bug rather than a policy bug.

Each workload carries its own ServiceAccount with no API permissions and token automounting
disabled, so no pod runs as `default` and no pod can present a cluster identity it was not granted.
