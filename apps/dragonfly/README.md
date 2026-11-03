# Dragonfly

[Dragonfly](https://d7y.io/) — peer-to-peer distribution for the images in [`apps/harbor`](../harbor/README.md), both its own projects and the upstream registries it caches ([`apps/registry-mirrors`](../registry-mirrors/README.md)), on the [upstream Helm chart](https://github.com/dragonflyoss/helm-charts) (`release.yaml`). Nodes pull Harbor's layers from each other and from a seed peer instead of all from the registry, so a rollout or a Karpenter scale-out fetches each layer from Harbor roughly once. That matters more than usual here: Harbor's registry is a single pod on a single EBS volume (`apps/harbor/README.md` → "Storage and availability"), and without Dragonfly every node's pull streams through it.

Opt-in, and only useful alongside Harbor and `apps/registry-mirrors`, which writes the node config that sends pulls through Dragonfly: register all three (`apps/harbor/README.md` has the `yq` one-liner). Nothing to configure first — the Harbor hostname in `values.yaml` is rewritten by `replace_placeholders.sh` like every other.

## When it pays off

Dragonfly earns its keep in throughput: it keeps a burst of pulls from queueing on Harbor's one registry pod. It saves almost nothing in transfer. Work out both before enabling it; on a cluster of tens of nodes pulling images of tens to hundreds of megabytes, it usually costs more than it saves.

**What it costs.** Karpenter packs nodes by requests, so the reservations are the cost. This app's defaults, at roughly on-demand list prices in us-east (about $0.032 per vCPU-hour and $0.0042 per GiB-hour across the c/m/r families, $0.08 per GB-month for gp3):

| Component | Requests | ≈ $/month |
| --- | --- | --- |
| Scheduler (1) | 25m CPU, 256Mi | 1.35 |
| Seed peer (1) | 50m CPU, 1Gi, 20Gi gp3 PVC | 5.80 |
| Client (one per node) | 50m CPU, 512Mi | 2.70 per node |

That's about **$7 + $2.70 per node** a month: $34 at 10 nodes, $140 at 50, $280 at 100. Spot capacity lowers the compute part. The real bill is lumpier than this: the per-node reservations either fit into slack on existing nodes or push Karpenter to add one.

**What it saves in transfer.**

- **Internet egress and NAT processing: nothing.** Harbor's proxy-cache projects (`apps/registry-mirrors`) fetch each upstream image once, with or without Dragonfly. Dragonfly only changes how bytes travel from Harbor to the nodes, inside the VPC.
- **Cross-zone transfer ($0.01 per GB each way): nothing, as deployed.** The scheduler prefers parents in the child's own IDC and location (weights 0.2 and 0.1, against 0.6 for load, in its default evaluator). But the chart sets `client.config.host.idc`/`location` once for the whole DaemonSet, so every node announces the same values and parents are picked without regard to zone. Labeling each node with its zone would take a DaemonSet per zone or a templated config. Even then, the best case removes the cross-zone share of Harbor-to-node traffic: about two thirds of it across three zones, or $0.013 per GB pulled. Break-even is then about **500 GB + 200 GB per node of pulls a month**, all of it bytes a same-zone peer could have served. That's 7 GB per node per day, which few clusters come near.

**What it buys in throughput.** Every byte a node pulls from Harbor streams through one registry pod reading one gp3 volume (`apps/harbor/README.md` → "Storage and availability"). A burst of B bytes, that is, nodes starting at once × image bytes they don't already have, adds roughly B divided by the volume's throughput to the last pod's start. Raising the volume's throughput is the simpler fix, and from about a dozen nodes the cheaper one too:

| Registry volume throughput | Extra $/month | Burst served per minute of added delay |
| --- | --- | --- |
| 125 MiB/s (gp3 baseline) | 0 | ~7 GiB |
| 1,000 MiB/s (with 4,000 IOPS) | ~40 | ~59 GiB |
| 2,000 MiB/s (gp3 maximum, 8,000 IOPS) | ~100 | ~117 GiB |

Provision it with the EBS CSI driver's `throughput` and `iops` parameters: a dedicated StorageClass for a new volume, or a VolumeAttributesClass for the existing one. The registry's node has to sustain the rate too; the EBS and network baselines of small instances sit well below 1,000 MiB/s, and every byte also crosses the gateway.

- 20 nodes × 500 MB = 10 GB: about 75 s at the baseline, 10 s at 1,000 MiB/s. Raise the volume's throughput; skip Dragonfly.
- 50 GPU nodes × 5 GB = 250 GB: about 32 min at the baseline, 4 min at 1,000 MiB/s, 2 min at 2,000 MiB/s. This is Dragonfly's case: Harbor serves each layer roughly once (about 40 s for 5 GB at the baseline) and the peers serve the rest.

So the break-even is a burst bigger than a provisioned volume serves in the delay you'll accept: past about 60 GiB per minute of tolerated delay at 1,000 MiB/s, or 117 GiB at the gp3 maximum. In practice that means multi-gigabyte images on dozens of nodes at once. If Harbor stores blobs in S3 with redirects on, S3 serves the bytes, so there's no single-pod ceiling and no cross-zone charge (given an S3 gateway endpoint). That leaves Dragonfly's case to much larger fleets.

To measure, `kubectl get events -A --field-selector reason=Pulled` shows each recent pull's image size and duration. The size is the whole image, an upper bound on the bytes actually fetched. Pull times that grow with the number of nodes starting together mean the origin is the bottleneck. For scale, one 11-node cluster measured while this was written ran about 80 images: a median of 37 MB compressed, 120 MB per new node through Harbor, and roughly 300 GB of pulls a month. That's about a ninth of its transfer break-even (2.7 TB a month), and its worst realistic burst, every app image rolled out to every node at once (4.4 GB), takes about 35 s at the gp3 baseline.

## How pulls flow

1. `apps/registry-mirrors` writes a containerd `hosts.toml` on every node for Harbor's hostname and for each upstream Harbor proxies (`docker.io`, `ghcr.io`, ...). Each names this node's dfdaemon (`http://127.0.0.1:4001`) first, with Harbor in the `X-Dragonfly-Registry` header — for an upstream, at the path of its Harbor proxy-cache project. The chart's own dfinit, which would otherwise write these files, is off: it can't express that path (`override_path`). Registries not on that app's list pull exactly as before.
2. containerd sends those requests to the local dfdaemon, which forwards to the header's registry plus the request path. Blob requests (and manifests by digest) go peer-to-peer: the scheduler points dfdaemon at peers that already hold the pieces, or at a seed peer, which fetches from Harbor through `eg-private` the first time (and Harbor, for a proxied upstream, from the upstream). Tag lookups pass through to Harbor directly.
3. Everything fails open. With no scheduler, dfdaemon downloads from Harbor itself; with no dfdaemon, containerd moves on to Harbor directly, and with no Harbor, to the upstream — `apps/registry-mirrors/README.md` → "How a pull flows".

Authentication passes through: containerd sends its Harbor credentials (or none, for public projects) on each request, and dfdaemon forwards them upstream.

## Without the manager

This deploys the chart's default shape: schedulers, seed peers, and per-node clients with static configuration, and no manager. The manager would need a database (MySQL or Postgres) and a Redis of its own; leaving it out leaves them out. What that gives up:

- **Preheat.** Harbor's P2P preheat policies (warm the seed peers when an image is pushed, so the first node to need it reads from inside the cluster) call the manager's API. Without it, the first pull of a new image waits on the seed peer's fetch from Harbor — streamed piece by piece, so it starts before the fetch finishes, but on the critical path of that pod start.
- **The console and REST API**, and the job system behind them (cache eviction across peers, among others). Cached content expires on the clients' own TTL and disk-pressure GC instead.
- **Multi-cluster management.** Irrelevant with one Dragonfly per cluster, as this template deploys it.

Adding the manager later is additive, with nothing to migrate — the caches are disposable: set `manager.enable: true`, point `externalPostgres` at a new CNPG cluster (from `apps/templates/cnpg-database`) and `externalRedis` at a Redis, and the schedulers register with it instead of reading the local `dynconfig.yaml`. Then add Dragonfly under Harbor's **Administration → Distributions** and create preheat policies per project. Do it when cold starts of large images measurably hurt, not before.

## Sizing

- **Per-node cache:** an emptyDir on the node's root volume, capped at 5GiB (`client.config.gc.policy.diskThreshold`). Karpenter's AL2023 nodes get a 20Gi root volume that containerd's image store shares; without the cap, Dragonfly's GC would only start at 90% of the whole disk, past the kubelet's eviction threshold. Raise it together with the EC2NodeClass's root volume, not alone.
- **Scheduler and seed peer:** one of each. Both fail open, so a second replica only shortens the stretches when pulls go straight to Harbor (`values.yaml` has the detail); run two of each once you're past the throughput break-even above. The seed peer has a 20Gi PVC (`gp3-dangerous` on EKS — a disposable cache stays out of the DLM snapshots). Size it for the image working set.
- **Resources:** the chart's defaults reserve 8 CPU / 16Gi per scheduler and per seed peer; `values.yaml` starts far lower (memory req=limit, no CPU limits). Resize with krr after some real usage.

## Checking that it works

```shell
# apps/registry-mirrors wrote the hosts.toml files (on any node, e.g. via kubectl debug node/...)
cat /etc/containerd/certs.d/docker.io/hosts.toml

# a pull of a Harbor image shows up in the node's dfdaemon log
kubectl -n dragonfly logs ds/dragonfly-client -c client | grep harbor.project1-dev.devops.coop
```

`dragonfly_client_download_task_total{job="dragonfly-client-metrics"}` rising during rollouts is the same signal in VictoriaMetrics.

## Platform notes

- **Node config:** comes from `apps/registry-mirrors`, which ships its node DaemonSet on EKS only; its README has the Talos and k0s equivalents. Bottlerocket's root filesystem is read-only and its registry mirrors are set through its settings API, so neither that app nor dfinit can configure it.
- **Pod Security:** the namespace is labeled `pod-security.kubernetes.io/enforce: privileged` for the clients' host network, PID, and IPC namespaces.
- **IPv6:** the cluster is IPv6-only, so every component sets `network.enableIPv6`. The clients run with `hostNetwork` and announce the node's IPv6 address; peers reach each other on TCP ports 4000-4006, which the node security group must allow between nodes and from pods (the common EKS module defaults open node-to-node TCP above 1024). Not yet verified on a live cluster — if peers never serve each other (every download goes back to source), check the announced addresses in the scheduler's log first.

## Security

- **Tampering is caught downstream, not here.** Peers serve only digest-addressed content (layers and manifests by digest), and containerd checks every layer against the digest in its manifest, so a malicious or corrupted peer can fail a pull but not change what runs. Tag lookups bypass the peer network and go to Harbor, which is where tag-level trust sits (`apps/harbor/README.md`).
- **The node proxy listens on loopback only** (`client.config.proxy.server.ip: 127.0.0.1`, and the same on the seed peers). It is a general-purpose HTTP proxy, so on the host network its default of every interface would let any pod fetch arbitrary URLs from the node's address. Only the node's own containerd needs it.
- **No mTLS, deliberately.** Dragonfly supports mTLS on its gRPC traffic (clients to schedulers, peer coordination on port 4000), but not on the storage servers (4005/4006) that carry the layer bytes, so it would leave the data plane as it is. And it verifies each server certificate against the IP address it dialed, so every scheduler pod, seed peer, and node would need a certificate for its own current IP — which Karpenter nodes and pod restarts keep changing, beyond what cert-manager's static Certificates can express. What it would buy — keeping rogue pods from joining as peers — is a denial-of-service fix, given the digest checks above.
- **Cached layers are readable in-cluster without credentials.** The storage servers serve any cached piece to whoever asks for it by task, and task IDs derive from layer digests, so a pod that knows a private image's layer digests can read those layers from a peer without a pull secret — the same trade-off as Spegel. It's acceptable under one tenant per cluster; clusters shared between tenants need network-level isolation of ports 4000-4006 instead.

## Monitoring

`vm.yaml` scrapes the schedulers, seed peers, and per-node clients through the chart's metrics Services, and its VMRule — adapted and pruned from the chart's own rules, every deviation listed in its header — warns when no scheduler is reachable and when the clients' or seed peers' downloads keep failing. Everything is a warning: Dragonfly fails open, so its failures slow pulls down and load Harbor rather than stopping them. No dashboard: Dragonfly's published ones hardcode a datasource uid that doesn't exist here (`vm.yaml`'s header has the detail).
