# descheduler

Rebalances pods per the policy in values.yaml (duplicates, too-many-restarts, affinity/taint violations, low node utilization). Opt-in: no deploy.sh list registers it — add `descheduler.yaml` to `flux/flux-system/kustomization.yaml`'s resources to enable it.

## Monitoring (deliberately none)

This app is intentionally unmonitored, and the gap is structural, not an oversight:

- values.yaml runs it as a **CronJob** (`kind: CronJob`, every 2 minutes). In that mode the chart renders no Service and no metrics endpoint worth having: the process serves `/metrics` only for the seconds one descheduling pass takes, then exits, and its counters reset every run. A scrape object pointed at it would flap permanently and page through the bundled `TargetDown` — strictly worse than nothing.
- No upstream alert rules or Grafana dashboard exist (kubernetes-sigs/descheduler issue #1046, open since 2023).

What still covers it: the bundled `KubeJobFailed` alert fires if a descheduler run fails outright, and its *effects* (evictions) show up in the pod-restart panels of the stack's Kubernetes dashboards.

If real monitoring is ever wanted, the prerequisite is a values change, not a scrape: `kind: Deployment` + `deschedulingInterval` + `service.enabled: true` + `leaderElection.enabled: true`. Then a `VMServiceScrape` on the `descheduler` Service (port `http-metrics`, `scheme: https`, `tlsConfig.insecureSkipVerify: true` — the endpoint serves a self-signed cert with no authn) and a rule on `increase(descheduler_pods_evicted_total{result="error"}[15m]) > 0` become worthwhile.
