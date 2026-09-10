# dex

[Dex](https://dexidp.io/) is a small OIDC issuer that federates an upstream
identity provider (Google Workspace, Entra, GitHub, LDAP, any OIDC) into
tokens for cluster services — an in-cluster SSO broker, not a user database.
Identity truth stays in the upstream IdP: Dex holds no local accounts
(`enablePasswordDB: false`), so offboarding someone upstream offboards them
from every consumer here. Why Dex and not Keycloak — and when that answer
flips — is mapped in `arguments/keycloak_vs_dex.argdown`.

This app is optional and not in `deploy.sh`'s app lists. To deploy it,
register it the same way `deploy_new_app.sh --deploy` would:

```shell
yq -i '.resources = (.resources + ["dex.yaml"] | unique)' flux/flux-system/kustomization.yaml
```

## Configuration

The split between the two values files follows the secrets convention:

- `values.yaml` — the issuer URL, CRD storage, and oauth2 behavior.
- `helm_secrets.yaml` — the `config.connectors` block (each connector
  carries the upstream IdP's client secret) and the whole
  `config.staticClients` list: Flux merges valuesFrom like `helm -f` —
  maps deep-merge but lists are replaced wholesale — so the client list
  cannot be split across the two files, and confidential clients carry
  secrets.

The issuer URL is load-bearing. Consumers configure it byte-for-byte, the
tokens embed it, and validators fetch the discovery document and JWKS from
it — so it must be HTTPS, match the HTTPRoute hostname, and resolve from
both user machines and cluster pods. Treat changing it as a coordinated
cutover across every SSO consumer, not a rename.

## Consumers

Anything that speaks OIDC: Grafana, kubectl (via OIDC auth), internal
tools. The consumer that motivated this app is PostgreSQL 18's native
OAuth — psql runs the device authorization flow against the public `psql`
static client (commented in `helm_secrets.yaml`), and Postgres validates
the resulting JWT through a validator library configured with this
issuer. The database template
(`apps/templates/cnpg-database/db-cluster.yaml`) ships this wiring as a
`pg-oauth` marker block — deliberately separate from the `dex` marker,
since it additionally requires building a validator extension image
(Postgres ships none; e.g. Percona-Lab's `pg_oidc_validator`), Kubernetes
1.35+ image volumes, and curl-enabled psql 18 on developer machines. The
block's comments carry the details; the `issuer=` in `pg_hba` must equal
`config.issuer` exactly.

### Grafana

Both monitoring stacks ship a commented `dex` marker block wiring
`auth.generic_oauth` at this issuer. To turn it on:

1. Deploy this app with the upstream connector's groups support configured
   (the Grafana role mapping reads the `groups` claim; without it everyone
   lands as Viewer).
2. `./toggle_blocks.sh --enable dex`, then replace the placeholder group
   addresses in `role_attribute_path`.
3. Generate one secret (`openssl rand -hex 24`) into both sides: the
   `grafana` entry in this app's `helm_secrets.yaml` (edit encrypted files
   with `sops`) and `GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET` in the monitoring
   app's `grafana-oidc-client.secrets.yaml`. Grafana reads the secret from
   that env var (`envFromSecret` in the monitoring app's values.yaml) rather
   than from `grafana.ini`: the chart renders that whole section into a
   world-readable ConfigMap, and its `assertNoLeakedSecrets` check fails the
   render if a plaintext secret appears there.

The local admin login form stays enabled as break-glass for when Dex or
the upstream IdP is down; SSO users get their role from group membership,
falling back to Viewer.

### Any HTTPRoute (Prometheus, Alertmanager, …)

For apps with no OIDC support of their own, Envoy Gateway's
`SecurityPolicy` OIDC filter runs the login at the gateway: browsers get
redirected to dex, authenticate upstream, and return with a session
cookie — the app itself never learns about auth. The same `dex` marker
enables `oidc-securitypolicy.yaml` in both monitoring stacks, covering
Alertmanager plus vmui (victoria-metrics) or Prometheus
(kube-prometheus-stack). With `cookieDomain` set to the parent domain,
one login covers every protected hostname.

Wiring for a new route: add its `/oauth2/callback` URL to the
`envoy-gateway` staticClient here, and either add the route to an
existing policy's `targetRefs` (same namespace only) or copy the policy
into the route's app. The client secret pairs three ways — the
staticClient here and `eg-oidc-client.secrets.yaml` in each monitoring
app — one generated value in all of them.

Two cautions: never target the dex or grafana routes (dex would put the
login behind the login; Grafana runs its own OIDC and the filter breaks
its callback), and note kube-prometheus-stack ships htpasswd basic auth
on these routes — Envoy Gateway honors only the oldest SecurityPolicy
per route, so the swap must disable it:
`./toggle_blocks.sh --enable dex --disable basic-auth`. This gates the
browser path only; in-cluster consumers use service DNS and never cross
the gateway.

## State and upgrades

Dex's only state — auth requests, refresh tokens, signing keys — lives in
CRDs in this namespace via the `kubernetes` storage backend, so there is
no database to run and the deployment scales by adding replicas. Chart
upgrades are the usual `release.yaml` version bump; check the
[dexidp/helm-charts](https://github.com/dexidp/helm-charts) release notes.
