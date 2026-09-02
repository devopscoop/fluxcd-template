# Restoring a CNPG database from its barman backup

Every CloudNativePG database in this repo archives WAL continuously and takes a nightly base backup to S3 through the Barman Cloud Plugin (see `apps/templates/cnpg-database/db-cluster.yaml`, and `arguments/ebs_snapshots_vs_barman.argdown` for why barman rather than EBS snapshots). That gives point-in-time recovery to any moment inside the retention window (30 days by default).

This runbook uses **goalert** / **goalert-db** throughout; for another database substitute the app name and Cluster name (`<app>`, `<app>-db`) everywhere, including in the S3 paths.

**What a restore cannot bring back:**

- Writes after the last archived WAL segment (archiving is continuous, so normally this is minutes at most — the "confirm" step below tells you exactly).
- Anything encrypted by an application-level key that you lost. GoAlert's `GOALERT_DATA_ENCRYPTION_KEY` lives in `apps/goalert/helm_secrets.yaml`, not in the database — restoring the database with a different key leaves the encrypted columns unreadable. Keep the key.

**How CNPG restores:** never in place. You bootstrap a *new* Cluster from the object store (`bootstrap.recovery` + `externalClusters`). This runbook keeps the same Cluster name so all the app wiring (`goalert-db-app` Secret, `goalert-db-rw` Service) is unchanged, which requires two things: deleting the old Cluster, and archiving the restored cluster's WAL under a **new `serverName`** — CNPG refuses to archive into a WAL history it didn't create, so the restored cluster cannot write into the same path it just restored from.

## Prerequisites

- `kubectl` admin access to the cluster and the `flux` CLI.
- A checkout of this repo — the restore is a git edit; you will commit it.
- The backup bucket and IRSA role are managed by aws-eks-template (`cluster/cnpg-backups.tf`), independent of the Kubernetes cluster: they survive even total cluster loss. The `aws` CLI helps for the verification and cleanup steps.

## 1. Freeze the world

Stop Flux from fighting your edits, and stop the application from writing:

```shell
flux suspend kustomization goalert
kubectl -n goalert scale deploy/goalert --replicas=0
```

## 2. Confirm you have something to restore — before deleting anything

If the old Cluster still exists:

```shell
kubectl -n goalert get cluster goalert-db \
  -o jsonpath='last backup: {.status.lastSuccessfulBackup}{"\n"}last archived WAL: {.status.lastArchivedWAL}{"\n"}'
```

If it doesn't (namespace or cluster gone), list the object store directly:

```shell
aws s3 ls s3://devopscoop-project1-dev-goalert-db-backups/goalert-db/base/
```

At least one base backup must exist. Everything written after the last archived WAL is gone regardless of what you do next.

## 3. Pick the recovery target

- **Latest** (default): recover to the end of the archived WAL. Use for PVC loss, corruption, cluster loss.
- **Point in time**: recover to just *before* a bad migration or deletion, discarding everything after. You will set `recoveryTarget.targetTime` below; it must be later than the end of some base backup and earlier than the last archived WAL.

## 4. Edit `apps/goalert/db-cluster.yaml`

Everything the restore needs ships commented out in the manifest itself; the ObjectStore and ScheduledBackup documents stay as they are. Three toggles in the Cluster document, each explained by the comment sitting on it:

1. Comment out the `bootstrap.initdb` block and uncomment `bootstrap.recovery` beneath it. For a point-in-time restore, also uncomment `recoveryTarget` and set `targetTime`.
2. Uncomment `serverName` under `.spec.plugins[0].parameters` — the restored cluster's *new* archive path, which CNPG requires because it refuses to archive into a WAL history it didn't create. Bump the suffix on every restore (`-r2`, `-r3`, ...).
3. Uncomment the `externalClusters` block at the bottom of the Cluster document and point its `serverName` at where the backup you are restoring from lives — the *old* serverName (the Cluster name originally, `-rN` if this cluster was restored before).

Check `storage.size` while you are in the file: the new PVCs must hold the restored data. The template ships 1Gi; a cluster that grew past that needs the size the old cluster actually had.

## 5. Replace the running Cluster

**Point of no return** — this deletes the old instances and their PVCs (the object store is untouched):

```shell
kubectl -n goalert delete cluster goalert-db
kubectl -n goalert apply -f apps/goalert/db-cluster.yaml
```

The apply creates all three documents; the ScheduledBackup's `immediate: true` takes a fresh base backup into the new `serverName` as soon as the cluster is healthy.

## 6. Watch the recovery

```shell
kubectl -n goalert get cluster goalert-db -w        # wait for "Cluster in healthy state", 3/3 ready
kubectl -n goalert logs -l cnpg.io/cluster=goalert-db -f --prefix   # full-recovery job, then instances
```

When healthy, confirm WAL archiving works against the new path and the post-restore backup completed:

```shell
kubectl -n goalert get cluster goalert-db -o jsonpath='{range .status.conditions[*]}{.type}={.status}{"\n"}{end}'   # ContinuousArchiving=True
kubectl -n goalert get backup
```

The `goalert-db-app` Secret is managed by the operator, which reconciles the application role's password in the restored database to match it — no manual credential surgery.

## 7. Sanity-check the data

```shell
kubectl cnpg psql goalert-db -n goalert   # or: kubectl -n goalert exec -it goalert-db-1 -- psql -U postgres goalert
```

Run whatever proves the restore landed where you wanted — for a PITR, verify the bad write is absent and the last good one is present.

## 8. Commit, then resume Flux — in that order

```shell
git add apps/goalert/db-cluster.yaml && git commit && git push
flux resume kustomization goalert
flux reconcile kustomization goalert --with-source
```

**The order matters.** If you resume Flux before the edited manifest is in git, Flux reverts the Cluster spec to the old `initdb` version — CNPG ignores the `bootstrap` change on a live cluster, but reverting the `plugins.serverName` points archiving back at the old, non-empty WAL path, which CNPG rejects, and archiving stops. Commit first.

Resuming also scales the app deployment back up (replicas come from git). Log in and verify the application works — for GoAlert, that schedules and escalation policies look right and test pages go out.

## 9. Afterwards

- **Old archive cleanup.** Retention only prunes the serverName that is being written; the old path (`s3://…/goalert-db/`) stops being pruned the moment nothing archives there, and would linger forever. After a confidence period — you may want the pre-restore state around for a while — delete it:

  ```shell
  aws s3 rm --recursive s3://devopscoop-project1-dev-goalert-db-backups/goalert-db/
  ```

- **Leave the recovery bootstrap in git.** CNPG ignores `bootstrap` after a cluster exists, and the block documents where this database actually came from. The next restore bumps `serverName` to `-r3` and points `externalClusters` at `-r2`.

## Variant: restoring during a full cluster rebuild

If the Kubernetes cluster itself is being rebuilt (the bucket outlives it), make the same edit from step 4 *before* the first deploy — bootstrap the app's database straight into recovery instead of `initdb`. Everything else is identical, minus the delete in step 5.
