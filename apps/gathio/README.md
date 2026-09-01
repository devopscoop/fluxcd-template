# Gathio

[Gathio](https://github.com/lowercasename/gathio) — self-destructing, shareable,
no-registration event pages. Also the reference example for the in-house
`devopscoop/charts/app` chart in this repo.

Scaffolded with:

```shell
./deploy_new_app.sh gathio devopscoop oci://registry.gitlab.com/devopscoop/charts app 0.11.1
```

## How it is wired

This directory holds **two** HelmReleases: gathio and the MongoDB it needs. The
`mongodb.*` files are the second release's half of the same four-file pattern
(source, release, values, helm secrets), and gathio's HelmRelease `dependsOn`
the mongodb one. The dot in `mongodb.helm_secrets.yaml` is load-bearing —
`.sops.yaml` picks its rule by filename, and `mongodb-helm_secrets.yaml` would
match no rule at all.

- StatefulSet, because user-uploaded event images are written to disk at
  `/app/public/events`. That path is the `events` volumeClaimTemplate (5Gi).
- `config.yaml` holds the `config` ConfigMap, mounted over
  `/app/config/config.toml` — the only config file gathio reads (it looks for
  `./config/config.toml` relative to its `/app` workdir).
- Any string in `config.toml` can interpolate a `GATHIO_`-prefixed environment
  variable as `${GATHIO_FOO}`. The MongoDB URL is set that way, from
  `envSecret.GATHIO_MONGODB_URL` in `helm_secrets.yaml`.
- Image is digest-pinned to 1.6.5, written as `<version>@sha256:<digest>` like
  `apps/radicle` (upstream publishes `linux/amd64`, `linux/arm/v7` and
  `linux/arm64`). Upstream re-pushes release tags, so re-derive the digest from
  the tag when bumping rather than trusting an old one.

## Before this can be enabled

1. **MongoDB.** It deploys from this directory alongside the app — see
   [MongoDB](#mongodb) below. Fill in the credentials on both sides
   (`userDatabase` in `mongodb.helm_secrets.yaml`, `GATHIO_MONGODB_URL` in
   `helm_secrets.yaml`) and run `./encrypt_secrets.sh`.
1. **Gateway listener.** `values.yaml` attaches an HTTPRoute for
   `gathio.project1-dev.devops.coop`, but `eg-public` ships with only its `http`
   listener. Add an HTTPS listener with `certificateRefs` →
   `gathio-project1-dev-devops-coop-tls` to
   `apps/eg-custom-resources/gateway-public.yaml`, and make sure the hostname
   resolves so cert-manager's HTTP-01 challenge can complete.
1. **Contact email.** `config.yaml` has a placeholder address, and
   `mail_service` is `none`, so gathio sends no mail at all — event creators
   get no edit links by email — until it is set to
   `nodemailer`/`sendgrid`/`mailgun` with credentials in `helm_secrets.yaml`.
1. **Open instance.** `creator_email_addresses = []` means anyone who can reach
   the URL can create events, and `is_federated = true` publishes them over
   ActivityPub. Changing `domain` later breaks existing federated events.
1. Add `- gathio.yaml` to `flux/flux-system/kustomization.yaml`.

## Notes

- Gathio serves `/` without touching MongoDB, and `mongoose.connect` failures
  are only logged — so with the database down the pod still passes its probes
  and reports Ready, while every event operation 500s.
- The driver/server version caveat and the credential rotation procedure are
  under [MongoDB](#mongodb) above.

## MongoDB

Chart: `mongodb` 0.8.1 (appVersion 8.3.8) from
<https://groundhog2k.github.io/helm-charts> — a plain StatefulSet around the
official `mongo` image, no operator and no CRDs.

### Why this chart

- Its `userDatabase` block runs `createUser` inside the *application* database
  on first start, so the connection string needs no `?authSource=admin`. The
  official image's own `MONGO_INITDB_ROOT_*` variables only create a root user
  in `admin`, which is the usual way this gets wired up wrong.
- Chart defaults already run non-root: uid/gid 999, `fsGroup: 999`,
  `readOnlyRootFilesystem: true`.

Alternatives, if this one stops fitting:

- **Bitnami** (`oci://registry-1.docker.io/bitnamicharts/mongodb`) — since the
  August 2025 catalogue change the chart ships `bitnami/mongodb:latest` as its
  only free image, with every pinned tag moved to the frozen `bitnamilegacy`
  repo, so you cannot pin a version without a subscription.
- **Percona `psmdb-operator` + `psmdb-db`** — the right answer if you want
  replica sets and PBM backups to S3, but it is an operator plus CRDs for a
  single-instance database. MongoDB's own `mongodb-kubernetes` operator (which
  replaced `community-operator`) is the same trade.
- The in-house `devopscoop/charts/app` chart would also work, but you would
  hand-roll the user creation and have to remember `?authSource=admin`.

### Connection details

| | |
| --- | --- |
| Service | `mongodb.gathio.svc.cluster.local:27017` |
| Headless | `mongodb-internal` |
| Database | `gathio` |
| App user | `gathio`, `readWrite` + `dbAdmin` **on the `gathio` database** |
| Root user | `root`, in `admin` |
| Storage | 5Gi PVC on the default StorageClass |

Credentials are commented out in `mongodb.helm_secrets.yaml.decrypted` — fill them in
and run `./encrypt_secrets.sh`. The app user's password is also part of
`GATHIO_MONGODB_URL` in the app's own `helm_secrets.yaml`; **change both together
or gathio cannot log in.** Left empty, the chart starts MongoDB with no
authentication at all.

> **These values only apply on first start.** `MONGO_INITDB_*` and the init
> script are the official `mongo` image's behaviour: they run once, against an
> empty data directory. Editing `mongodb.helm_secrets.yaml` after the PVC exists changes
> nothing in the database. To rotate, exec in and do it in mongosh:
>
> ```shell
> kubectl -n gathio exec -it statefulset/mongodb -- mongosh \
>   -u root -p --authenticationDatabase admin \
>   --eval 'db.getSiblingDB("gathio").changeUserPassword("gathio", "<new>")'
> ```
>
> then update both secret files and restart gathio.

### MongoDB notes

- Gathio 1.6.x pins `mongoose ^5.13.22` (Node driver 3.x), which MongoDB only
  officially supports against server 4.4 and older. Upstream runs `mongo:latest`
  in `docker-compose.yml` and CI, so 8.x is what it is actually tested against —
  the image here is digest-pinned so a server major cannot change on its own.
  On x86-64, MongoDB 5.0+ requires AVX support on the node CPU.
- No backups are configured. `metrics.enabled` (percona/mongodb_exporter) is
  off; turn it on to scrape it with kube-prometheus-stack.

## Local prototyping

```shell
helm install mongodb groundhog2k/mongodb \
  --namespace gathio --version 0.8.1 \
  --values mongodb.values.yaml --values <(sops -d mongodb.helm_secrets.yaml)

helm install gathio oci://registry.gitlab.com/devopscoop/charts/app \
  --namespace gathio --version 0.11.1 \
  --values values.yaml --values <(sops -d helm_secrets.yaml)
```
