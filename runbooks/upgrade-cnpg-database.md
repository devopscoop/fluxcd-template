# Upgrading a CNPG database's PostgreSQL version

Every CloudNativePG database in this repo pins an exact image tag in `apps/<app>/db-cluster.yaml`, so every version change is a deliberate git edit (see `apps/templates/cnpg-database/db-cluster.yaml`). There are two very different kinds of change behind that one line, and only the second needs this runbook.

This runbook uses **goalert** / **goalert-db** throughout; for another database substitute the app name and Cluster name (`<app>`, `<app>-db`) everywhere, including in the S3 paths.

## Minor upgrades are routine

Changing the patch level within a major — `17.11-system-trixie` to `17.12-system-trixie` — is a rolling update. The operator restarts the replicas one at a time, then switches the primary over to an already-upgraded instance. With `primaryUpdateStrategy: unsupervised` (what this repo ships) nobody has to promote anything, clients see a seconds-long blip through the `-rw` Service, and the data directory is untouched. Merge it like any other change; no window, no runbook.

The rest of this file is about **major** upgrades — 17 to 18 — which are a different operation entirely.

## What a major upgrade actually does

Bumping the major in `imageName` (or in the ImageCatalog, if you use one) triggers CNPG's [declarative offline in-place major upgrade](https://cloudnative-pg.io/docs/1.28/postgres_upgrades/), available since operator 1.26 — this repo pins 1.28. On the next reconcile the operator:

1. **Shuts down every instance.** The database is down from here, and so is every service that talks to it. There is no rolling variant of this.
2. Runs a Job (its name ends in `-major-upgrade`) that calls `pg_upgrade` against the primary's existing data volume, with the old major's binaries supplied from the previous image. It hard-links the data files rather than copying them, so the time scales with the number of relations, not with gigabytes on disk — minutes, but not seconds.
3. Restarts the primary on the new major. **Writes resume here**; this is the end of the outage.
4. Deletes the replicas' PVCs and re-clones them from the upgraded primary. The cluster is up but **without HA** until that finishes, and the re-clone does copy the whole dataset.

Two consequences to be clear about before you start:

- **It is one-way.** There is no downgrade. Going back means restoring a pre-upgrade backup into a cluster running the *old* image — and a point-in-time recovery cannot cross the upgrade boundary either.
- **The archive path must change.** `pg_upgrade` gives the cluster a new system identifier and resets its timeline, and the Barman Cloud Plugin refuses to archive into a WAL history it didn't create. Bumping `plugins.serverName` is part of the same edit — the same rule, and the same shared counter, as `runbooks/restore-cnpg-database.md`. Skip it and the upgrade will succeed while WAL archiving silently stops.

## Prerequisites

- `kubectl` admin access, the `kubectl cnpg` plugin, and the `flux` CLI.
- A checkout of this repo — the upgrade is a git edit you commit.
- The `aws` CLI, for verifying the new archive path.
- A scheduled maintenance window, announced. This is the one database operation that cannot be made invisible to users.

## 1. Check the application supports the new major

The database exists for an app, and the app's supported-Postgres matrix governs, not the operator's default. GoAlert is the standing example in this repo: v0.34 is tested against 13-17 only, which is why `apps/goalert/db-cluster.yaml` stays on 17 while `apps/templates/cnpg-database/db-cluster.yaml` tracks 18. Upgrade the app first, or don't upgrade the database.

## 2. Preflight against the live cluster

**Extensions.** Every extension installed in every database has to exist in the new image, or `pg_upgrade` refuses to run:

```shell
kubectl cnpg psql goalert-db -n goalert -- goalert -c \
  'select extname, extversion from pg_extension order by 1'
```

Contrib extensions (`pgcrypto`, `uuid-ossp`, `citext`, `pg_stat_statements`, ...) ship in every flavor and are never a problem. Anything else — `vector` is the common one — needs checking against the new tag. Run this in *each* database the cluster hosts, not just the app's main one.

**Parameters.** A GUC removed or renamed in the new major stops the instance from starting. Read the new major's release notes against `spec.postgresql.parameters` and `shared_preload_libraries` in the Cluster.

**Image flavor.** Stay on the same flavor and distro across the bump — `18.6-system-trixie` follows `17.11-system-trixie`. Changing distro at the same time changes the glibc/ICU collation, which silently invalidates text indexes; if you ever must, plan a `REINDEX` of every text index in the same window.

**Backups are healthy:**

```shell
kubectl -n goalert get cluster goalert-db \
  -o jsonpath='last backup: {.status.lastSuccessfulBackup}{"\n"}last archived WAL: {.status.lastArchivedWAL}{"\n"}'
kubectl -n goalert get cluster goalert-db \
  -o jsonpath='{range .status.conditions[*]}{.type}={.status}{"\n"}{end}'   # ContinuousArchiving=True
```

## 3. Take a pre-upgrade base backup

This is the safety net for the whole operation, and the only way back if `pg_upgrade` fails after it has started linking files:

```shell
kubectl cnpg backup goalert-db -n goalert \
  --method plugin --plugin-name barman-cloud.cloudnative-pg.io
kubectl -n goalert get backup -w
```

Wait for it to report `completed` before going any further. `pg_upgrade` runs its own consistency check first and aborts cleanly on anything it doesn't like — a failure there leaves the old data directory intact and reverting the image brings the cluster back on the old major. A failure *after* that point is the one this backup is for.

## 4. Edit `apps/goalert/db-cluster.yaml`

Two changes to the Cluster document — three if the app already has a recovery bootstrap:

