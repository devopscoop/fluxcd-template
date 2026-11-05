# Harbor

[Harbor](https://goharbor.io/) — a private OCI registry for this cluster's images, on the [upstream Helm chart](https://github.com/goharbor/harbor-helm) (`release.yaml`), served at <https://harbor.project1-dev.devops.coop> on the private Gateway. On EKS it runs highly available, with image blobs in S3 (`values-eks.yaml`); elsewhere it's a single registry on a volume. Metadata lives in a CloudNativePG database (`db-cluster.yaml`, cert-authenticated), and nodes pull through [Dragonfly](../dragonfly/README.md)'s peer-to-peer layer, which ships as its own app. Harbor is also the cluster's pull-through cache for Docker Hub, ghcr.io, quay.io, registry.k8s.io, and public.ecr.aws: [`apps/registry-mirrors`](../registry-mirrors/README.md) creates the proxy-cache projects and points every node's containerd at them, so workloads keep their image references unchanged. The comparison that picked this over ECR, including what it costs, is `arguments/ecr_vs_harbor_dragonfly.argdown`.

Opt-in: `deploy.sh` never registers this app. Add `harbor.yaml` — and `dragonfly.yaml` and `registry-mirrors.yaml`, which this README assumes — to the `resources` list in `flux/flux-system/kustomization.yaml` (`yq -i '.resources += ["harbor.yaml", "dragonfly.yaml", "registry-mirrors.yaml"] | .resources |= unique' flux/flux-system/kustomization.yaml`), then follow the steps below and `apps/registry-mirrors/README.md` → "First run".

## First run

1. Replace the three `CHANGEME`s in `helm_secrets.yaml.decrypted` — the chart's defaults for all of them are published — and run `../../encrypt_secrets.sh` (on a running cluster: `sops helm_secrets.yaml`):

   ```shell
   openssl rand -base64 24   # harborAdminPassword
   openssl rand -hex 8       # secretKey: exactly 16 characters, and never changed afterwards
   openssl rand -hex 16      # registry.credentials.password
   ```

2. On EKS, provision Harbor's two buckets and their IRSA roles in aws-eks-template, then apply: the database's (add it to `local.cnpg_databases` in `cluster/cnpg-backups.tf`, `{ harbor = "harbor-db" }`) and the registry's blobs (`enable_harbor = true` in `cluster/terraform.tfvars`, which applies `cluster/harbor.tf`). The bucket names and role ARNs in `db-cluster.yaml`, `values-eks.yaml`, and `serviceaccount-registry.yaml` need no edits: `replace_placeholders.sh` fills in their org, cluster, region, and account from `variables.sh` (set `aws_account_id` there).
3. Let Flux reconcile; the flux Kustomization `dependsOn` cert-manager, cnpg, cnpg-barman-plugin, and eg, so ordering is handled. harbor-core crash-loops until the database is up, then runs the schema migrations:

   ```shell
   kubectl -n harbor get cluster harbor-db   # wait for "Cluster in healthy state"
   kubectl -n harbor rollout status deployment/harbor-core
   kubectl -n harbor rollout status deployment/harbor-registry
   ```

4. Turn on the dashboard with the app: `./toggle_blocks.sh --enable harbor` (see Monitoring below).
5. Log in at <https://harbor.project1-dev.devops.coop> (VPN) as `admin` with the password from step 1, and change it. For SSO, point **Administration → Configuration → Authentication** at `apps/dex` as an OIDC provider — before anyone else logs in, since Harbor only switches auth modes while the database holds no users but `admin`.
6. Create the projects, pick how nodes authenticate their pulls (next section), and schedule garbage collection under **Administration → Clean Up** (weekly is plenty) alongside a tag-retention rule per project — without both, deleted and superseded images keep their space in the registry's storage.

## Pushing and pulling

Image references use the gateway hostname, `harbor.project1-dev.devops.coop/<project>/<repo>:<tag>`, everywhere: CI pushes there, workloads name it in their `image:`, and Dragonfly's per-node clients intercept the node's pulls of that hostname.

**Pushes** need credentials. Give CI a robot account (**Project → Robot Accounts**) with push permission on its project, and keep its token in CI's secret store.

**Pulls** are where the choice is. Harbor itself can't accept a pod's service account identity in place of a password: native workload identity federation exists only in 8gears' commercial distribution, not in upstream Harbor. The options, in order of how much they remove:

- **Public projects behind the private route.** Mark the projects public. The route only exists on `eg-private`, so "public" means "anything that can reach the private gateway" — every node and pod in the cluster, and people on the VPN. Pulls then need no credential at all (no `imagePullSecrets`, and Flux `ImageRepository` objects need no `secretRef`), and the only robot left to rotate is CI's push account. This is the right default when one cluster serves one team or product: the network boundary is already the tenant boundary.
- **Private projects with robot pull secrets.** A pull-only robot per project, stored as a `kubernetes.io/dockerconfigjson` Secret (SOPS-encrypted, `*secrets.yaml`) in each namespace that pulls from it, referenced from `imagePullSecrets` and from the Flux `ImageRepository`'s `secretRef`. Per-project isolation, at the cost of one more static secret per namespace to rotate. The isolation holds at Harbor, not past it: once a node has pulled a private image, Dragonfly's peers serve its layers to anything in the cluster that asks by digest, without credentials (`apps/dragonfly/README.md` → "Security").
- **A workload-identity bridge.** [harbor-workload-identity-bridge](https://github.com/AetherizeGmbH/harbor-workload-identity-bridge) uses the kubelet's service-account-token credential providers (KEP-4412, beta since Kubernetes 1.34) to hand each pod's identity to a broker that returns a per-service-account robot's credentials — no pull secrets in app namespaces, with robot passwords confined to the bridge's namespace and rotated daily. It's alpha, adds a plugin to every node's kubelet config, and doesn't cover Flux's image-reflector-controller, which lists tags itself rather than through the kubelet.

## Pull-through cache

`apps/registry-mirrors` turns this Harbor into a cache for the upstream registries the cluster pulls from. It creates one public proxy-cache project per upstream — `dockerhub`, `ghcr`, `quay`, `k8s`, `ecr-public` — and writes containerd config on every node that routes `docker.io/...`, `ghcr.io/...`, and the rest through those projects (via Dragonfly), with the upstream itself as the fallback. Nothing in the workloads changes: they keep naming `nginx:1.27` or `ghcr.io/fluxcd/source-controller`, and the node quietly fetches from `harbor.project1-dev.devops.coop/dockerhub/library/nginx:1.27` instead.

The cache is preferred, not enforced: when Harbor is down, nodes pull from the upstreams as before, which is also how Harbor's own images get pulled. Proxy-cache projects drop images unpulled for 7 days, and the weekly garbage collection reclaims their space. The full flow, the list of upstreams, and how to add one are in `apps/registry-mirrors/README.md`.

## Pushing from GitHub-hosted runners

GitHub-hosted Actions runners can't reach `eg-private`, which raises the question of moving Harbor to `eg-public`. Don't: pushing needs the whole registry API (`/v2/` plus the `/service/token` endpoint), so a public push route is a public registry, and the credential guarding it would be a static robot token stored in GitHub — upstream Harbor can't accept GitHub's OIDC tokens (workload identity federation is in 8gears' commercial distribution only). A leaked token would work from anywhere. The usual mitigations don't help here:

- **IP allowlisting** means allowing GitHub's published Actions ranges: thousands of shared Azure prefixes that every GitHub customer's workflows run from.
- **The WAF** can't front it: Coraza breaks pushes (Networking below), so the hostname would need an exemption from it anyway.
- **Patch lag** becomes an internet-facing exposure. Harbor is a large web application with a steady CVE history; on the private gateway a missed upgrade is reachable only from the VPC and the VPN.

Ways to publish from GitHub Actions without it, best first:

1. **Run the pushing jobs on in-cluster runners.** Keep GitHub Actions, but send the build-and-push jobs to Actions Runner Controller scale sets in this cluster (`runs-on: <scale-set>`), or run them on `apps/woodpecker`. Those runners are inside the VPC, so they push over the private route, and the push robot's token lives in the cluster instead of in GitHub; everything else keeps running on hosted runners. `arguments/woodpecker_vs_github_actions_arc.argdown` weighs the two.
2. **Pull instead of push.** CI pushes to GHCR with the workflow's own `GITHUB_TOKEN` (nothing long-lived in GitHub), and a pull-based replication rule in Harbor (**Administration → Replications**, a GitHub GHCR endpoint) copies the images in — nothing inbound at all. Pull replication runs on a schedule, not on push, so each release waits up to one interval before it reaches Harbor; images are stored twice, and private GHCR packages count against GitHub's billed storage.
3. **Join the runner to the VPN for the push step.** A VPN client step in the workflow (Tailscale's GitHub Action, for example, if that's the VPN in use) reaches `eg-private` directly. Viable when the VPN supports ephemeral, per-job joins without a long-lived key stored in GitHub.

If exposure is unavoidable after all, use a separate hostname on `eg-public` rather than moving this one, give that robot push rights on a single project only, rotate its token on a schedule, and treat Harbor upgrades as security patches.

## Storage and availability

Where the registry keeps its blobs (pushed images and the pull-through cache alike) decides everything else, and it differs by platform.

### EKS: highly available, on S3

`values-eks.yaml`, merged over `values.yaml` when the `eks` marker is on, stores the blobs in an S3 bucket from aws-eks-template's `cluster/harbor.tf` and runs every component on the push and pull path redundantly:

- **core, portal, and the registry run two replicas each.** They're one per node (the hostname spread is `DoNotSchedule`) and spread across zones where capacity allows (`ScheduleAnyway`), with a PodDisruptionBudget of one and rolling updates. Losing a node or a zone, an upgrade, or a Karpenter consolidation leaves a replica serving.
- **The database** is CNPG: three instances with synchronous replication and automatic failover (Database below).
- **Pulls don't stream through Harbor.** The registry answers each blob request with a redirect to a presigned S3 URL, and the node downloads from S3. There's no volume to fill or to move, and no single pod's throughput to share.
- **S3 credentials come from the pod's IRSA role, through a sidecar.** Harbor 2.15's registry can't use IRSA itself, so `release.yaml` adds an `aws-credentials` sidecar that exchanges the role for one-hour keys every 30 minutes and hands them over in a credentials file. If refreshes keep failing (its log says so every minute), the registry runs on its last keys until they expire, then fails its S3 calls, which pages through `vm.yaml`'s registry-health alert.

What stays single:

- **Redis** (the chart's internal one). From Harbor 2.15's source: harbor-core connects to Redis at startup and exits after a minute without it, so while Redis is down no core pod can start or restart. Running core pods keep answering, the registry's blob cache falls back to S3, UI users have to log in again, and queued jobs wait. With two core replicas, a Redis outage becomes an outage only if a core pod restarts during it. Its `gp3-dangerous` volume pins it to one zone. Making it redundant takes a Sentinel deployment (Harbor's external Redis supports `redis+sentinel`), which this template doesn't ship: `apps/valkey-operator` runs Valkey in Cluster mode only, and the official Valkey chart has replicas but no Sentinel.
- **jobservice, Trivy, and the exporter.** None is on the push or pull path: garbage collection, replication, retention, and scans wait out a restart.

Every component stays pinned to on-demand capacity (the `karpenter` blocks in `values.yaml`), even the replicated ones.

### Other platforms: one registry on a volume

Without the `eks` marker, the blobs sit on one `ReadWriteOnce` volume (`persistence.persistentVolumeClaim.registry` in `values.yaml`, 50Gi), which shapes everything else:

- The registry runs one replica, in that volume's zone. Every upgrade (`updateStrategy: Recreate`) and reschedule is a short registry outage while the volume detaches and reattaches; losing the zone takes the registry with it until the volume is restored from a snapshot elsewhere.
- Every byte of every pull streams through that one pod, at the volume's throughput, and with the pull-through cache that's every image the cluster runs, not just its own. Dragonfly is what makes that workable: each layer leaves Harbor roughly once per rollout, and nodes fetch it from each other.
- The volume grows online (raise the size in `values.yaml` and Flux patches the PVC) but never shrinks, and a full volume fails every push. The stack's default `KubePersistentVolumeFillingUp` alerts watch it.

For the EKS shape elsewhere, point `persistence.imageChartStorage` at an S3-compatible store (Rook-Ceph's object gateway, for example) and copy `values-eks.yaml`'s replica, spread, and PDB settings.

### Moving an existing Harbor to S3

Enabling `values-eks.yaml` on a Harbor that already stores blobs on its volume starts the registry on an empty bucket, while the database still lists every artifact. Copy the blobs first: from a pod that mounts the registry PVC and runs as the `harbor-registry` ServiceAccount, `aws s3 sync /storage/docker s3://<bucket>/docker`. Or accept the loss: re-push what's still needed, and delete the proxy-cache projects' repositories so they refill from upstream. The chart's `resourcePolicy: keep` leaves the old PVC behind either way; delete it once the bucket serves.

## Backups and restore

Two halves, backed up separately:

- **Metadata** — projects, users, robots, the artifact and tag index — is in the CNPG database, with continuous WAL archiving and daily base backups to S3 (barman), so it restores to any point in the last 30 days: `runbooks/restore-cnpg-database.md`.
- **Blobs**, on EKS, are in the versioned S3 bucket. S3's durability covers hardware and zone loss. Versioning covers deletions: an overwritten or deleted object stays recoverable for 14 days (`cluster/harbor.tf`), the window the volume's daily snapshots used to give. Elsewhere, blobs are on the registry volume; snapshot it with the platform's storage (Longhorn, Rook-Ceph). The Redis and Trivy volumes use `gp3-dangerous` on EKS: both hold nothing that isn't rebuilt on its own.

Harbor serves only artifacts its database knows about. Blobs the database doesn't reference are orphans the next garbage collection removes. Database rows whose blobs are gone are images that list in the UI and fail to pull. So restore the two halves to the same point in time:

- **On EKS**, restore the database with a barman point-in-time recovery to just before the incident. Then bring back any blobs deleted after that point by removing their delete markers:

  ```shell
  aws s3api list-object-versions --bucket <bucket> --prefix docker/registry/v2/ \
    --query "DeleteMarkers[?IsLatest && LastModified>='<restore point, ISO 8601>'].[Key,VersionId]" --output text |
    while read -r key id; do aws s3api delete-object --bucket <bucket> --key "$key" --version-id "$id"; done
  ```

  That reaches back 14 days. Blobs pushed after the restore point stay in the bucket as orphans until garbage collection removes them.
- **On a volume**, restore the database **at or slightly before** the snapshot's creation time (a barman point-in-time recovery to the snapshot's timestamp, not to latest). Anything pushed between the snapshot and the incident has to be pushed again.

Either way, rebuilt images get new digests, so re-run the release pipelines rather than expecting the old digests back.

## Database

`db-cluster.yaml` is the standard per-app CNPG cluster: three instances, synchronous replication, barman backups to S3, and client-certificate auth (`db-client-cert.yaml`) as the only login for the `harbor` role. Harbor's chart has no client-cert settings, so `release.yaml` patches the cert and the server CA into the three components that connect — harbor-core, harbor-jobservice, and harbor-exporter — with Flux `postRenderers`, and points pgx at them with `PGSSLCERT`/`PGSSLKEY`/`PGSSLROOTCERT`. The password in `values.yaml` is a placeholder the `cert` rule never asks for; it only has to be non-empty, because Harbor splices it into a keyword/value connection string. Connection pools are capped at 20 per pod (`database.maxOpenConns`) to stay inside CNPG's default `max_connections` of 100.

The certificate renews a month before it expires, but these components read it once, when they build their connection pool, so a renewal reaches them at the next restart. Chart upgrades restart them; a Harbor left un-upgraded for eleven months needs a manual `kubectl -n harbor rollout restart deployment harbor-core harbor-jobservice harbor-exporter`.

Connecting a client: `runbooks/connect-cnpg-database.md`.

## Networking

- The chart renders the HTTPRoute itself (`expose.type: route`), attached to `eg-private`'s HTTPS listener, so the registry is only reachable inside the VPC and over the VPN. TLS terminates at the gateway's wildcard certificate.
- `backendtrafficpolicy.yaml` raises the route's request timeout from Envoy's default 15 seconds to an hour; without it, any blob that takes longer than 15s to push or pull fails with a 504.
- On EKS, pulls carry no blob bytes through the gateway: the registry redirects each blob request to a presigned S3 URL, and the node fetches it from S3 directly. Without an S3 gateway endpoint in the VPC, that traffic goes through the NAT gateway and pays its per-GB processing charge. A gateway endpoint is free, and it also takes ECR's layer downloads off the NAT; aws-eks-template doesn't create one yet.
- If `apps/coraza` is enabled, it inspects `eg-private` too, and it will break pushes: its request-body handling truncates bodies over ~16KiB (`apps/coraza/README.md`), and the CRS content-type allowlist (rule `920420`) doesn't know the OCI manifest media types. Add a `per_authority_directives` entry for this hostname before enabling both.

## Monitoring

`vm.yaml` scrapes harbor-core, harbor-registry, harbor-jobservice, and harbor-exporter on their `:8001` metrics ports. Its VMRule pages when a component pushes and pulls depend on (core, database, Redis, registry) reports unhealthy or when Harbor's health can't be read at all, and warns on degraded background components and on job queues that stop draining. Both ship with the app. The dashboard (grafana.com 16003) is behind the `harbor` marker in `apps/victoria-metrics/values.yaml`: run `./toggle_blocks.sh --enable harbor` when enabling this app. The database is covered by the fleet-wide cnpg-instances scrape, and job logs (`jobservice.jobLoggers: stdout`) land in VictoriaLogs rather than in Harbor's UI.

## Not yet verified on a live cluster

This app was assembled from the chart, Harbor's source, and this repo's patterns, and has only been rendered offline (`./flux_diff.sh`). Check these first on the first deploy:

- **Cert login.** Harbor's database code uses pgx v5 (`src/common/dao/pgsql.go` at v2.15.4), which takes `PGSSLCERT`/`PGSSLKEY`/`PGSSLROOTCERT` from the environment. Confirm with the `pg_stat_ssl` query in `apps/templates/cnpg-database/README.md` that every `harbor` connection carries `/CN=harbor`.
- **IPv6.** The cluster's pods are IPv6-only. The chart's portal nginx listens on both families (`ipFamily.ipv6.enabled`, default true) and the Go components on dual-stack sockets, but whether the bundled Redis (goharbor/valkey-photon) binds `::` hasn't been checked; if harbor-core can't reach `harbor-redis`, that's the first suspect.
- **Pulls through Dragonfly.** See [`apps/dragonfly/README.md`](../dragonfly/README.md) → "Checking that it works". On EKS, also check that the seed peers follow the registry's redirect to S3.
- **S3 credentials on EKS.** Check that the `aws-credentials` sidecar logs "refreshed S3 credentials" and the registry starts after it. Then watch the registry's log around the one-hour mark: expect at most one `ExpiredToken` retry, after which it re-reads the credentials file, and no S3 errors. Others report this workaround working on Harbor 2.12 ([goharbor/harbor#16490](https://github.com/goharbor/harbor/issues/16490#issuecomment-3133783502)); it hasn't been run here.
- **Two registry replicas on S3.** Push through one pod and pull through the other (`kubectl -n harbor get pods -l component=registry`), and run a garbage collection while both are up.
