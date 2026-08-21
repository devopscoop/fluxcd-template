# MongoDB (gathio)

Single-node MongoDB backing [`../gathio`](../gathio/README.md), deployed into
the same `gathio` namespace — the same layout as the `seafile`/`seafile-mariadb`
pair: a database app dir co-located with its consumer, both shipping a
`namespace.yaml` with prune disabled.

Chart: `mongodb` 0.8.1 (appVersion 8.3.8) from
<https://groundhog2k.github.io/helm-charts> — a plain StatefulSet around the
official `mongo` image, no operator and no CRDs.

## Why this chart

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

## Connection details

| | |
| --- | --- |
| Service | `mongodb-gathio.gathio.svc.cluster.local:27017` |
| Headless | `mongodb-gathio-internal` |
| Database | `gathio` |
| App user | `gathio`, `readWrite` + `dbAdmin` **on the `gathio` database** |
| Root user | `root`, in `admin` |
| Storage | 5Gi PVC on the default StorageClass |

Credentials are commented out in `helm_secrets.yaml.decrypted` — fill them in
and run `./encrypt_secrets.sh`. The app user's password is also part of
`GATHIO_MONGODB_URL` in `apps/gathio/helm_secrets.yaml`; **change both together
or gathio cannot log in.** Left empty, the chart starts MongoDB with no
authentication at all.

> **These values only apply on first start.** `MONGO_INITDB_*` and the init
> script are the official `mongo` image's behaviour: they run once, against an
> empty data directory. Editing `helm_secrets.yaml` after the PVC exists changes
> nothing in the database. To rotate, exec in and do it in mongosh:
>
> ```shell
> kubectl -n gathio exec -it statefulset/mongodb-gathio -- mongosh \
>   -u root -p --authenticationDatabase admin \
>   --eval 'db.getSiblingDB("gathio").changeUserPassword("gathio", "<new>")'
> ```
>
> then update both `helm_secrets.yaml` files and restart gathio.

## Notes

- Gathio 1.6.x pins `mongoose ^5.13.22` (Node driver 3.x), which MongoDB only
  officially supports against server 4.4 and older. Upstream runs `mongo:latest`
  in `docker-compose.yml` and CI, so 8.x is what it is actually tested against —
  the image here is digest-pinned so a server major cannot change on its own.
  On x86-64, MongoDB 5.0+ requires AVX support on the node CPU.
- No backups are configured. `metrics.enabled` (percona/mongodb_exporter) is
  off; turn it on to scrape it with kube-prometheus-stack.
