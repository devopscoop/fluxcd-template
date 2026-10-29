# kubescape

[Kubescape](https://kubescape.io) operator — CNCF Kubernetes security
scanning, deployed standalone (no ARMO cloud account): results stay in the
cluster as custom resources.

Opt-in: not in any of deploy.sh's app lists.

## What it runs

All in the `kubescape` namespace (the chart's `ksNamespace`; it hardcodes
the namespace into many templates, so don't rename the app):

- **kubescape** — configuration/posture scanning (NSA, MITRE, CIS, ...),
  triggered daily by the `kubescape-scheduler` CronJob.
- **kubevuln** — image vulnerability matching (Grype, with Syft SBOMs).
  The `kubevuln-scheduler` CronJob triggers a daily rescan of all
  workloads.
- **node-agent** — eBPF DaemonSet: generates the SBOM for every container
  on its node (which is what triggers each vulnerability scan), and supplies
  runtime data for relevancy (which vulnerable packages are actually
  loaded), network-policy generation and the other runtime features.
- **operator** — orchestrates the above. It also serves a validating
  admission webhook on pods and RBAC objects, with `failurePolicy: Ignore`,
  so an unavailable operator doesn't block those changes.
- **storage** — aggregated API server (`spdx.softwarecomposition.kubescape.io`)
  holding scan results in SQLite on a 5Gi PVC (default StorageClass).
- **prometheus-exporter** — serves result summaries as metrics; see
  [Monitoring](#monitoring).

## Enabling

1. Register the app: add `kubescape.yaml` to `resources` in
   `flux/flux-system/kustomization.yaml`.
2. Turn on its dashboard: `./toggle_blocks.sh --enable kubescape`.
3. Commit and push.

## Viewing results

```shell
# Image vulnerabilities
kubectl get vulnerabilitymanifests -A
kubectl get vulnerabilitymanifestsummaries -A

# Posture / configuration scan results
kubectl get workloadconfigurationscans -A
kubectl get workloadconfigurationscansummaries -A
```

Results arrive gradually after install, as node-agents write SBOMs and
kubevuln scans them. Relevancy-filtered results take longer: the node-agent
has to observe each workload first (`nodeAgent.config.learningPeriod` /
`maxLearningPeriod`).

## Private registries

When kubevuln has to pull an image itself, it uses the workload's
`imagePullSecrets` (the chart's default `global.enableClusterWideSecretAccess`
lets it read them). Registries authenticated some other way — ECR via the
node's IAM role, for one — need `cloudProviderMetadata.awsIamRoleArn` (an
IRSA role for kubevuln) or credentials under
`imageScanning.privateRegistries`; put credentials in `helm_secrets.yaml`,
not `values.yaml`.

## Monitoring

- **Scrape** — `vm.yaml` scrapes the prometheus-exporter
  (`kubescape_controls_total_*`, `kubescape_vulnerabilities_total_*`, at
  cluster, namespace and workload level; workload level is turned on in
  `values.yaml`).
- **Dashboard** — the exporter repo's sample dashboard, downloaded by
  Grafana in `apps/victoria-metrics` (the `kubescape` marker block).
- **Alert rules** — none, deliberately: every alert in this stack pages,
  and vulnerability counts are a backlog, not an incident (rationale in the
  `vm.yaml` header). Component health is covered by the stack's bundled
  rules.

The node-agent's own runtime metrics (`nodeAgent.config.prometheusExporter`)
are off; add a scrape for them if you need to troubleshoot it.

## Upgrading

Bump `version` in `release.yaml`. The HelmRelease uses
`crds: CreateReplace`, so the chart's `crds/` directory is applied on every
upgrade — no manual CRD step, unlike the chart README's procedure. Then bump
the dashboard URL tag in `apps/victoria-metrics/values.yaml` to the
prometheus-exporter image tag the new chart ships
(`helm show values kubescape/kubescape-operator --version <ver> | yq .prometheusExporter.image.tag`).

## Notes

- `capabilities.autoUpgrading` stays at its `disable` default: Flux owns
  the chart version, and the upgrader CronJob would fight it.
- Without an ARMO account the operator still sends a daily report to
  `version-check.ks-services.co`, and the scanner checks for new versions.
  To opt out, set `kubescape.skipUpdateCheck: true` plus an `operator.env`
  list entry `KS_SKIP_UPDATE_CHECK: "true"` (Helm then logs a harmless
  "cannot overwrite table with non table" warning: the chart defaults
  `operator.env` to `{}` but its template ranges over a list).
  `capabilities.kubescapeOffline: enable` also stops the report, but
  additionally freezes the posture-control library at the one baked into
  the scanner image.
- Some default-on capabilities need the ARMO backend and render disabled
  here (node profiles, network-event streaming); HTTP detection additionally
  needs `capabilities.runtimeDetection`. The rendered `ks-capabilities`
  ConfigMap lists these under `capabilityWarnings`.
- `kubescape` and the `kube-*` system namespaces are excluded from scanning
  (chart value `excludeNamespaces`).
