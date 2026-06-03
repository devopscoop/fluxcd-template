# Alloy

[Grafana Alloy](https://grafana.com/docs/alloy/) as a cluster-wide log
collector — the official replacement for the now-deprecated Promtail. Runs as a
DaemonSet (one pod per node), tails pod log files under `/var/log/pods`, labels
them with Kubernetes metadata, and pushes them to Loki (`apps/loki`).

## Notes

- Logs are written to `http://loki-gateway.loki.svc.cluster.local/loki/api/v1/push`.
- The River pipeline lives inline in `values.yaml` under `alloy.configMap.content`.
- Pod-discovery RBAC is created by the chart (`rbac.create` default `true`).
- This only collects logs. To also gather metrics/traces with the same agent,
  extend the River config with `prometheus.*` / `otelcol.*` components.
