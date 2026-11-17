# registry-mirrors

Makes [Harbor](../harbor/README.md) the cluster's pull-through cache: every node's containerd pulls `docker.io`, `ghcr.io`, `quay.io`, `registry.k8s.io`, and `public.ecr.aws` images (and, opt-in on EKS, the account's own private ECR) through Harbor proxy-cache projects without any workload changing its image references. `nginx:1.27` stays `nginx:1.27`; the node fetches it from `harbor.project1-dev.devops.coop/dockerhub/library/nginx:1.27` instead of Docker Hub, and Harbor fetches it from Docker Hub once.

What that buys: upstream rate limits are spent once per image rather than once per node; an upstream outage stops mattering for anything already cached (once Harbor's periodic health check marks the upstream unhealthy, it serves its cached copies); and image bytes cross the internet once instead of once per node.

Opt-in, and only meaningful with Harbor (this app's flux Kustomization `dependsOn` harbor): register both (`apps/harbor/README.md` has the `yq` one-liner).

## Two halves, one list

`registries.txt` is the single list of proxied upstreams, and both halves read it:

- **`daemonset.yaml`** (EKS only, behind the `eks` marker in `kustomization.yaml`) runs `write-hosts.sh` on every node, writing one containerd `hosts.toml` per upstream into `/etc/containerd/certs.d`. AL2023's containerd reads that directory on every pull, so there's no restart.
- **`job.yaml`** runs `configure-harbor.sh` in the `harbor` namespace, creating a Harbor registry endpoint and a proxy-cache project per upstream through Harbor's API, as the built-in admin, plus `robot$registry-mirrors`, the robot account the nodes pull as ("Node credentials" below).

Editing `registries.txt` rolls the DaemonSet and reruns the Job (their ConfigMaps carry kustomize hash suffixes), so a new upstream is one line. Removing a line removes the node config on the next rollout but leaves the Harbor endpoint and project, cached images included, for you to delete in the UI.

Only public upstreams belong on the list. Their proxy-cache projects are public, the same model as Harbor's own projects (`apps/harbor/README.md` → "Pushing and pulling"), so anything Harbor could fetch from an upstream, anything reaching `eg-private` could pull. Registries that need per-workload credentials (`registry.crowdstrike.com` for falcon-platform, the EKS add-ons' private ECR) aren't listed and pull directly, as before. A private image under a proxied host, like a private `ghcr.io` repository, still works: Harbor's anonymous fetch fails, and containerd falls through to the upstream with the pod's own `imagePullSecrets`.

The one opt-in exception is the cluster account's own private ECR, behind the `ecr-proxy` marker at the end of `registries.txt`. Harbor fetches it with harbor-core's IRSA role, and its `ecr` project is private: only the node robot can pull from it. `apps/harbor/README.md` → "Caching this account's private ECR" has how to turn it on and who can pull.

## Node credentials

Nodes pull from Harbor as `robot$registry-mirrors`, a system robot account with pull on every proxy-cache project. `configure-harbor.sh` creates it and sets its password from `node-robot-harbor.secrets.yaml`, and `write-hosts.sh` puts the same password, from `node-robot.secrets.yaml`, in every Harbor entry as a static header:

```toml
[host."https://harbor.project1-dev.devops.coop/v2/ecr".header]
  Authorization = "Basic <robot$registry-mirrors:password, base64>"
```

Harbor accepts a robot's Basic auth on the registry API, so it answers the node straight away. Without the header it answers every manifest and blob request, public projects included, with a 401 challenge. containerd's token flow then sends Harbor whatever credentials the kubelet handed over for the pull, because the kubelet doesn't tell containerd which host they're for. For an ECR image those are the kubelet's ECR token, user `AWS`. Harbor rejects them as a failed login and, in its database and LDAP auth modes, waits 1.5 seconds before answering. It then serves the pull anonymously, which works only on a public project. The robot fixes both: no failed logins, and a private `ecr` project.

The password sits in `/etc/containerd/certs.d/*/hosts.toml` on every node, readable by root only. It grants pull on the proxy-cache projects, which root on a node could already get from the upstreams: the node's IAM role pulls the account's ECR directly. Like the rest of the files, it stays behind when the app is deleted.

Without a working header (no password in `node-robot.secrets.yaml`, or one that doesn't match Harbor's), pulls get slower but don't fail. Every request is a failed login again, the public projects still serve anonymously, and the private `ecr` project refuses, so containerd moves on to ECR itself.

## How a pull flows

Each upstream's `hosts.toml` lists two places, which containerd tries in order, moving on when one refuses the connection, errors, or answers 404:

1. **Harbor's proxy-cache project**, at `https://harbor.project1-dev.devops.coop/v2/<project>`. Harbor answers blob requests with a redirect to its S3 bucket, so the bytes come from S3 (`apps/harbor/README.md` → "Storage and availability").
2. **The upstream itself** (`server`), for when Harbor is down — including while Harbor's own pods are being pulled on a node that doesn't have them.

`override_path = true` on the Harbor entry is what lets the mirror URL carry the project: containerd uses the path as the API root instead of appending `/v2`. Harbor's own hostname needs no file; earlier versions wrote one for Dragonfly, which `write-hosts.sh` now removes.

### Preferred, not enforced

Every step fails open, so "every workload pulls from Harbor" holds while Harbor is up and falls back to the upstream when it isn't. That's deliberate: Harbor, Flux, the CNI, and cert-manager are themselves pulled from these upstreams, and a node that could only pull through Harbor couldn't start Harbor. Enforcing it — dropping the `server` fallback, or blocking the upstreams at the egress — first needs every platform image pre-pulled into the node AMI or mirrored somewhere that doesn't depend on the cluster.

Flux's source-controller fetching OCI Helm charts (`oci://ghcr.io/...`) and image-reflector-controller listing tags don't go through containerd, so they still reach the upstreams directly.

## First run

1. Generate the node robot's password into both of its files (Harbor wants an upper- and a lower-case letter and a digit, hence the prefix), then run `../../encrypt_secrets.sh`:

   ```shell
   export node_robot="Rb0$(openssl rand -hex 24)"
   for f in node-robot.secrets.yaml.decrypted node-robot-harbor.secrets.yaml.decrypted; do
     yq -i '.stringData.password = strenv(node_robot)' "$f"
   done
   ```

   On a cluster that already runs this app, `sops` both encrypted files instead and put the same value in each. Until the Job's copy is set, the Job fails with "no node robot password".
2. Optionally, fill in `dockerhub-credentials.secrets.yaml.decrypted` with a Docker Hub username and a personal access token (public-repo read scope), then run `../../encrypt_secrets.sh`. Docker Hub rate-limits anonymous pulls per source IP, and all of Harbor's upstream pulls leave from the cluster's egress addresses, so a fresh cluster pulling its platform images can hit the limit. Leave both empty for anonymous pulls.
3. Let Flux reconcile. The flux Kustomization waits for harbor, then for the Job to complete:

   ```shell
   kubectl -n harbor logs job/harbor-proxy-cache        # "created proxy-cache project dockerhub -> ...", "set robot registry-mirrors's password"
   kubectl -n registry-mirrors rollout status daemonset/registry-mirrors
   ```

4. Check a node, with the password masked: `kubectl debug node/<node> -it --image=busybox -- sed 's/Basic .*/Basic …"/' /host/etc/containerd/certs.d/docker.io/hosts.toml`. Then delete any pod running a Docker Hub image and watch its project fill in Harbor's UI (**Projects → dockerhub**). Harbor-core's log shouldn't show `Login failed` for the pulls.

The Job logs in as Harbor's `admin` with the password from the chart's `harbor-core` Secret, which is the initial one from apps/harbor's `helm_secrets.yaml`. After changing admin's password in the UI, update it there too, or the next run fails with 401. A Docker Hub token rotated in the Secret alone doesn't change the Job's spec: delete the Job (`kubectl -n harbor delete job harbor-proxy-cache`) and Flux recreates it.

Rotating the node robot's password works the same way, plus a DaemonSet roll, since its Secret isn't part of the pod spec either: put the new value in both files, then `kubectl -n harbor delete job harbor-proxy-cache` and `kubectl -n registry-mirrors rollout restart daemonset/registry-mirrors`. Nodes still on the old header pull without a working one (above) until the roll reaches them.

## Storage

Harbor attaches a retention policy to each new proxy-cache project that deletes images nobody has pulled for 7 days; Harbor's weekly garbage collection (`apps/harbor/README.md` → "First run", step 6) then frees their blobs. Pulls by tag resolve against Harbor, so images in use keep counting as pulled. The cache lives in Harbor's S3 bucket, which has no size to outgrow.

## Other platforms

The DaemonSet only ships on EKS. Elsewhere, give each node the same three-host chain in the platform's own registry config:

- **Talos:** `machine.registries.mirrors.<host>.endpoints` with `overridePath: true` (Talos writes the containerd config itself; `/etc/containerd` isn't writable from a pod).
- **k0s and others:** set containerd's `registry.config_path` to `/etc/containerd/certs.d` in the node's containerd config, then enable the DaemonSet by hand (`./toggle_blocks.sh --enable eks` is too broad — uncomment its line in `kustomization.yaml` instead).

The Job half works on every platform.

## Monitoring

No scrape: neither the DaemonSet nor the Job exposes metrics. A failed Job leaves the `registry-mirrors` Kustomization not Ready, which pages as `FluxResourceNotReady` (`apps/victoria-metrics/flux-vm.yaml`); the cache's health shows in Harbor's metrics and dashboard (the proxy-cache projects are ordinary projects there).
