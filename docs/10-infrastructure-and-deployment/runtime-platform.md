# Runtime Platform Decision Draft

Evaluate Kubernetes, a managed container service, or an equivalent scheduler against:

- WebSocket connection draining and long-lived connection behavior
- Horizontal scaling signals
- Elixir release lifecycle and clustering/discovery
- Multi-zone scheduling and disruption budgets
- Secret/configuration delivery
- Job-worker isolation
- Operational competence and total cost

The selected platform must demonstrate rolling deployment without losing acknowledged data and must bound reconnect storms during node turnover.
