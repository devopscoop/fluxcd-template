# Dragonfly

[Dragonfly](https://d7y.io/) — peer-to-peer distribution for the images in [`apps/harbor`](../harbor/README.md), on the [upstream Helm chart](https://github.com/dragonflyoss/helm-charts) (`release.yaml`). Nodes pull Harbor's layers from each other and from a pair of seed peers instead of all from the registry, so a rollout or a Karpenter scale-out fetches each layer from Harbor roughly once. That matters more than usual here: Harbor's registry is a single pod on a single EBS volume (`apps/harbor/README.md` → "Storage and availability"), and without Dragonfly every node's pull streams through it.

Opt-in, and only useful alongside Harbor: register both (`apps/harbor/README.md` has the `yq` one-liner). Nothing to configure first — the Harbor hostname in `values.yaml` is rewritten by `replace_placeholders.sh` like every other.

## How pulls flow

1. dfinit, an init container in the per-node client DaemonSet, writes `/etc/containerd/certs.d/harbor.project1-dev.devops.coop/hosts.toml`. It names this node's dfdaemon (`http://127.0.0.1:4001`) as a mirror for pull and resolve, with Harbor as the server behind it. Only Harbor's hostname is redirected (`proxyAllRegistries: false`); the platform's own images from Docker Hub, ghcr.io, quay.io, and the rest pull exactly as before.
2. containerd sends Harbor requests to the local dfdaemon. Blob requests (and manifests by digest) go peer-to-peer: the scheduler points dfdaemon at peers that already hold the pieces, or at a seed peer, which fetches from Harbor through `eg-private` the first time. Tag lookups pass through to Harbor directly.
3. Everything fails open. With no scheduler, dfdaemon downloads from Harbor itself; with no dfdaemon, containerd falls back to the server in `hosts.toml` — Harbor — and the pull proceeds as if Dragonfly weren't installed.

Authentication passes through: containerd sends its Harbor credentials (or none, for public projects) on each request, and dfdaemon forwards them upstream.

## Without the manager

This deploys the chart's default shape: schedulers, seed peers, and per-node clients with static configuration, and no manager. The manager would need a database (MySQL or Postgres) and a Redis of its own; leaving it out leaves them out. What that gives up:

- **Preheat.** Harbor's P2P preheat policies (warm the seed peers when an image is pushed, so the first node to need it reads from inside the cluster) call the manager's API. Without it, the first pull of a new image waits on the seed peer's fetch from Harbor — streamed piece by piece, so it starts before the fetch finishes, but on the critical path of that pod start.
- **The console and REST API**, and the job system behind them (cache eviction across peers, among others). Cached content expires on the clients' own TTL and disk-pressure GC instead.
- **Multi-cluster management.** Irrelevant with one Dragonfly per cluster, as this template deploys it.

Adding the manager later is additive, with nothing to migrate — the caches are disposable: set `manager.enable: true`, point `externalPostgres` at a new CNPG cluster (from `apps/templates/cnpg-database`) and `externalRedis` at a Redis, and the schedulers register with it instead of reading the local `dynconfig.yaml`. Then add Dragonfly under Harbor's **Administration → Distributions** and create preheat policies per project. Do it when cold starts of large images measurably hurt, not before.

## Sizing

- **Per-node cache:** an emptyDir on the node's root volume, capped at 5GiB (`client.config.gc.policy.diskThreshold`). Karpenter's AL2023 nodes get a 20Gi root volume that containerd's image store shares; without the cap, Dragonfly's GC would only start at 90% of the whole disk, past the kubelet's eviction threshold. Raise it together with the EC2NodeClass's root volume, not alone.
- **Seed peers:** two, each with a 20Gi PVC (`gp3-dangerous` on EKS — a disposable cache stays out of the DLM snapshots). Size for the image working set.
- **Resources:** the chart's defaults reserve 8 CPU / 16Gi per scheduler and per seed peer; `values.yaml` starts far lower (memory req=limit, no CPU limits). Resize with krr after some real usage.

## Checking that it works

```shell
# dfinit wrote the hosts.toml (on any node, e.g. via kubectl debug node/...)
cat /etc/containerd/certs.d/harbor.project1-dev.devops.coop/hosts.toml

# a pull of a Harbor image shows up in the node's dfdaemon log
kubectl -n dragonfly logs ds/dragonfly-client -c client | grep harbor.project1-dev.devops.coop
```

`dragonfly_client_download_task_total{job="dragonfly-client-metrics"}` rising during rollouts is the same signal in VictoriaMetrics.

## Platform notes

- **EKS (AL2023):** containerd already sets `registry.config_path`, so dfinit only writes `hosts.toml`, which containerd reloads without a restart. Bottlerocket's root filesystem is read-only and its registry mirrors are set through its settings API, not files; dfinit can't configure it.
- **Elsewhere:** where `config_path` is unset, dfinit sets it in `config.toml` and the chart's privileged init container restarts containerd once per node — a brief pause in container operations on each node as the DaemonSet rolls out. The namespace is labeled `pod-security.kubernetes.io/enforce: privileged` for this and for the clients' host namespaces.
- **IPv6:** the cluster is IPv6-only, so every component sets `network.enableIPv6`. The clients run with `hostNetwork` and announce the node's IPv6 address; peers reach each other on TCP ports 4000-4006, which the node security group must allow between nodes and from pods (the common EKS module defaults open node-to-node TCP above 1024). Not yet verified on a live cluster — if peers never serve each other (every download goes back to source), check the announced addresses in the scheduler's log first.

## Monitoring

`vm.yaml` scrapes the schedulers, seed peers, and per-node clients through the chart's metrics Services, and its VMRule — adapted and pruned from the chart's own rules, every deviation listed in its header — warns when no scheduler is reachable and when the clients' or seed peers' downloads keep failing. Everything is a warning: Dragonfly fails open, so its failures slow pulls down and load Harbor rather than stopping them. No dashboard: Dragonfly's published ones hardcode a datasource uid that doesn't exist here (`vm.yaml`'s header has the detail).
