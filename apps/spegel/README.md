# spegel

[Spegel](https://spegel.dev) is a stateless, cluster-local OCI registry
mirror. A DaemonSet points each node's containerd at it through
`/etc/containerd/certs.d/<registry>/hosts.toml`, and when a node pulls an
image layer another node already has, it fetches it from that peer instead of
the upstream registry. A Karpenter scale-up then pulls each image from
upstream once rather than once per node, which saves time and keeps nodes
under registry rate limits (Docker Hub, ECR Public). Anything no peer has goes
to the upstream registry as before, so a broken mirror costs speed, not
availability.

It mirrors container images only. Flux's chart fetches (HelmRepository,
OCIRepository) are made by source-controller, not containerd, and don't go
through it.

## Enabling (opt-in)

No deploy.sh list registers it. Read "Security" below first: none of its
mitigations are configured here. The DaemonSet runs on every node, managed
node groups and Karpenter alike (the chart tolerates every taint, including
the managed nodes' `CriticalAddonsOnly`), and every node needs containerd
settings the EKS AL2023 AMI doesn't ship with:
`discard_unpacked_layers = false` and a single-entry registry `config_path`.
Each node source gets them from its own repo, so enabling Spegel takes two
steps, in this order:

1. In aws-eks-template, set `enable_spegel = true` and apply it. That adds
   the NodeConfig to the managed node groups' launch template, and the apply
   replaces every managed node.
2. Here, in one commit: run `./toggle_blocks.sh --enable spegel`, which
   uncomments the same NodeConfig as `userData` in
   `apps/karpenter-custom-resources/ec2nodeclass.yaml`, and add `spegel.yaml`
   to `flux/flux-system/kustomization.yaml`'s `resources`.

Changing the EC2NodeClass's `userData` drifts every Karpenter node, so
Karpenter replaces the whole fleet at the pace `nodepool.yaml`'s disruption
budget allows. Until a node is replaced, its Spegel pod runs against the old
containerd config. On the AMI's containerd 2.2 that is harmless (it has no
layers to serve); see "Containerd requirements" for 2.4+.

## Containerd requirements

Spegel 0.8.0 checks containerd at startup and exits if the check fails. It
needs containerd 2.2 or later, and on 2.4+ it also requires
`discard_unpacked_layers` off and a single-entry registry `config_path`. The
AL2023 AMI (`v20260930`: containerd 2.2.7) defaults to
`discard_unpacked_layers = true` and
`config_path = "/etc/containerd/certs.d:/etc/docker/certs.d"`, so:

- On containerd 2.2–2.3 the config check doesn't run, and a node without the
  nodeadm config (a managed node with `enable_spegel` off, or a Karpenter
  node not yet replaced) runs Spegel without serving anything. Verify after
  enabling (below).
- Once an AMI ships containerd 2.4+, a node without it crash-loops Spegel.

Spegel's [compatibility notes](https://spegel.dev/docs/getting-started/#compatibility)
cover the equivalent host config for k0s and Talos, plus their `values.yaml`
overrides (socket, content-store and certs.d paths). Neither is wired up here.

## Security

None of the mitigations below are set in `values.yaml` yet. Decide on them
before enabling Spegel on a cluster that pulls private images.

- **Image pull secrets stop protecting private images.** Once any node has
  pulled a private image (`registry.crowdstrike.com/falcon-sensor`,
  `ghcr.io/devopscoop/...`), two paths get it without the registry's
  credentials:
  - A pod on another node can run it without an `imagePullSecret`, because
    containerd gets it from a peer. `spegel.registryFilters` matching the
    private registries closes this: Spegel then neither advertises nor
    resolves those references, so containerd goes to the registry with the
    pod's credentials.
  - Spegel's registry has no authentication by default. Anything that reaches
    port 30020 on a node (the registry NodePort) or 5000 on a Spegel pod can
    fetch any layer that node stores, given its digest. Filters don't stop
    this, because Spegel serves a locally stored layer requested under any
    unfiltered image name. Digests aren't secret: pod status shows them to
    anyone who can read pods, including `cluster-viewers`.
    `basicAuthSecretName` closes this; the credentials then sit in each
    node's `hosts.toml` for containerd to use.
- **A rogue peer can swap images pulled by tag.** Nothing authenticates peers
  on Spegel's router port (5001). A pod that can reach it can join the
  peer-to-peer network and answer tag lookups, substituting a different
  image for tag-based pulls across the cluster. Pulls pinned by digest are
  safe, because containerd verifies digests. The chart's
  `networkPolicy.enabled` limits the router port to Spegel pods, but does
  nothing unless the VPC CNI's network policy enforcement is on, which
  aws-eks-template doesn't do. `spegel.resolveTags: false` also closes it,
  but then tags resolve upstream, so tag-based pulls lose outage protection.
- **Re-pushed tags go stale.** A node resolves a tag to whatever digest its
  peers hold. If a vendor re-pushes a tag with a security fix, new pulls keep
  getting the old image while any node has it. Filter mutable tags
  (`".*:latest$"` is the chart's own example), and prefer immutable tags or
  digests.
- **Spegel is root-equivalent on every node.** It mounts containerd's socket
  and writes containerd's mirror config. Whoever can change its DaemonSet, or
  create pods in the `spegel` namespace (labelled `privileged`), has root on
  every node, and Spegel's image is in that trust path. The chart pins the
  image by digest; keep the namespace's RBAC tight.
- **Layers move between nodes over plain HTTP.** The traffic stays inside the
  VPC, but it matters if private image contents fall under SOC 2
  encryption-in-transit requirements.

## Verifying

Spegel's getting-started guide has a two-pod test that proves a pull was
served by a peer: <https://spegel.dev/docs/getting-started/#verify-deployment>.
Once it is running, `sum by (cache) (rate(spegel_mirror_requests_total[1h]))`
in vmui shows how many mirror requests peers answered (`hit`) versus passed
upstream (`miss`).

## Monitoring

`vm.yaml` scrapes the metrics Service. No alert rules or dashboard ship with
it; the file header explains why.
