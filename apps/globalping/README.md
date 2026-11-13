# globalping

A [Globalping](https://globalping.io) probe: one node in jsDelivr's community network that runs ping, traceroute, mtr, DNS and HTTP measurements on request from anywhere in the world. Hosting a probe and adopting it into your Globalping account earns that account measurement credits and higher rate limits. The probe only dials out, over a websocket to `api.globalping.io`, so it opens no ports and serves nothing in the cluster.

Upstream ships the probe as a container meant for `docker run` on a VPS and publishes no Helm chart, so this app runs the image on the generic [devopscoop app chart](https://github.com/devopscoop/charts/tree/main/devopscoop/app), the same as `apps/goalert` and `apps/radicle`.

## Before you deploy

Put the account's adoption token in `helm_secrets.yaml.decrypted` and encrypt it with `../../encrypt_secrets.sh`. The token is the `GP_ADOPTION_TOKEN` value in the `docker run` command the [Globalping dashboard](https://dash.globalping.io) generates. Without a valid token the probe still runs, but it stays unadopted and earns nothing.

Globalping's limits shape how the probe is deployed:

- **One probe per public IPv4 address or IPv6 /64.** Every pod in the cluster egresses through the same NAT gateways and subnets, so this runs exactly one replica, with a `Recreate` strategy so an upgrade never overlaps two. The probe's IPv4 address is the NAT gateway of whichever availability zone its node is in. If the pod moves to another zone, the address changes; the token re-adopts the probe automatically.
- **At most two adopted probes per ASN and city.** A dev and a prod cluster in the same AWS region use both slots. A third probe there won't adopt.

## Networking

Upstream's `docker run` uses `--network host` to keep overlay and service-mesh networking from skewing latency. That reason mostly doesn't apply here, so the probe runs on the regular pod network:

- The EKS VPC CNI routes pod traffic natively on VPC addresses, without an overlay, and the template ships no service mesh.
- The chart has no `hostNetwork` setting.
- Host networking would weaken isolation. The probe runs as root. On the host network it would reach the instance metadata service, and through it the node's IAM role credentials. It would also listen on port 7201 on the node for an hour after each start, for its adoption server.

Two things do differ from the VPS setup:

- **IPv4 measurements take an extra SNAT hop.** The EKS clusters are IPv6-only on the pod network, so IPv4 traffic leaves through the node's SNAT before it reaches the NAT gateway. Measurements still work; traceroute and mtr may show one extra first hop.
- **DNS goes through CoreDNS.** The pod's `resolv.conf` points at cluster DNS with search domains and `ndots:5`. DNS measurements that don't name a resolver query CoreDNS rather than the VPC resolver, and resolving a target hostname may try the search-domain expansions first.

If that accuracy ever matters, the fix is `dnsPolicy: Default`, which gives the pod the node's resolver. The chart doesn't expose `dnsPolicy` either, so that means a chart change first.

## Updates

Upstream's probe updates itself, and nothing in its configuration turns that off:

- **At every container start**, the entrypoint fetches the latest release from jsDelivr and swaps it in for `/app`.
- **While running**, the probe checks for a new release every 5–10 minutes and exits so that the entrypoint can install it.
- **Runtime and entrypoint:** when a release wants a different Node.js version, the probe installs it with nvm; when a release ships a new entrypoint, the probe rewrites `/entrypoint.sh`.
- **A leftover fallback script** downloads and unpacks Debian packages over plain HTTP if `unbuffer` is missing. It isn't missing from the image, but the script still runs at every start.

All of that is third-party code reaching the cluster without review, so this app blocks it. The root filesystem is read-only and no writable volume is mounted, not even `/tmp`, so every one of those writes fails and the probe carries on with the code in the pinned image. The `UPDATE_INTERVAL` override in `values.yaml` pushes the in-process check past the probe's weekly restart. Without it, every upstream release would start a restart loop every few minutes until the digest is bumped.

This deviates from upstream. Globalping's terms say not to modify the probe's code or behavior. The code is untouched, but blocking its updates changes how it behaves.

**Falling too far behind fails loudly.** The API refuses probes older than its minimum version: 0.52.0 at the time of writing, two releases behind the latest. An outdated probe logs `Detected an outdated probe. Restarting.` and exits on every connection attempt, so the pod crash-loops and `KubePodCrashLooping` pages. Bump the digest then, or sooner.

To upgrade, read what changed in the [release](https://github.com/jsdelivr/globalping-probe/releases), since reviewing it is the point of pinning, then look up the new version's digest:

```shell
v=0.54.0
tok=$(curl -s "https://auth.docker.io/token?service=registry.docker.io&scope=repository:globalping/globalping-probe:pull" | jq -r .token)
curl -sI -H "Authorization: Bearer $tok" -H "Accept: application/vnd.oci.image.index.v1+json" \
  "https://registry-1.docker.io/v2/globalping/globalping-probe/manifests/$v" | grep -i docker-content-digest
```

Set `image.tag` to `<version>@<digest>`.

## Monitoring

None of the three usual pillars applies. The probe exposes no metrics, so there's nothing to scrape, and there's no upstream dashboard. A probe that's down, including one too outdated to connect, shows up as a crash-looping pod, which the victoria-metrics stack's default kube-state-metrics rules already page on. So this app has no `vm.yaml`, and its flux Kustomization doesn't depend on `victoria-metrics-crds`.

## Checking on it

```shell
kubectl -n globalping logs deploy/globalping
```

A healthy start logs `Starting probe version …`, then the connection and adoption result. The probe also runs an hourly ICMP and TCP self-test, and the API sends no measurements to a probe that fails it, so watch the log for that test's result. Adopted probes appear in the [Globalping dashboard](https://dash.globalping.io).

Each start also logs errors from the blocked self-updates, and they're expected:

- `update-ca-certificates` fails to write. The image's CA bundle is still in place.
- When a newer release exists, the entrypoint fails to download it to `/tmp` and logs `All methods failed. Exiting.` Despite the wording, it then starts the probe.
- `Failed to write the new UUID`. The probe takes a new UUID at every start. Adoption is keyed by IP address, so the probe stays adopted.
- `failed to save` probe settings, if the API pushes any. They're kept in memory.

The probe restarts itself every 7–8 days. Any other restart is worth a look.
