# Connecting to a CNPG database

Examples use **goalert**; for another app substitute `<app>` and `<app>-db`. Each Cluster has three Services: `goalert-db-rw` (the primary), `goalert-db-ro` (replicas, where writes fail), and `goalert-db-r` (any instance).

| Option | Use it for | You connect as |
| --- | --- | --- |
| [1. SSO](#option-1-oauth-developer-sso-for-databases-with-the-pg-oauth-block-enabled) | Everyday queries | Your own role |
| [2. Claude with SSO](#option-2-using-claude-with-sso-using-psql-oauthsh-sessions) | Letting Claude Code query for you | Your own role |
| [3. `kubectl cnpg`](#option-3-the-kubectl-cnpg-plugin) | Superuser tasks | `postgres` superuser |

Use SSO (1 or 2) wherever the database has the `pg-oauth` block enabled: it's the only option that attributes your session to you.

## Option 1: OAuth developer SSO, for databases with the pg-oauth block enabled

```shell
./psql-oauth.sh goalert                    # psql prompt on a replica
./psql-oauth.sh goalert -- -c 'select 1'   # run SQL and exit
./psql-oauth.sh -e rw goalert              # the primary, for writes
```

Approve the login in the browser tab that opens, or at the URL psql prints.

- `-e` picks the Service: `ro` (the default), `rw`, or `r`. A single-instance Cluster has no replicas, so use `-e r` or `-e rw` there.
- `-U ROLE` overrides your role, which defaults to your git email's local part. `-n`/`-c`/`-d` override the namespace, Cluster and database. `--print` shows the manual commands.
- Developers get `pg_read_all_data`. Tables behind row-level security also need `bypassrls` on your role.

You need:

- psql 18 with OAuth support: Homebrew `postgresql@18` (installed as `psql-18`), Arch `postgresql-libs`, or Debian/Ubuntu PGDG `libpq-oauth`.
- A login role named after your email's local part in the Cluster's `managed.roles`.
- With read-only cluster access (`cluster-viewers`), the template's `db-developer-rbac.yaml` applied in the app's namespace.

## Option 2: Using Claude with SSO (using psql-oauth.sh sessions)

Every connection is a new browser approval, so start a session and approve once:

```shell
./psql-oauth.sh --session start goalert                           # approve once
./psql-oauth.sh goalert -- -At -c 'select count(*) from alerts'   # no browser
./psql-oauth.sh --session status                                  # list sessions
./psql-oauth.sh --session stop goalert                            # when done
```

Then ask Claude Code to query the database. `AGENTS.md` tells it how to use the session, and it can start one itself; you still approve in the browser.

- Pass the same `-e`, `-U`, and `-n`/`-c`/`-d` to `start`, the queries, and `stop`. Two sessions running at once need different `-p PORT`s.
- A session takes SQL through `-c`, `-f FILE` or stdin, plus `-A -t -x -F --csv -v`. Other psql flags need `--session stop` first.
- A switchover or failover can end a session. The next query reconnects with one approval; run `--session start` again afterwards.

## Option 3: the kubectl cnpg plugin

Superuser psql. The plugin is in the `Brewfile` and `pkglist.txt`.

```shell
kubectl cnpg psql goalert-db -n goalert -- goalert             # on the primary
kubectl cnpg psql goalert-db -n goalert --replica -- goalert   # on a replica
kubectl cnpg status goalert-db -n goalert                      # primary, lag, backups
```

## Related

- Restoring from backup: `runbooks/restore-cnpg-database.md`
- Upgrading to a new PostgreSQL major: `runbooks/upgrade-cnpg-database.md`
