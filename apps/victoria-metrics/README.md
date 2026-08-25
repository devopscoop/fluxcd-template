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

## Slack alerts

Alertmanager can send every alert to a Slack channel. To enable it before running deploy.sh:

1. Create a [Slack incoming webhook](https://api.slack.com/messaging/webhooks) and put its URL in helm_secrets.yaml.decrypted: uncomment the `alertmanager` block (deleting the trailing `{}`) and replace the placeholder `slack_api_url`.
1. Set your channel in the `>>> slack` block in values.yaml.
1. Set `slack_alerts=true` in variables.sh. deploy.sh uncomments the `>>> slack` block and encrypts the webhook.

To enable it on an already-deployed cluster instead, uncomment the `>>> slack` block in values.yaml by hand (strip the leading `#` and space between the markers, leaving the markers in place), and edit your webhook URL into the encrypted secrets with `sops helm_secrets.yaml`.

## Enabling this app

This stack is the default: deploy.sh's `core_app_list` registers `victoria-metrics.yaml`, `victoria-logs.yaml`, `tempo.yaml`, `otel-collector.yaml`, `goalert.yaml` (plus `cnpg.yaml` for GoAlert's database) in `flux/flux-system/kustomization.yaml` at bootstrap. To switch a cluster to the kube-prometheus-stack + alloy + loki alternative instead, swap the two groups in that resources list (or in deploy.sh's `core_app_list` before bootstrapping) — never enable both, per the either/or section above.

## Notes

- The cluster is IPv6-only, and VictoriaMetrics binaries listen and dial IPv4-only by default; every VM component in values.yaml sets `enableTCP6: "true"`. Alertmanager, Grafana, and the exporters are ordinary dual-stack Go listeners and need nothing.
- The chart's sync-job fetches the default dashboards and rules from raw.githubusercontent.com at install time, and Grafana downloads the VictoriaMetrics/VictoriaLogs datasource plugins from grafana.com at startup — both need internet egress.
- vmsingle and Alertmanager are singletons; on EKS, deploy.sh pins them to on-demand capacity (the `>>> eks` blocks in values.yaml).