```yaml
spec:
  # 1. The new major, exact tag, same flavor and distro as before.
  imageName: ghcr.io/cloudnative-pg/postgresql:18.6-system-trixie
  plugins:
    - name: barman-cloud.cloudnative-pg.io
      isWALArchiver: true
      parameters:
        barmanObjectName: goalert-db
        # 2. A fresh archive path: pg_upgrade resets the timeline, and the
        # plugin will not write into a WAL history it didn't create. The
        # suffix counter is shared with restores — a cluster that has never
        # been restored starts at -r2, one already on -r2 goes to -r3.
        serverName: goalert-db-r2
  # 3. Only if this file already carries a bootstrap.recovery source (i.e.
  # the database has been restored before): repoint it at the NEW path, so a
  # future rebuild recovers a cluster the new image can actually run. It
  # becomes a valid source once step 7's post-upgrade backup lands.
  externalClusters:
    - name: goalert-db
      plugin:
        name: barman-cloud.cloudnative-pg.io
        parameters:
          barmanObjectName: goalert-db
          serverName: goalert-db-r2
```

Say in the commit message which majors this moves between and what the new `serverName` is — the next person restoring this database reads that history to work out which image a given archive path needs.

## 5. Merge inside the window

The merge is the trigger: Flux reconciles the new `imageName` and the operator starts shutting instances down. Nothing else is required, and nothing should be applied by hand.

```shell
flux reconcile kustomization goalert --with-source   # only to stop waiting for the poll interval
```

Do not suspend Flux for this one. Unlike a restore, the upgrade is entirely driven by the manifest, and a suspended Kustomization just means the cluster is down while the operator waits for an edit it can't see.

## 6. Watch it through

```shell
kubectl -n goalert get cluster goalert-db -w
kubectl -n goalert get jobs                                        # the -major-upgrade job
kubectl -n goalert logs -f job/<the -major-upgrade job>            # pg_upgrade's own output
kubectl -n goalert logs -l cnpg.io/cluster=goalert-db -f --prefix  # then the instances
```

Watch for the primary coming back first — that is the outage ending — and then for the two replicas to be re-created and reach `3/3` and "Cluster in healthy state".

## 7. Immediately after the cluster is healthy

**Take a base backup, before anything else.** The ScheduledBackup's `immediate: true` fires only when that resource is created, so it does *not* cover an upgrade: the new `serverName` path is empty, and until the next nightly run the upgraded database has no base backup and nothing to recover from.

```shell
kubectl cnpg backup goalert-db -n goalert \
  --method plugin --plugin-name barman-cloud.cloudnative-pg.io
aws s3 ls s3://devopscoop-project1-dev-goalert-db-backups/goalert-db-r2/base/
```

**Update the extensions.** `pg_upgrade` carries each extension's catalog entry across at the version it had on the old major, even though the new image ships newer SQL definitions. Find the stragglers and update them, in every database:

```shell
kubectl cnpg psql goalert-db -n goalert -- goalert -c \
  "select e.extname, e.extversion, a.default_version
     from pg_extension e join pg_available_extensions a on a.name = e.extname
    where e.extversion <> a.default_version"
kubectl cnpg psql goalert-db -n goalert -- goalert -c \
  'ALTER EXTENSION pg_stat_statements UPDATE'
```

**Re-analyze.** Recent majors carry most planner statistics across, but a fresh `ANALYZE` is cheap insurance against a first-query-of-the-day cliff:

```shell
primary=$(kubectl -n goalert get cluster goalert-db -o jsonpath='{.status.currentPrimary}')
kubectl -n goalert exec "$primary" -c postgres -- vacuumdb --all --analyze-in-stages
```

**Confirm the rest:**

```shell
kubectl -n goalert get cluster goalert-db \
  -o jsonpath='{range .status.conditions[*]}{.type}={.status}{"\n"}{end}'   # ContinuousArchiving=True
kubectl cnpg status goalert-db -n goalert   # 3/3, both replicas streaming, new PG version
```

Then exercise the application itself — for GoAlert, that schedules and escalation policies look right and test pages go out.

## 8. Rollback

- **The upgrade Job failed.** Revert the commit — image back to the old tag, `serverName` back to what it was — and let Flux reconcile. The operator restarts the cluster on the old major with no data loss, because `pg_upgrade`'s check pass aborts before touching the data directory. If the Job instead failed midway through linking, treat the data directory as lost and restore the step 3 backup per `runbooks/restore-cnpg-database.md`, with the *old* image in the manifest.
- **The upgrade succeeded and you want to go back.** There is no downgrade path. Restore a pre-upgrade backup — the archive under the *old* `serverName` — into a cluster running the old image, following the restore runbook. Anything written since the upgrade is lost, so decide quickly.
- **A PITR to before the upgrade** is the same operation: old archive, old image. The timeline reset means no single cluster can span both sides of the boundary.

## 9. Afterwards

- **The old archive stops being pruned.** Retention only applies to the path being written, so `s3://…/goalert-db/` lingers once everything archives into `goalert-db-r2/`. Keep it while the new major is on probation — it is your only pre-upgrade restore source — and delete it once you are confident and the retention window has rolled over anyway:

  ```shell
  aws s3 rm --recursive s3://devopscoop-project1-dev-goalert-db-backups/goalert-db/
  ```

- **Leave the `serverName` in git**, and leave any `bootstrap.recovery` block alone — CNPG ignores `bootstrap` on a live cluster, and together they record which archive path belongs to which era.
- **Revisit the template.** If this upgrade moved a database to a major that `apps/templates/cnpg-database/db-cluster.yaml` hasn't reached yet, bump the template too, so the next database starts where this one ended up.
