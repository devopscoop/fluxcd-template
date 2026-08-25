# Tempo

Grafana Tempo as a trace store, deployed **monolithic** (the `tempo` chart
only does single-binary mode) and backed by **S3-compatible object storage**.
This is the traces piece of the VictoriaMetrics-based observability stack —
deploy it alongside `apps/victoria-metrics`, `apps/victoria-logs` and
`apps/otel-collector`. That stack is the either/or alternative to the
kube-prometheus-stack/Alloy/Loki stack: run one or the other, not both.

Tempo only *stores* traces — `apps/otel-collector` ships spans into it.

## Service endpoints

Everything talks to the Service `tempo.tempo.svc.cluster.local` (release name
equals chart name, so the chart's fullname helper already yields `tempo` — no
fullnameOverride needed):

- `:4317` (OTLP gRPC) and `:4318` (OTLP HTTP) — trace ingest, used by
  `apps/otel-collector`.
- `:3200` — Tempo's HTTP API (TraceQL search/query and Tempo's own metrics).
  The Grafana in `apps/victoria-metrics` provisions a Tempo datasource
  pointing here.

The chart also renders Jaeger/Zipkin/legacy-OTLP Service ports by default.
Nothing sends to them, and on this IPv6-only cluster those receivers bind
IPv4-only anyway — see the receivers comment in `values.yaml`.

## Before deploying

Authentication to S3 is via **IRSA** (IAM Roles for Service Accounts) — no
static access keys, so there's nothing to encrypt here.

1. Create one S3 bucket for trace blocks.
2. Create an IAM role with read/write to that bucket and a trust policy for
   this cluster's OIDC provider, scoped to the `tempo` ServiceAccount in the
   `tempo` namespace.
3. Fill in the placeholders in `values.yaml`:
   - `tempo.storage.trace.s3` → `bucket`, `region`, and the region in
     `endpoint` (keep the `dualstack` endpoint — the cluster is IPv6-only).
   - `serviceAccount.annotations` → `eks.amazonaws.com/role-arn` with the
     role ARN from step 2 (replace `ACCOUNT_ID`). This block is commented out
     by default and is uncommented automatically by `deploy.sh` when
     `k8s_platform=eks`.

To use static access keys instead of IRSA (e.g. for a non-AWS S3 backend like
Rook-Ceph RGW or MinIO), see the commented-out alternatives in `values.yaml`
and `helm_secrets.yaml.decrypted`. There's also a commented-out local-disk
backend in `values.yaml` that keeps trace blocks on the PVC instead of S3.

## Metrics generator

The metrics generator is enabled with the **span-metrics** and
**service-graphs** processors: RED metrics (rate/errors/duration per service
and operation) and service-graph edges are derived from the span stream and
remote-written to
`http://vmsingle-victoria-metrics.victoria-metrics.svc.cluster.local:8428/api/v1/write`.
This is what makes Grafana's service-graph view and span-metrics dashboards
work, and it requires `apps/victoria-metrics`. If vmsingle is unreachable the
generator logs remote-write errors and drops samples — trace ingest and query
keep working.

## Notes

- The chart comes from
  [grafana-community/helm-charts](https://github.com/grafana-community/helm-charts):
  the `tempo` chart moved there from the `grafana` repo after 2026-01-30, and
  new versions only land in the new home (the `grafana` repo copy is frozen
  at 1.24.4 and marked deprecated). This app made the promised 1.24.4 → 2.x
  jump; despite the major-version bump, no values keys changed — 2.x mainly
  added an optional Gateway API HTTPRoute and dropped the OpenCensus
  receiver. Note this is a different HelmRepository than `apps/loki`'s
  `grafana`.
- Retention is 30 days (`tempo.retention`, rendered into the compactor's
  `block_retention`), parity with the 30-day metrics retention in
  `apps/victoria-metrics` and the 31-day logs retention in
  `apps/victoria-logs`.
- OTLP receivers are enabled by the chart's defaults; `values.yaml` only
  re-pins their endpoints to `[::]` because the default `0.0.0.0` bind is
  unreachable on an IPv6-only cluster.
- The other IPv6-only accommodations: every active ring runs on an
  `inmemory` kvstore with `enable_inet6: true` (memberlist is then never
  even instantiated), and S3 uses the dualstack endpoint. The
  metrics-generator ring has no chart values key, so `values.yaml` replaces
  the chart's whole `config` template with a copy carrying that one addition
  — re-diff that block against the chart's defaults on upgrades.
- Tempo's own metrics are scraped via the `VMServiceScrape` in
  `vmservicescrape.yaml` (the chart only offers a prometheus-operator
  ServiceMonitor, whose CRD this stack doesn't install — see the comment
  there). That CRD comes from the VictoriaMetrics operator, so
  `apps/victoria-metrics` must land first — that's the `dependsOn` in
  `flux/flux-system/tempo.yaml`.
