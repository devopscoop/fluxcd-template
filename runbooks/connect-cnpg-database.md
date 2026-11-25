# Connecting to a CNPG database

Examples connect to the **goalert** database (namespace `goalert`, Cluster `goalert-db`) as **alice**; substitute your own. Each Cluster has three Services: `goalert-db-rw` (the primary), `goalert-db-ro` (replicas, where writes fail), and `goalert-db-r` (any instance).

| Option | Use it for | You connect as |
| --- | --- | --- |
| [1. SSO](#option-1-oauth-developer-sso-for-databases-with-the-pg-oauth-block-enabled) | Everyday queries | Your own role |
| [2. Claude with SSO](#option-2-using-claude-with-sso-using-psql-oauthsh-sessions) | Letting Claude Code query for you | Your own role |
| [3. `kubectl cnpg`](#option-3-the-kubectl-cnpg-plugin) | Superuser tasks | `postgres` superuser |
| [4. Client certificate](#option-4-client-certificate-for-desktop-guis-for-databases-with-the-pg-dev-certs-block-enabled) | Desktop GUIs (DataGrip, DBeaver) | Your own `_cert` role |

Use SSO (1 or 2) wherever the database has the `pg-oauth` block enabled: they and option 4 attribute your session to you; option 3 doesn't.

## Option 1: OAuth developer SSO, for databases with the pg-oauth block enabled

```shell
# psql prompt on a replica
./psql-oauth.sh -n goalert -c goalert-db -d goalert -U alice

# Run one command and exit
./psql-oauth.sh -n goalert -c goalert-db -d goalert -U alice -- -c '\ds'

# Run a SQL file and exit
./psql-oauth.sh -n goalert -c goalert-db -d goalert -U alice -- -f query.sql
```

Approve the login in the browser tab that opens, or at the URL psql prints.

- `-e` picks the Service: `ro` (the default), `rw`, or `r`. A single-instance Cluster has no replicas, so use `-e r` or `-e rw` there.
- `-n`, `-c`, `-d` are the namespace, Cluster and database. `-U` is your role: your email's local part (`alice@example.com` → `alice`).
- `--print` shows the manual commands instead of running them.
- Developers get `pg_read_all_data`. Tables behind row-level security also need `bypassrls` on your role.

You need:

- psql 18 with OAuth support: Homebrew `postgresql@18` (installed as `psql-18`), Arch `postgresql-libs`, or Debian/Ubuntu PGDG `libpq-oauth`.
- A login role named after your email's local part in the Cluster's `managed.roles`.
- With read-only cluster access (`cluster-viewers`), the template's `db-developer-rbac.yaml` applied in the app's namespace.

## Option 2: Using Claude with SSO (using psql-oauth.sh sessions)

Every connection is a new browser approval, so start a session and approve once:

```shell
# Approve once
./psql-oauth.sh -n goalert -c goalert-db -d goalert -U alice --session start

# Queries now skip the browser
./psql-oauth.sh -n goalert -c goalert-db -d goalert -U alice -- -At -c 'select count(*) from alerts'

# List running sessions
./psql-oauth.sh --session status

# When done
./psql-oauth.sh -n goalert -c goalert-db -d goalert -U alice --session stop
```

Then ask Claude Code to use it, naming the environment and database — for example, "I have a dev SSO session on goalert-db; list its tables." `AGENTS.md` tells it how to find and use the session, and it can start one itself; you still approve in the browser.

- Pass the same `-e`, `-U`, and `-n`/`-c`/`-d` to `start`, the queries, and `stop`, with the same kubeconfig: sessions are per Kubernetes cluster. Two sessions running at once need different `-p PORT`s.
- A session takes SQL through `-c`, `-f FILE` or stdin, plus `-A -t -x -F --csv -v`. Other psql flags need `--session stop` first.
- A switchover or failover can end a session. The next query reconnects with one approval; run `--session start` again afterwards.

## Option 3: the kubectl cnpg plugin

Superuser psql. The plugin is in the `Brewfile` and `pkglist.txt`.

```shell
kubectl cnpg psql goalert-db -n goalert -- goalert             # on the primary
kubectl cnpg psql goalert-db -n goalert --replica -- goalert   # on a replica
kubectl cnpg status goalert-db -n goalert                      # primary, lag, backups
```

## Option 4: client certificate, for desktop GUIs, for databases with the pg-dev-certs block enabled

DataGrip and DBeaver can't do the SSO login: their JDBC driver has no OAuth support yet. With the `pg-dev-certs` block enabled, each developer also has a certificate-only role, `<name>_cert`, with the same read-only access as their SSO role.

Get your certificate and key. You can read your own Secret and nobody else's:

```shell
mkdir -p ~/.goalert-db && chmod 700 ~/.goalert-db
s=goalert-db-developer-alice-cert

kubectl -n goalert get secret $s -o jsonpath='{.data.tls\.crt}' | base64 -d > ~/.goalert-db/client.crt

# The JDBC driver wants the key as PKCS#8 DER; psql takes the PEM as it is.
kubectl -n goalert get secret $s -o jsonpath='{.data.tls\.key}' | base64 -d \
  | openssl pkcs8 -topk8 -nocrypt -outform DER -out ~/.goalert-db/client.pk8
chmod 600 ~/.goalert-db/client.pk8
```

Open a port-forward to a replica and leave it running while you work. Run it in a loop, because it exits whenever a database connection closes:

```shell
while :; do kubectl -n goalert port-forward svc/goalert-db-ro 15432:5432; sleep 1; done
```

Then point the GUI at it:

| Setting | Value |
| --- | --- |
| Host / port | `localhost` / `15432` |
| Database | `goalert` |
| User | `alice_cert` |
| Authentication | No auth (no password) |
| SSL mode | `require` |
| Client certificate file | `~/.goalert-db/client.crt` |
| Client key file | `~/.goalert-db/client.pk8` |

- Use `require`, not `verify-full`: the server certificate doesn't name `localhost`.
- Expect dropped connections. When any connection through the port-forward closes, `kubectl` exits ("connection reset by peer", "lost connection to pod") and every other connection through it drops with it. The loop brings the forward back in a second or two; reconnect in the GUI.
- To see fewer drops, make the GUI use one connection. In DBeaver, untick "Open separate connection for metadata read" and "Open separate connection for each editor" in Preferences. In DataGrip, turn on single session mode in the data source's options.
- Certificates last 90 days and renew 30 days before expiry. When yours stops working, fetch the files again.
- Set the GUI to auto-commit, or close its transactions: a session left idle in a transaction holds back vacuum.
- Adding or removing a developer: the app's `db-developer-client-cert.yaml`.

## Related

- Restoring from backup: `runbooks/restore-cnpg-database.md`
- Upgrading to a new PostgreSQL major: `runbooks/upgrade-cnpg-database.md`
