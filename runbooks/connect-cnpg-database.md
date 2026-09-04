# Connecting to a CNPG database

Three ways to get a SQL prompt on a CloudNativePG database in this repo, in increasing order of ceremony:

1. [The `kubectl cnpg` plugin](#option-1-the-kubectl-cnpg-plugin) — one command, superuser psql on the primary. Needs the plugin installed (it's in the `Brewfile` and `pkglist.txt`).
2. [Plain `kubectl exec`](#option-2-plain-kubectl-exec) — the same session with no plugin, anywhere `kubectl` works.
3. [Port-forwarding](#option-3-port-forwarding-for-local-clients-dbeaver-etc) — for DBeaver or any other client running on your machine, authenticating as the application role.

This runbook uses **goalert** / **goalert-db** throughout; for another database substitute the app name and Cluster name (`<app>`, `<app>-db`).

## What you're connecting to

Each Cluster runs one primary and two read-only streaming replicas (`instances: 3`), behind three Services: `goalert-db-rw` (always the primary), `goalert-db-ro` (replicas only), and `goalert-db-r` (any instance). Writes only succeed on the primary — a replica answers queries but rejects writes with "cannot execute ... in a read-only transaction".

The two ways in authenticate differently:

- **Exec into a pod** (options 1 and 2): psql talks over the pod-local Unix socket as the `postgres` OS user, which peer authentication maps to the `postgres` superuser. No password exists or is asked for — which is also why this is the *only* superuser path: CNPG's `enableSuperuserAccess` defaults to false, so the `postgres` role has no password and there is no `goalert-db-superuser` Secret.
- **Over TCP** (option 3): you authenticate as the application role — the database owner — with the password CNPG generates into the `goalert-db-app` Secret (`<cluster>-app`).

## Option 1: the kubectl cnpg plugin

```shell
kubectl cnpg psql goalert-db -n goalert
```

That's a superuser psql on the current primary, connected to the `postgres` database. Arguments after `--` go to psql, so to land in the app's database instead:

```shell
kubectl cnpg psql goalert-db -n goalert -- goalert
```

Add `--replica` to connect to a replica instead — the right default for exploratory queries, since it keeps your session off the primary.

The plugin is also the quickest topology view — which instance is primary, replication lag, last archived WAL:

```shell
kubectl cnpg status goalert-db -n goalert
```

## Option 2: plain kubectl exec

The Cluster's `.status.currentPrimary` names the primary pod, so plain kubectl can do what the plugin does:

```shell
kubectl -n goalert exec -it "$(kubectl -n goalert get cluster goalert-db -o jsonpath='{.status.currentPrimary}')" -c postgres -- psql
```

`-c postgres` matters: the instance pods also run the barman-cloud sidecar container (WAL archiving — see `apps/cnpg-barman-plugin`), and without it kubectl may pick that container instead. As with option 1 you land as superuser in the `postgres` database; append the database name (`-- psql goalert`) to start in the app's.

For a read-only session, exec into a replica instead — CNPG labels pods with their role:

```shell
kubectl -n goalert get pods -l cnpg.io/cluster=goalert-db,cnpg.io/instanceRole=replica
```

## Option 3: port-forwarding, for local clients (DBeaver etc.)

Superuser access over TCP is disabled, so local clients connect as the application role. CNPG generates and maintains its credentials in the `goalert-db-app` Secret:

```shell
kubectl -n goalert get secret goalert-db-app -o jsonpath='{.data.username}' | base64 -d; echo
kubectl -n goalert get secret goalert-db-app -o jsonpath='{.data.password}' | base64 -d; echo
```

Username and database name are both the app name (`goalert`) by this repo's convention. The Secret also carries ready-made `uri` and `jdbc-uri` keys, but they point at the in-cluster Service DNS name — for a port-forward, use localhost and the individual pieces.

Forward the read-write Service to a local port (15432 here, so a Postgres already running on your machine doesn't collide):

```shell
kubectl -n goalert port-forward svc/goalert-db-rw 15432:5432
```

Then connect from DBeaver (or anything else): host `localhost`, port `15432`, database `goalert`, and the username/password from above. The psql equivalent:

```shell
psql "host=localhost port=15432 user=goalert dbname=goalert"
```

Caveats:

- **The forward pins to one pod.** `kubectl port-forward svc/...` resolves the Service to a single pod when it starts and never re-resolves. If a failover or switchover happens while you're connected, your session is now on a replica (writes fail as read-only) or dead — kill the port-forward and start it again.
- **Read-only browsing:** forward `svc/goalert-db-ro` instead to land on a replica and keep exploratory load off the primary.
- **TLS:** the server speaks TLS and psql's default `sslmode=prefer` works, but the certificate names the in-cluster Services, not localhost — so `sslmode=verify-full` fails through a port-forward. Anything up to `sslmode=require` is fine.
- **Privileges:** the app role owns the `goalert` database and nothing more. If a task genuinely needs superuser, use option 1 or 2 rather than trying to get superuser over TCP.

## Related

Restoring a database from its barman backup: `runbooks/restore-cnpg-database.md`.
