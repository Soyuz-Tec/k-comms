# Deployment View

```mermaid
flowchart TB
    Internet[Internet]
    WAF[CDN / WAF / Load Balancer]
    MediaEdge[Trusted WSS / TURN / Media Endpoint]
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
      Media[Provider-composed LiveKit Media Plane]
    end
    DR[Warm DR Region]

    Internet --> WAF
    WAF --> Edge1
    WAF --> Edge2
    Internet --> MediaEdge
    MediaEdge --> Media
    Edge1 --> DBP
    Edge2 --> DBP
    Worker1 --> DBP
    Worker2 --> DBP
    DBP --> DBS
    Edge1 --> Obs
    Edge2 --> Obs
    Worker1 --> Obs
    Worker2 --> Obs
    Media --> Obs
    DBP -. backups/replication .-> DR
    Obj -. replication .-> DR
```

The production design must tolerate loss of one application instance and one
availability zone without losing acknowledged messages, subject to the
approved database replication mode. Audio/video production activation
additionally requires a separately qualified media endpoint with trusted WSS,
ICE/UDP, ICE/TCP, restricted TURN/TLS, bandwidth and group-capacity evidence,
privacy approval, and failure evidence. A media outage degrades calls but must
not make durable text messaging unavailable. The portable application overlay
references this external boundary and does not deploy LiveKit or TURN.
