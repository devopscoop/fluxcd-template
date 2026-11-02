# registry-mirrors

Makes [Harbor](../harbor/README.md) the cluster's pull-through cache: every node's containerd pulls `docker.io`, `ghcr.io`, `quay.io`, `registry.k8s.io`, and `public.ecr.aws` images through Harbor proxy-cache projects — peer-to-peer via [Dragonfly](../dragonfly/README.md) — without any workload changing its image references. `nginx:1.27` stays `nginx:1.27`; the node fetches it from `harbor.project1-dev.devops.coop/dockerhub/library/nginx:1.27` instead of Docker Hub, and Harbor fetches it from Docker Hub once.

What that buys: upstream rate limits are spent once per image rather than once per node; an upstream outage stops mattering for anything already cached (once Harbor's periodic health check marks the upstream unhealthy, it serves its cached copies); and image bytes cross the internet once instead of once per node.

Opt-in, and only meaningful with Harbor (this app's flux Kustomization `dependsOn` harbor) and Dragonfly: register all three (`apps/harbor/README.md` has the `yq` one-liner).

## Two halves, one list

`registries.txt` is the single list of proxied upstreams, and both halves read it:

- **`daemonset.yaml`** (EKS only, behind the `eks` marker in `kustomization.yaml`) runs `write-hosts.sh` on every node, writing one containerd `hosts.toml` per upstream — plus one for Harbor's own hostname — into `/etc/containerd/certs.d`. AL2023's containerd reads that directory on every pull, so there's no restart.
- **`job.yaml`** runs `configure-harbor.sh` in the `harbor` namespace, creating a Harbor registry endpoint and a public proxy-cache project per upstream through Harbor's API, as the built-in admin.

Editing `registries.txt` rolls the DaemonSet and reruns the Job (their ConfigMaps carry kustomize hash suffixes), so a new upstream is one line. Removing a line removes the node config on the next rollout but leaves the Harbor endpoint and project, cached images included, for you to delete in the UI.

Only public upstreams belong on the list. The proxy-cache projects are public — nodes pull anonymously, the same model as Harbor's own projects (`apps/harbor/README.md` → "Pushing and pulling") — so anything Harbor could fetch from an upstream, anything reaching `eg-private` could pull. Registries that need per-workload credentials (`registry.crowdstrike.com` for falcon-platform, the EKS add-ons' private ECR) aren't listed and pull directly, as before. A private image under a proxied host, like a private `ghcr.io` repository, still works: Harbor's anonymous fetch fails, and containerd falls through to the upstream with the pod's own `imagePullSecrets`.

## How a pull flows

Each upstream's `hosts.toml` lists three places, which containerd tries in order, moving on when one refuses the connection, errors, or answers 404:

1. **This node's dfdaemon**, at `http://127.0.0.1:4001/v2/<project>` with `X-Dragonfly-Registry: https://harbor.project1-dev.devops.coop`. dfdaemon forwards to header + path, which is the Harbor proxy-cache project, and serves blobs peer-to-peer.
2. **Harbor's proxy-cache project directly**, at `https://harbor.project1-dev.devops.coop/v2/<project>`, for nodes where dfdaemon is down or not yet started.
3. **The upstream itself** (`server`), for when Harbor is down — including while Harbor's own pods, and Dragonfly's, are being pulled on a node that doesn't have them.

`override_path = true` on the first two is what lets the mirror URL carry the project: containerd uses the path as the API root instead of appending `/v2`. Dragonfly's dfinit can't write that field, which is why this app owns `certs.d` and `apps/dragonfly` runs with dfinit off. Harbor's own hostname gets a simpler file: dfdaemon first, Harbor as the server.

### Preferred, not enforced

Every step fails open, so "every workload pulls from Harbor" holds while Harbor is up and falls back to the upstream when it isn't. That's deliberate: Harbor, Dragonfly, Flux, the CNI, and cert-manager are themselves pulled from these upstreams, and a node that could only pull through Harbor couldn't start Harbor. Enforcing it — dropping the `server` fallback, or blocking the upstreams at the egress — first needs every platform image pre-pulled into the node AMI or mirrored somewhere that doesn't depend on the cluster.

Flux's source-controller fetching OCI Helm charts (`oci://ghcr.io/...`) and image-reflector-controller listing tags don't go through containerd, so they still reach the upstreams directly.

## First run

1. Optionally, fill in `dockerhub-credentials.secrets.yaml.decrypted` with a Docker Hub username and a personal access token (public-repo read scope), then run `../../encrypt_secrets.sh`. Docker Hub rate-limits anonymous pulls per source IP, and all of Harbor's upstream pulls leave from the cluster's egress addresses, so a fresh cluster pulling its platform images can hit the limit. Leave both empty for anonymous pulls.
2. Let Flux reconcile. The flux Kustomization waits for harbor, then for the Job to complete:

   ```shell
   kubectl -n harbor logs job/harbor-proxy-cache        # "created proxy-cache project dockerhub -> ..."
   kubectl -n registry-mirrors rollout status daemonset/registry-mirrors
   ```

3. Check a node: `kubectl debug node/<node> -it --image=busybox -- cat /host/etc/containerd/certs.d/docker.io/hosts.toml`. Then delete any pod running a Docker Hub image and watch its project fill in Harbor's UI (**Projects → dockerhub**).

The Job logs in as Harbor's `admin` with the password from the chart's `harbor-core` Secret, which is the initial one from apps/harbor's `helm_secrets.yaml`. After changing admin's password in the UI, update it there too, or the next run fails with 401. A Docker Hub token rotated in the Secret alone doesn't change the Job's spec: delete the Job (`kubectl -n harbor delete job harbor-proxy-cache`) and Flux recreates it.

## Storage

Harbor attaches a retention policy to each new proxy-cache project that deletes images nobody has pulled for 7 days; Harbor's weekly garbage collection (`apps/harbor/README.md` → "First run", step 6) then frees their blobs. Pulls through Dragonfly still resolve tags against Harbor, so images in use keep counting as pulled. The registry volume is sized for this (`apps/harbor/values.yaml`, 50Gi); `KubePersistentVolumeFillingUp` warns before it fills, and a full volume turns every cache miss into a fallback to the upstream.

## Other platforms

The DaemonSet only ships on EKS. Elsewhere, give each node the same three-host chain in the platform's own registry config:

- **Talos:** `machine.registries.mirrors.<host>.endpoints` with `overridePath: true` (Talos writes the containerd config itself; `/etc/containerd` isn't writable from a pod).
- **k0s and others:** set containerd's `registry.config_path` to `/etc/containerd/certs.d` in the node's containerd config, then enable the DaemonSet by hand (`./toggle_blocks.sh --enable eks` is too broad — uncomment its line in `kustomization.yaml` instead).

The Job half works on every platform.

## Monitoring

No scrape: neither the DaemonSet nor the Job exposes metrics. A failed Job leaves the `registry-mirrors` Kustomization not Ready, which pages as `FluxResourceNotReady` (`apps/victoria-metrics/flux-vm.yaml`); the cache's health shows in Harbor's metrics and dashboard (the proxy-cache projects are ordinary projects there) and in Dragonfly's download success rates.
