# Harbor

[Harbor](https://goharbor.io/) — a private OCI registry for this cluster's images, on the [upstream Helm chart](https://github.com/goharbor/harbor-helm) (`release.yaml`), served at <https://harbor.project1-dev.devops.coop> on the private Gateway. Image blobs live on an EBS volume, metadata in a CloudNativePG database (`db-cluster.yaml`, cert-authenticated), and nodes pull through [Dragonfly](../dragonfly/README.md)'s peer-to-peer layer, which ships as its own app. The comparison that picked this over ECR, including what it costs, is `arguments/ecr_vs_harbor_dragonfly.argdown`.

Opt-in: `deploy.sh` never registers this app. Add `harbor.yaml` — and `dragonfly.yaml`, which this README assumes — to the `resources` list in `flux/flux-system/kustomization.yaml` (`yq -i '.resources += ["harbor.yaml", "dragonfly.yaml"] | .resources |= unique' flux/flux-system/kustomization.yaml`), then follow the steps below.

## First run

1. Replace the three `CHANGEME`s in `helm_secrets.yaml.decrypted` — the chart's defaults for all of them are published — and run `../../encrypt_secrets.sh` (on a running cluster: `sops helm_secrets.yaml`):

   ```shell
   openssl rand -base64 24   # harborAdminPassword
   openssl rand -hex 8       # secretKey: exactly 16 characters, and never changed afterwards
   openssl rand -hex 16      # registry.credentials.password
   ```

2. On EKS, add the database to `local.cnpg_databases` in aws-eks-template `cluster/cnpg-backups.tf` (`{ harbor = "harbor-db" }`). The bucket name and role ARN in `db-cluster.yaml` need no edits: `replace_placeholders.sh` fills in their org, cluster, and account from `variables.sh` (set `aws_account_id` there).
3. Let Flux reconcile; the flux Kustomization `dependsOn` cert-manager, cnpg, cnpg-barman-plugin, and eg, so ordering is handled. harbor-core crash-loops until the database is up, then runs the schema migrations:

   ```shell
   kubectl -n harbor get cluster harbor-db   # wait for "Cluster in healthy state"
   kubectl -n harbor rollout status deployment/harbor-core
   kubectl -n harbor rollout status deployment/harbor-registry
   ```

4. Turn on the dashboard with the app: `./toggle_blocks.sh --enable harbor` (see Monitoring below).
5. Log in at <https://harbor.project1-dev.devops.coop> (VPN) as `admin` with the password from step 1, and change it. For SSO, point **Administration → Configuration → Authentication** at `apps/dex` as an OIDC provider — before anyone else logs in, since Harbor only switches auth modes while the database holds no users but `admin`.
6. Create the projects, pick how nodes authenticate their pulls (next section), and schedule garbage collection under **Administration → Clean Up** (weekly is plenty) alongside a tag-retention rule per project — without both, deleted and superseded images keep their space on the registry volume.

## Pushing and pulling

Image references use the gateway hostname, `harbor.project1-dev.devops.coop/<project>/<repo>:<tag>`, everywhere: CI pushes there, workloads name it in their `image:`, and Dragonfly's per-node clients intercept the node's pulls of that hostname.

**Pushes** need credentials. Give CI a robot account (**Project → Robot Accounts**) with push permission on its project, and keep its token in CI's secret store.

**Pulls** are where the choice is. Harbor itself can't accept a pod's service account identity in place of a password: native workload identity federation exists only in 8gears' commercial distribution, not in upstream Harbor. The options, in order of how much they remove:

- **Public projects behind the private route.** Mark the projects public. The route only exists on `eg-private`, so "public" means "anything that can reach the private gateway" — every node and pod in the cluster, and people on the VPN. Pulls then need no credential at all (no `imagePullSecrets`, and Flux `ImageRepository` objects need no `secretRef`), and the only robot left to rotate is CI's push account. This is the right default when one cluster serves one team or product: the network boundary is already the tenant boundary.
- **Private projects with robot pull secrets.** A pull-only robot per project, stored as a `kubernetes.io/dockerconfigjson` Secret (SOPS-encrypted, `*secrets.yaml`) in each namespace that pulls from it, referenced from `imagePullSecrets` and from the Flux `ImageRepository`'s `secretRef`. Per-project isolation, at the cost of one more static secret per namespace to rotate.
- **A workload-identity bridge.** [harbor-workload-identity-bridge](https://github.com/AetherizeGmbH/harbor-workload-identity-bridge) uses the kubelet's service-account-token credential providers (KEP-4412, beta since Kubernetes 1.34) to hand each pod's identity to a broker that returns a per-service-account robot's credentials — no pull secrets in app namespaces, with robot passwords confined to the bridge's namespace and rotated daily. It's alpha, adds a plugin to every node's kubelet config, and doesn't cover Flux's image-reflector-controller, which lists tags itself rather than through the kubelet.

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

The registry's blobs sit on one `ReadWriteOnce` gp3 volume (`persistence.persistentVolumeClaim.registry` in `values.yaml`, 20Gi), which shapes everything else:

- The registry runs one replica, in that volume's AZ. Every upgrade (`updateStrategy: Recreate`) and reschedule is a short registry outage while the volume detaches and reattaches; an AZ outage takes the registry with it until the volume is restored from a snapshot in another zone (next section).
- Every byte of every pull streams through that one pod, at the volume's provisioned throughput (gp3's 125 MiB/s baseline). Dragonfly is what makes that workable: each layer leaves Harbor roughly once per rollout, and nodes fetch it from each other.
- The volume grows online — raise the size in `values.yaml` and Flux patches the PVC — but never shrinks, and a full volume fails every push. The stack's default `KubePersistentVolumeFillingUp` alerts watch it.

On EKS every component is pinned to on-demand capacity (the `karpenter` blocks in `values.yaml`), so spot reclaims don't add to those outages.

## Backups and restore

Two halves, backed up separately:

- **Metadata** — projects, users, robots, the artifact and tag index — is in the CNPG database, with continuous WAL archiving and daily base backups to S3 (barman), so it restores to any point in the last 30 days: `runbooks/restore-cnpg-database.md`.
- **Blobs** are on the registry volume, which the default gp3 class tags `Backup=dlm`, putting it under aws-eks-template's daily EBS snapshot policy (`cluster/dlm.tf`). The Redis and Trivy volumes use `gp3-dangerous` instead: both hold nothing that isn't rebuilt on its own.

Restore them as a pair, with the database **at or slightly before** the snapshot's creation time (a barman point-in-time recovery to the snapshot's timestamp, not to latest). Harbor serves only artifacts its database knows about: blobs newer than the database are orphans the next garbage collection removes, but database rows newer than the blobs are images that list in the UI and fail to pull. Anything pushed between the snapshot and the incident has to be pushed again — rebuilt images get new digests, so re-run the release pipelines rather than expecting the old digests back.

