# Dragonfly

[Dragonfly](https://d7y.io/) — peer-to-peer distribution for the images in [`apps/harbor`](../harbor/README.md), both its own projects and the upstream registries it caches ([`apps/registry-mirrors`](../registry-mirrors/README.md)), on the [upstream Helm chart](https://github.com/dragonflyoss/helm-charts) (`release.yaml`). Nodes pull Harbor's layers from each other and from a pair of seed peers instead of all from the registry, so a rollout or a Karpenter scale-out fetches each layer from Harbor roughly once. That matters more than usual here: Harbor's registry is a single pod on a single EBS volume (`apps/harbor/README.md` → "Storage and availability"), and without Dragonfly every node's pull streams through it.

Opt-in, and only useful alongside Harbor and `apps/registry-mirrors`, which writes the node config that sends pulls through Dragonfly: register all three (`apps/harbor/README.md` has the `yq` one-liner). Nothing to configure first — the Harbor hostname in `values.yaml` is rewritten by `replace_placeholders.sh` like every other.

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
- **Seed peers:** two, each with a 20Gi PVC (`gp3-dangerous` on EKS — a disposable cache stays out of the DLM snapshots). Size for the image working set.
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
