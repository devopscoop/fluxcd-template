# VictoriaLogs

VictoriaLogs as a log store, deployed **single-node** (one StatefulSet pod
writing to a local PVC). This is the logs half of the VictoriaMetrics-based
observability stack and the direct alternative to `apps/loki` — the two stacks
are either/or: deploy this one alongside `apps/victoria-metrics`, `apps/tempo`
and `apps/otel-collector`, or the Loki/kube-prometheus-stack one, not both.

VictoriaLogs only *stores* logs — `apps/otel-collector` ships pod logs into it.

## Ingestion

Everything talks to the server Service:
`http://victoria-logs-server.victoria-logs.svc.cluster.local:9428`
(the name is pinned via `server.fullnameOverride` in `values.yaml`).

- **OTLP logs** — `POST /insert/opentelemetry/v1/logs`. This is what
  `apps/otel-collector` uses to ship pod logs.
- **Loki push API** — `POST /insert/loki/api/v1/push`. An existing Alloy
  DaemonSet (`apps/alloy`) can migrate off Loki by swapping its push URL to
  this endpoint — no pipeline changes needed.

(VictoriaLogs also accepts Elasticsearch bulk, jsonline and syslog; see the
upstream data-ingestion docs.)

## Querying

- The `victoriametrics-logs-datasource` Grafana plugin is provisioned by the
  Grafana in `apps/victoria-metrics`, pointed at the Service above.
- Built-in web UI for ad-hoc LogsQL queries:
  `kubectl -n victoria-logs port-forward svc/victoria-logs-server 9428`, then
  open `http://localhost:9428/select/vmui`.

## Durability caveat

Unlike Loki, open-source single-node VictoriaLogs has **no object-storage
backend** — every log lives only on the pod's PVC, so durability is exactly
the durability of the underlying PV (e.g. a single-AZ EBS volume). Losing the
volume loses the logs. If that's not acceptable, back the PVC up externally
(e.g. EBS snapshots); the paid cluster version or Loki are the alternatives
with replicated/object storage.

## Notes

- Retention is 31 days (`server.retentionPeriod: 31d`), matching the loki
  app's `retention_period: 744h`.
- Disk grows with ingestion. VictoriaLogs compresses aggressively, so the
  20Gi PVC goes a long way; watch `vl_data_size_bytes` (scraped via the
  VMServiceScrape) and grow `server.persistentVolume.size` with usage —
  gp3/EBS volumes expand online, but never shrink. A hard safety net is
  available via `server.retentionDiskSpaceUsage` if the volume ever runs
  tight before retention kicks in.
