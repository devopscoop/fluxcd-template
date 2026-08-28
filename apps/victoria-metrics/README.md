# victoria-metrics

The metrics half of the VictoriaMetrics observability stack, via the [victoria-metrics-k8s-stack](https://docs.victoriametrics.com/helm/victoria-metrics-k8s-stack/) chart:

- **vmsingle** — the metrics store (single-node, 30d retention, 20Gi PVC). Remote-write endpoint: `http://vmsingle-victoria-metrics.victoria-metrics.svc.cluster.local:8428/api/v1/write`; query UI at `https://vmui.devops.coop` (under `/vmui`).
- **vmagent** — scrapes the cluster (kubelet, cAdvisor, apiserver, CoreDNS, kube-state-metrics, node-exporter, and anything selected by VM scrape CRs) and remote-writes to vmsingle.
- **vmalert** — evaluates the chart's default alerting/recording rules (the same kube-prometheus rule set kube-prometheus-stack ships, fetched by the chart's sync-job) plus any `VMRule`/`PrometheusRule` objects in the cluster.
- **Alertmanager** — 1Gi PVC for silences and the notification log; UI at `https://alertmanager.devops.coop`.
- **VictoriaMetrics operator** — reconciles the `VM*` CRs above and converts prometheus-operator objects (`ServiceMonitor`, `PodMonitor`, `PrometheusRule`, `Probe`, `ScrapeConfig`) into their VM equivalents, so charts written for prometheus-operator plug in unchanged.
- **Grafana** — at `https://grafana.devops.coop`, provisioned with datasources for VictoriaMetrics (this app), VictoriaLogs (`apps/victoria-logs`), Tempo (`apps/tempo`), and Alertmanager.

## Either/or with kube-prometheus-stack

victoria-metrics + victoria-logs + tempo + otel-collector + goalert form the **default observability stack**; kube-prometheus-stack + alloy + loki stay in the repo as the disabled alternative. Deploy one stack or the other, never both:

- **Shared hostnames** — both stacks claim `grafana.devops.coop` and `alertmanager.devops.coop`; two HTTPRoutes for one hostname would fight over traffic.
- **One Grafana** — each stack ships its own Grafana provisioned with its own datasources; running two means two dashboards UIs on the same URL.
- **CRD ownership** — the prometheus-operator CRDs (`monitoring.coreos.com`) are installed and owned by kube-prometheus-stack. This chart installs only the VictoriaMetrics CRDs (`operator.victoriametrics.com`); its operator *converts* prometheus-operator objects but does not install their CRDs. If you run this stack without kube-prometheus-stack and need charts that create `ServiceMonitor`s (most set `serviceMonitor.enabled`), install the [prometheus-operator-crds](https://artifacthub.io/packages/helm/prometheus-community/prometheus-operator-crds) chart as its own app — from this chart's perspective they are read-only inputs, so there is no conflict risk with whoever installs them, which is exactly why this app doesn't: on a cluster that already runs kube-prometheus-stack, a second owner would fight over CRD upgrades.

## Alert routing (Slack + GoAlert)

Alertmanager sends every alert to both GoAlert for paging (see apps/goalert/README.md → "Wiring Alertmanager to GoAlert") and Slack — a match-everything `goalert` sub-route with `continue: true` falls through to a match-everything `slack` sub-route. The one exception is the Watchdog alert, blackholed until a GoAlert heartbeat monitor watches for its *absence* instead.

The routing config is split across two files, and the split follows Flux's merge semantics — valuesFrom merges like `helm -f`: maps deep-merge, but lists are replaced wholesale, so each list must live entirely in one file:

- **helm_secrets.yaml** (edit with `sops helm_secrets.yaml`; before bootstrap, helm_secrets.yaml.decrypted) holds the `route.routes` and `receivers` lists — including the non-secret Slack channel and message templates — because the GoAlert webhook receiver's URL embeds an integration key, and the Slack webhook URL (`alertmanager.config.global.slack_api_url`) is secret too.
- **values.yaml** keeps only the default route receiver (`route.receiver: slack`) and `route.group_by` in its `>>> slack` marker block (uncommented by deploy.sh when `slack_alerts=true` in variables.sh).

To enable it before running deploy.sh:

1. In helm_secrets.yaml.decrypted, uncomment the `alertmanager` block (deleting the trailing `{}`), replace the placeholder `slack_api_url` with a [Slack incoming webhook](https://api.slack.com/messaging/webhooks) URL, and set your channel. The GoAlert integration-key URL can only be created once GoAlert is running, so leave its placeholder on a first bootstrap and fill it in afterwards with `sops helm_secrets.yaml` (apps/goalert/README.md walks through it).
1. Set `slack_alerts=true` in variables.sh. deploy.sh uncomments the `>>> slack` block in values.yaml and encrypts the secrets.

To enable it on an already-deployed cluster instead, uncomment the `>>> slack` block in values.yaml by hand (strip the leading `#` and space between the markers, leaving the markers in place), and edit the webhook URLs into the encrypted secrets with `sops helm_secrets.yaml`.

`group_by` is `["alertname", "namespace"]`, and getting it right matters more than it looks. Alertmanager's default is to put **every** firing alert into a single group with no common labels, and GoAlert's Alertmanager integration opens **one alert per group** — not one per Prometheus alert. With the default, six unrelated alerts (TargetDown, KubePodNotReady, TooManyLogs, …) arrived in GoAlert as one alert with nothing in it naming them, so a `TargetDown` page never appeared under its own name (ENG-1613). Grouping on alertname+namespace gives one group per distinct problem while still collapsing a single alert that fires across many pods into one page. It sits on the root route because child routes inherit it and grouping is not secret, so it stays reviewable outside sops — the trade-off being that Slack gets a message per alertname+namespace instead of one digest. To change paging alone, set `group_by` on the `goalert` sub-route in `helm_secrets.yaml` instead. If you ever want strictly one GoAlert alert per firing alert, `group_by: ["..."]` (a literal ellipsis) disables aggregation entirely, at the cost of a page per affected pod.

## Enabling this app

This stack is the default: deploy.sh's `core_app_list` registers `victoria-metrics.yaml`, `victoria-logs.yaml`, `tempo.yaml`, `otel-collector.yaml`, `goalert.yaml` (plus `cnpg.yaml` for GoAlert's database) in `flux/flux-system/kustomization.yaml` at bootstrap. To switch a cluster to the kube-prometheus-stack + alloy + loki alternative instead, swap the two groups in that resources list (or in deploy.sh's `core_app_list` before bootstrapping) — never enable both, per the either/or section above.

## Notes

- The cluster is IPv6-only, and VictoriaMetrics binaries listen and dial IPv4-only by default; every VM component in values.yaml sets `enableTCP6: "true"`. Alertmanager, Grafana, and the exporters are ordinary dual-stack Go listeners and need nothing.
- The chart's sync-job fetches the default dashboards and rules from raw.githubusercontent.com at install time, and Grafana downloads the VictoriaMetrics/VictoriaLogs datasource plugins from grafana.com at startup — both need internet egress.
- vmsingle and Alertmanager are singletons; on EKS, deploy.sh pins them to on-demand capacity (the `>>> eks` blocks in values.yaml).
