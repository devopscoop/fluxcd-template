# AGENTS.md

Instructions for AI coding agents working in this repo. `CLAUDE.md` is a symlink to this file — edit this one, and keep the symlink intact (pre-commit's `check-symlinks`/`destroyed-symlinks` hooks will fail if it gets replaced with a regular file).

This is a FluxCD GitOps template: one git repo per cluster. There is no build and no test suite — the "build" is Flux reconciling this repo into a cluster, so correctness work is validating manifests and conventions before commit.

## How a deploy is wired together

Two layers, and both must be edited to ship an app:

1. `flux/flux-system/<app>.yaml` — a Flux `Kustomization` (`kustomize.toolkit.fluxcd.io/v1`) whose `spec.path` points at `apps/<app>`. Every one carries the same SOPS `decryption` block so it can decrypt secrets in that directory.
2. `apps/<app>/` — the actual manifests, assembled by a kustomize `Kustomization`.

`flux/flux-system/kustomization.yaml`'s `resources` list is the on/off switch: an app in `apps/` with a Kustomization in `flux/flux-system/` still does not deploy until its filename is in that list. `deploy.sh` (per-platform app lists) and `deploy_new_app.sh --deploy` both append to it with `yq ... | unique`.

Ordering between apps is expressed with `spec.dependsOn` in `flux/flux-system/*.yaml`, referencing another Kustomization by `metadata.name`. The `*-custom-resources` apps exist precisely for this: CRs that need their operator's CRDs installed first (`cert-manager-custom-resources` → `cert-manager`, `eg-custom-resources` → `eg`, `metallb-custom-resources` → `metallb`, `victoria-metrics-custom-resources` → `victoria-metrics`, `rook-ceph-cluster` → `rook-ceph`) live in a separate app so they can depend on it.

## The Helm app pattern

`apps/templates/helm/` is the boilerplate that `deploy_new_app.sh` copies; `apps/templates/kustomize/` is for plain-manifest apps and is copied by hand. A Helm app directory holds `namespace.yaml`, exactly one of `helmrepo.yaml`/`ocirepo.yaml` (the script deletes the unused one and uncomments the right line in `kustomization.yaml`), `release.yaml`, `values.yaml`, `helm_secrets.yaml`, `kustomization.yaml`, and `kustomizeconfig.yaml`.

The indirection is the part worth understanding. Helm values are *not* inlined in `HelmRelease.spec.values`. Instead `kustomization.yaml` runs `values.yaml` through `configMapGenerator` and `helm_secrets.yaml` through `secretGenerator`, both mapped to the key `values.yaml=`, and `release.yaml` pulls them in via `spec.valuesFrom`. Because the generators append a content hash to the resource names, `kustomizeconfig.yaml` supplies a `nameReference` config that teaches kustomize to rewrite `spec/valuesFrom/name` on `HelmRelease` objects — without it the HelmRelease points at names that don't exist. Keep all four names in sync when renaming an app: the generator names (`<app>-values`, `<app>-secrets`), `valuesFrom`, and the `namespace:` field.

This split is deliberate — it keeps secrets encryptable and lets you prototype the same files with plain Helm:

```shell
helm install <app> <repo>/<chart> --namespace <app> --version <ver> --values values.yaml --values <(sops -d helm_secrets.yaml)
```

Convention for `values.yaml`: strip everything you are not overriding, so the file contains no chart defaults. `apps/templates/helm/values.yaml` ships `dyff`/`vim` one-liners for diffing your file against the chart's defaults.

## Secrets

`.sops.yaml` picks the encryption rule by *filename*, so names are load-bearing:

- `*secrets.yaml` — a real Kubernetes Secret; only `data`/`stringData` are encrypted, so `apiVersion`/`kind` stay readable to the API server.
- `*helm_secrets.yaml` — Helm values that happen to be sensitive; the whole file is encrypted.

Never open an encrypted file in an editor — use `sops <file>`, which decrypts, opens, and re-encrypts. Plaintext staging files use the `.decrypted` suffix, are gitignored, and are swept up by `encrypt_secrets.sh` (via `sops --filename-override`, so the ciphertext lands under the real filename and gets the right rule). Files under `apps/templates/` are skipped. `deploy.sh` calls `encrypt_secrets.sh` during bootstrap and commits the result (including the deletions of the tracked `.decrypted` boilerplate); on an already-bootstrapped repo it only warns about stray `.decrypted` files and leaves encrypting them to `encrypt_secrets.sh`.

## Conditional marker blocks

Optional config ships commented out between `>>> <marker>` / `<<< <marker>` comment delimiters (with a leading hash on the real markers). `toggle_blocks.sh --enable <marker>` strips the leading hash-and-space (or a lone hash) from the lines between them; `--disable <marker>` puts it back. The markers stay in place, so both directions are idempotent. It only transforms files and prints what it touched — no git operations — so `deploy.sh` stages what it prints (the same split as `encrypt_secrets.sh`: the tool owns the mechanism, `deploy.sh` owns the git bookkeeping). Genuine comments inside a block must use a doubled hash (`## like this`); toggling leaves those untouched in both directions. Files under `apps/templates/` are skipped (same as `encrypt_secrets.sh`) — the boilerplate always ships with its blocks commented out. The enabling steps run on every `deploy.sh` invocation, not just bootstrap: an app added later ships with its blocks still commented, and the next run opens (and commits) them. `deploy.sh` never disables — turning a feature back off is a manual run. A block can also be toggled without a full deploy by running `./toggle_blocks.sh --enable <marker>` (or `--disable`) directly; markers can be comma-separated or repeated, and modes mixed (`./toggle_blocks.sh --enable eks --disable slack`). Current markers: `eks` (enabled when `k8s_platform=eks` — EKS-platform config: IRSA service-account annotations, AWS NLB annotations, gp3 storage classes, disabling control-plane scrapes), `karpenter` (also enabled when `k8s_platform=eks` — pins spot-intolerant workloads to on-demand nodes via `karpenter.sh/capacity-type`; a separate marker because those labels exist only on Karpenter-provisioned nodes, and the pinning can be toggled independently of the EKS config), `slack` (enabled when `slack_alerts=true` — Alertmanager → Slack, in both `apps/kube-prometheus-stack` and `apps/victoria-metrics`; see their READMEs), `dex` (never auto-enabled — toggled manually once the optional `apps/dex` issuer is deployed; in both monitoring stacks it turns on Grafana SSO via `auth.generic_oauth` plus a gateway-level OIDC `SecurityPolicy` for the Prometheus/Alertmanager/vmui routes; see `apps/dex/README.md`), `basic-auth` (kube-prometheus-stack only, and unusually it SHIPS ENABLED — the htpasswd gate on the Prometheus and Alertmanager routes; it is a marker so the dex swap can turn it off in the same commit, since Envoy Gateway honors only the oldest SecurityPolicy per route: `./toggle_blocks.sh --enable dex --disable basic-auth`), `pg-oauth` (never auto-enabled — PostgreSQL 18 native OAuth for developer logins in the CNPG database template, validated against the dex issuer; separate from `dex` because it needs a hand-built validator extension image and Kubernetes 1.35+ image volumes first — enabling it with the placeholder image reference breaks the database pods; see the block's comments and `apps/dex/README.md`), `metallb` (enabled when `k8s_platform` is not eks — MetalLB's monitoring entries in the two victoria-metrics kustomizations, gated with the app), and the per-app monitoring markers `longhorn`, `rook-ceph`, `rabbitmq`, and `coraza` (never enabled by `deploy.sh` — run `./toggle_blocks.sh --enable <app>` by hand when you enable that opt-in app, so its scrapes/rules/dashboards turn on with it; see the Monitoring section).

Gotcha, called out in `toggle_blocks.sh` itself: never write the literal opening marker (hash, space, three `>`) anywhere except a real marker. The script greps every tracked file for it and rewrites every file that matches — including prose. When writing about markers in docs, drop the leading hash, as above.

## Monitoring conventions

The default observability stack (`apps/victoria-metrics`) discovers everything through custom resources, and the repo has one pattern for wiring an app into it — three pillars per app:

- **Scrapes** are `VMPodScrape`/`VMServiceScrape` objects, never chart-native ServiceMonitors/PodMonitors: the `monitoring.coreos.com` CRDs are deliberately not installed on a pure VictoriaMetrics cluster (see apps/victoria-metrics/README.md → "CRD ownership"), so enabling a chart's toggle fails the apply. Mirror what the chart's ServiceMonitor would have selected, select on the workload's own `matchLabels` (never `helm.sh/chart`), and mind the port *name*.
- **Alert rules** are `VMRule` objects, adapted from the best upstream source with every deviation documented in the file header (`envoy-vmrule.yaml` is the style reference). Severity is a page label, not a filter — every warning and critical pages GoAlert and Slack — so upstream rule sets get pruned and re-tuned, not copied.
- **Dashboards** are `grafana_dashboard: "1"` ConfigMaps (the sidecar reads every namespace). Prefer a chart-native toggle (`apps/cnpg`); otherwise vendor the JSON from a pinned upstream URL with a provenance header and a re-sync note.

Placement: stack-agnostic apps keep their scrape/rule CRs in `apps/victoria-metrics-custom-resources` and dashboards in `apps/victoria-metrics` (CRD-ordering and either/or-stack reasons — that kustomization's header explains); apps that only exist as part of the VictoriaMetrics stack (tempo, otel-collector, victoria-logs, goalert, uptime-kuma) carry them in-app with `dependsOn: victoria-metrics` on their flux Kustomization.

Gating: monitoring for an app that isn't deployed must not apply — an empty scrape pool pages `ScrapePoolHasNoTargets`. Entries for platform-conditional and opt-in apps therefore sit in marker blocks in the two kustomization `resources` lists, enabled with the app (`eks` and `metallb` automatically by deploy.sh; `longhorn`/`rook-ceph`/`rabbitmq`/`coraza` by hand). When adding an app, add its three pillars the same way — and if it's opt-in, a marker named after it.

The kube-prometheus-stack alternative keeps its own conventions: ServiceMonitors/PrometheusRules there are legal but must carry `release: kube-prometheus-stack` or its Prometheus ignores them (`apps/loki`, `apps/alloy` are the references).

## Placeholders that deploy.sh rewrites

During bootstrap, `deploy.sh` sed-replaces `project1-dev` → `$cluster_name` and `us-east-2` → `$region` across every tracked file except itself and this file (AGENTS.md mentions the placeholders in prose), then commits and pushes. Treat both strings as reserved: don't introduce unrelated uses, and don't "fix" them to something else in template files. The script also commits and pushes on its own several times, with `git commit -n` to bypass local hooks. None of this happens on an already-bootstrapped repo — see the `deploy.sh` bullet under "Other scripts".

## Validation

`pre-commit` is the whole check suite (yamllint, markdownlint, detect-secrets, detect-private-key, symlink checks, plus a local hook).

```shell
pre-commit install                         # once
pre-commit run --all-files                 # everything
pre-commit run validate-flux --all-files   # just the Flux conventions hook
```

`.githooks/validate-flux.py` enforces two rules:

- Every `Namespace` resource needs the `kustomize.toolkit.fluxcd.io/prune: disabled` annotation, so Flux won't delete namespaces (and PVCs with them). Rationale and the counter-argument are in `arguments/prune.argdown`.
- Every `dependsOn` entry must name a Flux Kustomization that exists in `flux/flux-system/`, with no dependency cycles. This check scans that whole directory regardless of which files are staged, so it catches a dangling reference even when you only touched `apps/`.

## Other scripts

- `./deploy_new_app.sh` with no arguments prints its usage; it scaffolds a Helm app from the template, pulls the chart's default values into `values.yaml`, and optionally registers it for deploy (`--deploy`) and adds ImageRepository/ImagePolicy entries (`--image-automation`).
- `./update_flux-instance.sh [FILE]` bumps `flux/flux-system/flux-instance.yaml` to the latest Flux release and re-pins each controller image to its multi-arch digest. Set `GITHUB_TOKEN` to avoid anonymous API rate limits.
- `./deploy.sh` bootstraps a fresh template clone; it requires `variables.sh`, refuses to start on a dirty working tree, and pushes to the remote as it goes. On an already-bootstrapped repo (detected by the `fluxcd-template/bootstrapped` annotation in `flux/flux-system/flux-instance.yaml` *and* its sync URL pointing at `$git_owner/$git_repo` — both stamped by the final bootstrap commit) it skips the one-time rewrites and re-asserts cluster-side state: `flux-operator install` plus the `flux-system` githubapp and `sops-age` secrets. It still runs the marker-block uncommenting (via `toggle_blocks.sh --enable`), so apps added after bootstrap get their `eks`/`slack` blocks opened on the next run.

## Image automation and promotion

In the continuously-deployed (dev) repo, image-automation-controller commits tag updates to `# {"$imagepolicy": ...}` setter markers in `apps/*/values.yaml`. Prod-like repos sync from dev via PR and must not run the automation controllers — leave the marker comments and the `imagepolicies.yaml`/`imagerepositories.yaml`/`imageupdateautomation.yaml` files in place so syncs stay conflict-free, and just don't reference them. Full procedure in README.md → "Promoting changes to other environments".

## Package manifests

This repo ships a `Brewfile` (macOS: `brew bundle`) and a `pkglist.txt` (Arch Linux) that install every CLI tool the repo uses. Keep them in sync with the code:

- When you add a tool, script, or a new external command inside an existing script, add the package to BOTH files, with a comment noting what uses it.
- When a tool stops being used, remove it from both files.
- Verify package names before adding them: `brew info <formula>` for Homebrew, and the official repos/AUR for Arch. Names differ between ecosystems — this repo already depends on two such cases: the Go (mikefarah) `yq` is Arch's `go-yq` (Arch's `yq` is the incompatible Python implementation), and the Flux Operator CLI comes from the `controlplaneio-fluxcd/tap` Homebrew tap and the AUR `flux-operator` package. If a package is AUR-only, note that in pkglist.txt's header instructions.
- Update the "Install required packages" section in README.md if the tool list changes.

Note that the scripts need the Flux Operator CLI (`flux-operator`), not the standard `flux` CLI — the plain `flux` command appears only in commented-out lines.
