# Alloy

[Grafana Alloy](https://grafana.com/docs/alloy/) as a cluster-wide log
collector — the official replacement for the now-deprecated Promtail. Runs as a
DaemonSet (one pod per node), tails pod log files under `/var/log/pods`, labels
them with Kubernetes metadata, and pushes them to Loki (`apps/loki`).

## Notes

- Logs are written to `http://loki-gateway.loki.svc.cluster.local/loki/api/v1/push`.
- The River pipeline lives inline in `values.yaml` under `alloy.configMap.content`.
- Pod-discovery RBAC is created by the chart (`rbac.create` default `true`).
- Discovery is node-scoped (`spec.nodeName` field selector): each DaemonSet
  pod watches only its own node's pods, so API-server watch load stays flat
  as the cluster grows.
- This only collects logs. To also gather metrics/traces with the same agent,
  extend the River config with `prometheus.*` / `otelcol.*` components.

## Log parsing at ingest

Every line has its CRI envelope (`2026-01-01T00:00:00Z stderr F ...`)
unwrapped at ingest (`loki.process` in `values.yaml`): the stored line is the
container's own output, the entry timestamp is the container write time, a
`stream` label (`stdout`/`stderr`) is added, and long lines that the runtime
split into partial chunks (containerd splits at 16k) are reassembled. The
unwrap deliberately applies to all lines, not just JSON ones — partial-line
reassembly buffers chunks per stream, so `stage.cri` must see every entry of
a stream to pair the chunks correctly.

Lines that are JSON additionally get the `level` field promoted to a Loki
index label — so `{namespace="x", level="error"}` skips chunks instead of
scanning them. The level is lowercased first (`INFO` → `info`), so each level
maps to exactly one label value regardless of the app's casing convention.

To promote additional (org-specific) JSON fields, add them to
`stage.json`'s `expressions` and route them to `stage.structured_metadata`
(unbounded values: ids, request/trace ids) or `stage.labels` (only
low-cardinality values — every label value combination creates a new stream).

**Cutover caveat for existing clusters**: adopting this changes the stored
line format of every stream — new lines arrive without the CRI prefix, while
already-stored lines keep it until retention ages them out. Queries that strip
the prefix with `pattern`/`line_format` will silently mis-parse new lines;
migrate them to bare `| json` (or the `level` label) after the cutover.
