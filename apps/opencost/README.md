# opencost

[OpenCost](https://opencost.io) — CNCF cost monitoring for Kubernetes,
deployed as a metrics exporter only (no bundled Prometheus, no UI).

## How it's wired

The exporter reads cluster usage from the sibling VictoriaMetrics stack
(vmsingle's Prometheus-compatible API), prices it against cloud list/spot
rates, and serves cost metrics (`node_total_hourly_cost`, `pv_hourly_cost`,
per-container allocation, ...) on `:9003/metrics`. Three pieces, three apps:

- **apps/opencost** (this app) — the exporter itself.
- **apps/victoria-metrics-custom-resources** — `opencost-vmservicescrape.yaml`
  scrapes the exporter back into vmsingle (CRs live there for the
  CRD-ordering reason in that app's kustomization.yaml).
- **apps/victoria-metrics** — `opencost-overview-dashboard.yaml`, the official
  "OpenCost / Overview" Grafana dashboard (grafana.com 22208) with a local
  "Monthly Cost — history & 30d linear forecast" panel on top: the monthly
  run-rate plus a `predict_linear()` projection 30 days out, regressed over
  the trailing 7 days. Local modifications are documented in that file's
  header.

## Pricing accuracy

- **AWS on-demand**: list prices, no credentials needed.
- **AWS spot**: accurate prices require configuring the
  [spot data feed](https://opencost.io/docs/configuration/aws/#spot-node-prices)
  (S3 bucket + IAM); until then spot nodes get a flat default price.
- Estimates cover in-cluster resources (nodes, PVs, ...) — not data
  transfer, NAT, snapshots, or the EKS control-plane fee.

## Verifying

```shell
kubectl -n opencost port-forward svc/opencost 9003:9003 &
curl -s localhost:9003/metrics | grep -m3 node_total_hourly_cost
```

Then check the "OpenCost / Overview" dashboard in Grafana — the forecast
panel needs a few days of history before `predict_linear` says anything
sensible.
