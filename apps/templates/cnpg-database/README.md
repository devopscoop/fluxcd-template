# cnpg-database

A per-app PostgreSQL database (CloudNativePG) with mTLS client-certificate
auth for the app and barman backups to S3. Copy the files by hand — the
step-by-step is in `db-cluster.yaml`'s header. What each file provides:

- `db-cluster.yaml` — the Cluster, its barman ObjectStore, and the daily
  ScheduledBackup.
- `db-client-cert.yaml` — a namespace-local CA chain (selfsigned bootstrap
  Issuer → CA Certificate → CA Issuer) and two leaf certs: the
  `streaming_replica` cert CNPG's replicas need once the cluster carries
  its own `clientCASecret`, and the app's client certificate.
- `db-developer-rbac.yaml` — RBAC for read-only developer SSO sessions
  (the `pg-oauth` marker block; see `apps/dex/README.md`).

## How authentication works

The app's login is the client certificate, not a password. The `cert`
pg_hba method requires TLS and a certificate whose CN equals the Postgres
role, signed by the cluster's client CA — so possession of the mounted
cert IS the login. Two pg_hba rules in `db-cluster.yaml` make it the only
login for the app role: `hostssl ... cert` owns every TLS connection, and
`host ... reject` closes the non-TLS fallback where the password in the
auto-generated `<cluster>-app` Secret would still work. That Secret keeps
existing (CNPG always creates it) but authenticates nothing — don't wire
it into the app.

Everything renews automatically: cert-manager reissues the app cert a
month before expiry and the replication cert with the `cnpg.io/reload`
label, so the database picks renewals up without a restart. Server
certificates stay operator-managed; the operator's `<cluster>-ca` Secret
carries the server CA, which the app can mount to verify the server
(`sslmode=verify-full`).

Humans don't use the app's certificate: interactive access is peer auth in
the pods or, with the `pg-oauth` block enabled, per-developer SSO
(`runbooks/connect-cnpg-database.md`).

## Using the certificate in your app

Worked example for an app named `myapp` (so the role, database, and
cluster are `myapp`, `myapp`, and `myapp-db`) deployed with the Helm app
template (`apps/templates/helm/`), whose chart passes `volumes`,
`volumeMounts`, and `envConfigMap` through to the workload.

### 1. Mount the cert files

In `apps/myapp/values.yaml`:

```yaml
volumes:
  - name: db-client-cert
    secret:
      secretName: myapp-db-client-cert
      # 0640 (decimal 416): libpq and Go's lib/pq refuse a private key
      # readable beyond u=rw,g=r unless it is root-owned at 0640 or less.
      # pgx doesn't check. Root-running images read the file as owner; a
      # nonroot image needs the fsGroup below to read it via group.
      defaultMode: 416
  - name: db-server-ca
    secret:
      secretName: myapp-db-ca
volumeMounts:
  - name: db-client-cert
    mountPath: /etc/db-client-cert
    readOnly: true
  - name: db-server-ca
    mountPath: /etc/db-server-ca
    readOnly: true
# Only for images that run as a nonroot user (uid/gid shown for
# distroless:nonroot): group-owns the pod's volumes so the 0640 key is
# readable. Root-running images need nothing.
podSecurityContext:
  fsGroup: 65532
```

The client-cert mount lands `tls.crt`, `tls.key`, and the client CA's
`ca.crt`; the second mount is the *server* CA (a different CA — the
operator's), which is what the client verifies the server against.

### 2. Point the client at the files

For libpq and libpq-compatible drivers (psql, Go's pgx and lib/pq, and
most others), the standard environment variables are enough — no code
changes, add to `envConfigMap`:

```yaml
envConfigMap:
  PGHOST: "myapp-db-rw.myapp.svc.cluster.local"
  PGDATABASE: "myapp"
  PGUSER: "myapp"                # must equal the certificate's CN
  PGSSLMODE: "verify-full"
  PGSSLCERT: "/etc/db-client-cert/tls.crt"
  PGSSLKEY: "/etc/db-client-cert/tls.key"
  PGSSLROOTCERT: "/etc/db-server-ca/ca.crt"
```

Or as a DSN, for apps that take a connection URL:

```text
postgresql://myapp@myapp-db-rw.myapp.svc.cluster.local:5432/myapp?sslmode=verify-full&sslcert=/etc/db-client-cert/tls.crt&sslkey=/etc/db-client-cert/tls.key&sslrootcert=/etc/db-server-ca/ca.crt
```

No password appears anywhere in either form. Drivers that don't read
libpq settings need their own spelling of the same three file paths
(for node-postgres: the `ssl: {ca, cert, key}` connection options).

### 3. Verify

With the app running, every one of its connections should carry the CN:

```shell
kubectl cnpg psql myapp-db -n myapp -- -c \
  "SELECT s.client_dn, count(*) FROM pg_stat_ssl s
   JOIN pg_stat_activity a USING (pid)
   WHERE a.usename = 'myapp' GROUP BY 1;"
```

`client_dn = /CN=myapp` on every row is success. A NULL row is a client
that connected without the cert — under these pg_hba rules it could not
have authenticated, so in practice failures surface as TLS errors in the
app's log instead.

### The one renewal gotcha

Most drivers read the cert files once, when the connection config is
built, so a renewal only reaches the process at the next pod restart. The
cert ships with an 11-month margin between renewal and expiry — a pod
must run longer than that without a restart before its in-memory cert can
expire and new connections start failing. If your pods can live that
long, either restart workloads on secret change (a Reloader-style
controller) or alert on pod uptime approaching the margin
(`time() - kube_pod_start_time` as a VMRule, joined against
`kube_pod_status_phase{phase="Running"}` so completed Job pods don't
false-fire).

## Migrating an existing password-auth database

Never add the pg_hba rules before the app demonstrably presents the cert:
pg_hba is first-match by connection and user, not by auth success, so the
`cert` rule kills password auth the moment it lands. Stage it — deploy
`db-client-cert.yaml` and the mounts first (inert), add the env vars
(certs are presented but scram still authenticates; verify with the
`pg_stat_ssl` query above), and only then add the two pg_hba rules.

## Rolling back

Remove the two pg_hba rules from `db-cluster.yaml` and the app can
authenticate with the `<cluster>-app` Secret's password again (CNPG
maintains it regardless). The cert machinery is independent — leave it
deployed while debugging and re-add the rules after.
