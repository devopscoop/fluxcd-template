# opencost

[OpenCost](https://opencost.io) — CNCF cost monitoring for Kubernetes,
deployed as a metrics exporter only (no bundled Prometheus, no UI).

## How it's wired

The exporter reads cluster usage from the sibling VictoriaMetrics stack
(vmsingle's Prometheus-compatible API), prices it against cloud list/spot
rates, and serves cost metrics (`node_total_hourly_cost`, `pv_hourly_cost`,
per-container allocation, ...) on `:9003/metrics`. Two apps:

- **apps/opencost** (this app) — the exporter itself, plus `vm.yaml`, which
  scrapes the exporter back into vmsingle.
- **apps/victoria-metrics** — the official "OpenCost / Overview" Grafana
  dashboard (grafana.com 22208), pulled from grafana.com by Grafana's
  download-dashboards init container at every pod start (the
  `grafana.dashboards` entry in that app's values.yaml). It tracks the latest
  upstream revision, so there is no vendored copy to re-sync — updates land on
  the next Grafana pod restart.

The scrape ships with this app, so it applies exactly when the app does. The
dashboard entry sits in an `opencost` marker block, which deploy.sh enables
on EKS together with the app itself (the app is EKS-only: it's in
deploy.sh's eks `$app_list`).

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
