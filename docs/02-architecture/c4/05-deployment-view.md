# Deployment View

```mermaid
flowchart TB
    Internet[Internet]
    WAF[CDN / WAF / Load Balancer]
    subgraph Region[Primary Region]
      subgraph AZ1[Availability Zone A]
        Edge1[Edge/API Pods]
        Worker1[Worker Pods]
      end
      subgraph AZ2[Availability Zone B]
        Edge2[Edge/API Pods]
        Worker2[Worker Pods]
      end
      DBP[(PostgreSQL Primary)]
      DBS[(Synchronous or Async Standby)]
      Obj[(Regional Object Storage)]
      Obs[Telemetry Collectors]
    end
    DR[Warm DR Region]

    Internet --> WAF
    WAF --> Edge1
    WAF --> Edge2
    Edge1 --> DBP
    Edge2 --> DBP
    Worker1 --> DBP
    Worker2 --> DBP
    DBP --> DBS
    Edge1 --> Obs
    Edge2 --> Obs
    Worker1 --> Obs
    Worker2 --> Obs
    DBP -. backups/replication .-> DR
    Obj -. replication .-> DR
```

The production design must tolerate loss of one application instance and one availability zone without losing acknowledged messages, subject to the approved database replication mode.
