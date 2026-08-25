# OpenTelemetry Collector

[OpenTelemetry Collector](https://opentelemetry.io/docs/collector/) as the
collection layer of the VictoriaMetrics-based observability stack. Runs as a
DaemonSet (one pod per node) that tails pod log files under `/var/log/pods`,
receives OTLP pushed by workloads, enriches everything with Kubernetes
metadata, and fans the three signals out to their stores.

This is the direct replacement for `apps/alloy` — the two stacks are
either/or: deploy this alongside `apps/victoria-logs`, `apps/victoria-metrics`
and `apps/tempo`, or the Alloy/Loki/kube-prometheus-stack one. **Never run
both log collectors**: each one independently tails every pod's log files, so
running both double-ingests every line.

## Pipelines

All three pipelines get the `k8s_attributes` processor (node-scoped, like
Alloy's `spec.nodeName` field selector) and `memory_limiter` + `batch`.

- **logs** — OTLP + `file_log` (pod stdout/stderr) →
  `http://victoria-logs-server.victoria-logs.svc.cluster.local:9428/insert/opentelemetry/v1/logs`
  (`apps/victoria-logs`)
- **traces** — OTLP → `tempo.tempo.svc.cluster.local:4317`, OTLP gRPC,
  plaintext in-cluster (`apps/tempo`)
- **metrics** — OTLP →
  `http://vmsingle-victoria-metrics.victoria-metrics.svc.cluster.local:8428/api/v1/write`,
  Prometheus remote write (`apps/victoria-metrics`)

The metrics pipeline only carries metrics that applications **push** over
OTLP. Infrastructure and exporter metrics are **scraped** by vmagent
(`apps/victoria-metrics`) — including this collector's own `:8888` telemetry,
via the `VMServiceScrape` in `vmservicescrape.yaml` (the chart only offers a
prometheus-operator ServiceMonitor, whose CRD this stack doesn't install —
see the comment there).

## Sending telemetry from workloads

Point the OTel SDK (or any OTLP client) at the Service:

```shell
# http/protobuf — the SDK default protocol
OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector.otel-collector.svc.cluster.local:4318
# or gRPC
OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector.otel-collector.svc.cluster.local:4317
OTEL_EXPORTER_OTLP_PROTOCOL=grpc
```

The Service uses `internalTrafficPolicy: Local` (the chart's daemonset
default), so pushes are handled by the collector on the sender's own node.
There is no need to set per-signal endpoint variables — unrouted signals just
end at this collector.

## What this intentionally does not replicate from Alloy

- **Ingest-time JSON parsing.** Alloy parsed JSON log lines at ingest and
  promoted a lowercased `level` to a Loki index label; its README also
  documented promoting org-specific fields (`organization_id`,
  `correlation_id`, ...) to structured metadata. Here log bodies ship as-is
  (the `file_log` receiver's `container` operator only unwraps the CRI
  envelope, reassembles runtime-split lines and restores the real timestamp
  — the `stage.cri` equivalent). VictoriaLogs parses JSON cheaply at query
  time; if ingest-time promotion is ever needed, the OTel equivalent is a
  `transform` or `attributes` processor in the logs pipeline — left for
  users to add.
- **Loki index labels.** Kubernetes metadata arrives as OTLP resource
  attributes (which VictoriaLogs maps to stream fields), not hand-picked
  Loki labels.

## Scale-out note

One DaemonSet doing both jobs is the right shape while OTLP volume is modest:
log collection *must* be per-node anyway. When app-pushed OTLP outgrows it,
split into an agent DaemonSet (logs only) plus a gateway Deployment — a
second release of this same chart with `mode: deployment` — and point the
Service at the gateway. See the mode comment in `values.yaml`.

## Notes

- Chart presets do the Kubernetes wiring: `logsCollection` (hostPath mounts,
  `file_log` receiver, checkpoints in `/var/lib/otelcol` so restarts neither
  re-read nor skip lines) and `kubernetesAttributes` (RBAC + `k8s_attributes`
  processor). Checkpointing runs the container as root — see `values.yaml`.
- The cluster is IPv6-only: every listener endpoint is overridden to bracket
  `${env:MY_POD_IP}` — the chart's unbracketed defaults fail Go's host:port
  parsing on IPv6 addresses. Background in `apps/loki/values.yaml`.
- The Service name is pinned with `fullnameOverride` — the chart would
  otherwise render `otel-collector-opentelemetry-collector`.