## Database

`db-cluster.yaml` is the standard per-app CNPG cluster: three instances, synchronous replication, barman backups to S3, and client-certificate auth (`db-client-cert.yaml`) as the only login for the `harbor` role. Harbor's chart has no client-cert settings, so `release.yaml` patches the cert and the server CA into the three components that connect — harbor-core, harbor-jobservice, and harbor-exporter — with Flux `postRenderers`, and points pgx at them with `PGSSLCERT`/`PGSSLKEY`/`PGSSLROOTCERT`. The password in `values.yaml` is a placeholder the `cert` rule never asks for; it only has to be non-empty, because Harbor splices it into a keyword/value connection string. Connection pools are capped at 20 per pod (`database.maxOpenConns`) to stay inside CNPG's default `max_connections` of 100.

The certificate renews a month before it expires, but these components read it once, when they build their connection pool, so a renewal reaches them at the next restart. Chart upgrades restart them; a Harbor left un-upgraded for eleven months needs a manual `kubectl -n harbor rollout restart deployment harbor-core harbor-jobservice harbor-exporter`.

Connecting a client: `runbooks/connect-cnpg-database.md`.

## Networking

- The chart renders the HTTPRoute itself (`expose.type: route`), attached to `eg-private`'s HTTPS listener, so the registry is only reachable inside the VPC and over the VPN. TLS terminates at the gateway's wildcard certificate.
- `backendtrafficpolicy.yaml` raises the route's request timeout from Envoy's default 15 seconds to an hour; without it, any blob that takes longer than 15s to push or pull fails with a 504.
- If `apps/coraza` is enabled, it inspects `eg-private` too, and it will break pushes: its request-body handling truncates bodies over ~16KiB (`apps/coraza/README.md`), and the CRS content-type allowlist (rule `920420`) doesn't know the OCI manifest media types. Add a `per_authority_directives` entry for this hostname before enabling both.

## Monitoring

`vm.yaml` scrapes harbor-core, harbor-registry, harbor-jobservice, and harbor-exporter on their `:8001` metrics ports. Its VMRule pages when a component pushes and pulls depend on (core, database, Redis, registry) reports unhealthy or when Harbor's health can't be read at all, and warns on degraded background components and on job queues that stop draining. Both ship with the app. The dashboard (grafana.com 16003) is behind the `harbor` marker in `apps/victoria-metrics/values.yaml`: run `./toggle_blocks.sh --enable harbor` when enabling this app. The database is covered by the fleet-wide cnpg-instances scrape, and job logs (`jobservice.jobLoggers: stdout`) land in VictoriaLogs rather than in Harbor's UI.

## Not yet verified on a live cluster

This app was assembled from the chart, Harbor's source, and this repo's patterns, and has only been rendered offline (`./flux_diff.sh`). Check these first on the first deploy:

- **Cert login.** Harbor's database code uses pgx v5 (`src/common/dao/pgsql.go` at v2.15.4), which takes `PGSSLCERT`/`PGSSLKEY`/`PGSSLROOTCERT` from the environment. Confirm with the `pg_stat_ssl` query in `apps/templates/cnpg-database/README.md` that every `harbor` connection carries `/CN=harbor`.
- **IPv6.** The cluster's pods are IPv6-only. The chart's portal nginx listens on both families (`ipFamily.ipv6.enabled`, default true) and the Go components on dual-stack sockets, but whether the bundled Redis (goharbor/valkey-photon) binds `::` hasn't been checked; if harbor-core can't reach `harbor-redis`, that's the first suspect.
- **Pulls through Dragonfly.** See [`apps/dragonfly/README.md`](../dragonfly/README.md) → "Checking that it works".
