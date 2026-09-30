# openbao

[OpenBao](https://openbao.org/) (the Linux Foundation's MPL-2.0 fork of
Vault) as the cluster's secret store: a 3-node Raft cluster that
auto-unseals, serves TLS from a private cert-manager CA, and hands secrets to
workloads only through `apps/external-secrets`. Secret values live in
OpenBao, and git holds only references to them (`ExternalSecret` objects).

Why this over SOPS-encrypted files: with SOPS, the repo plus one age private
key decrypts every secret the repo has ever held, all of git history
included. Here, a leaked repo contains no ciphertext. Reading a secret
takes a live, authenticated OpenBao session (every read is audit-logged).
Decrypting stolen storage takes the Raft data plus the unseal key: a KMS
key that never leaves AWS on EKS, and even the static key used elsewhere is
never committed.

This app is optional and not in `deploy.sh`'s app lists. It comes with
`apps/external-secrets` (the operator) and
`apps/external-secrets-custom-resources` (the `ClusterSecretStore`); see
[Enabling](#enabling).

## Before deploying

Auto-unseal needs a key, and which one depends on the platform.

### EKS: AWS KMS

`deploy.sh` enables the `eks` blocks in `values.yaml`, which switch the seal
to AWS KMS through IRSA. Create both of these (in aws-eks-template, next to
the other IRSA roles):

1. A symmetric KMS key with the alias `alias/openbao-project1-dev` (the
   `awskmsSeal.kmsKeyId` in `values.yaml`). Never schedule it for deletion:
   without it the data can't be decrypted, backups included.
2. An IRSA role named `openbao`, trusted by the cluster's OIDC provider for
   `openbao:openbao` (namespace:ServiceAccount), allowed to call
   `kms:Encrypt`, `kms:Decrypt` and `kms:DescribeKey` on that key. Put its
   ARN in the `eks.amazonaws.com/role-arn` annotation in `values.yaml`
   (replace `ACCOUNT_ID`).

Since OpenBao 2.7 the AWS KMS seal is a plugin, not built in. The config
pins its OCI image by digest, and the pods download it from `ghcr.io` on
first start and cache it on their data volume.

### Everywhere else: static key

The `static` seal reads a 32-byte key from the `openbao-unseal-key` Secret.
Create the Secret yourself, before the pods start; it is never committed:

```shell
kubectl create namespace openbao
openssl rand 32 | kubectl -n openbao create secret generic openbao-unseal-key --from-file=key=/dev/stdin
```

Save a copy in the organization's password manager
(`kubectl -n openbao get secret openbao-unseal-key -o jsonpath='{.data.key}'`
prints it base64-encoded). Losing it means losing every secret in OpenBao.
Anyone who can read the Secret and also gets a copy of the Raft data can
decrypt everything, so it is weaker than a KMS. It is still far narrower
than an age key that decrypts the whole git history.

To rotate it, follow upstream's
[static seal key rotation](https://openbao.org/docs/configuration/seal/static/#key-rotation):
set `previous_key`/`previous_key_id` to the current key and `current_key`
to a new file in the same Secret, then restart the pods. This procedure
hasn't been exercised in this repo.

## Enabling

Register all three apps and turn on their monitoring:

```shell
for app in openbao external-secrets external-secrets-custom-resources; do
  yq -i ".resources = (.resources + [\"${app}.yaml\"] | unique)" flux/flux-system/kustomization.yaml
done
./toggle_blocks.sh --enable openbao,external-secrets
```

On a bootstrapped cluster repo, `deploy.sh` has deleted
`apps/victoria-metrics-custom-resources/openbao-vm.yaml` and
`external-secrets-vm.yaml`. Restore them from fluxcd-template before
toggling (AGENTS.md → "Monitoring conventions").

Flux orders the three apps: `openbao` waits for `cert-manager`, and
`external-secrets-custom-resources` waits for both `external-secrets` and
`openbao`. The `ClusterSecretStore` stays not Ready, and so does its Flux
Kustomization, until you've done the [first start](#first-start).

## First start

The pods come up Ready but uninitialized: the readiness probe accepts
sealed and uninitialized nodes on purpose (see the comment in
`values.yaml`). Initialize once, from any one pod:

```shell
kubectl -n openbao exec openbao-0 -c openbao -- bao operator init
```

This prints five **recovery keys** and a **root token**. Store all of them
in the organization's password manager right away, because they are shown
only once. With auto-unseal, the recovery keys never unseal anything. Three
of them are needed to generate a new root token (`bao operator
generate-root`), which is the break-glass path if the admin role ever stops
working.

The other two nodes join through Raft `retry_join` and unseal themselves
within seconds. Then apply the configuration, using the root token this one
time, and revoke it; the admin role replaces it:

```shell
read -rs -p 'Root token: ' BAO_TOKEN && export BAO_TOKEN
apps/openbao/configure.sh
kubectl -n openbao exec openbao-0 -c openbao -- env BAO_TOKEN="$BAO_TOKEN" bao token revoke -self
unset BAO_TOKEN
```

`configure.sh` enables the kv v2 engine at `secret/`, the Kubernetes auth
method, the policies in `policies/`, and the `admin` and `external-secrets`
roles.

Within a minute the `ClusterSecretStore` turns Ready. Continue in
`apps/external-secrets/README.md` to add secrets.

Why not OpenBao's declarative self-initialization (the `initialize` config
stanza)? With Raft `retry_join`, a node that starts on an empty volume can
initialize a second, separate cluster instead of joining the first
([openbao/openbao#3652](https://github.com/openbao/openbao/issues/3652),
open as of 2.7.0). That happened here on the very first install when this
was tested. It also runs only once, so it could never roll out a later
policy change.

## Administering OpenBao

There are no long-lived admin tokens. The `admin` role accepts a short-lived
token for the `openbao-admin` ServiceAccount, so anyone allowed to create
tokens for it is an OpenBao admin, and access follows Kubernetes RBAC:

```shell
kubectl -n openbao get secret openbao-server-tls -o jsonpath='{.data.ca\.crt}' | base64 -d > /tmp/openbao-ca.crt
kubectl -n openbao port-forward svc/openbao-active 8200:8200 &
export BAO_ADDR=https://127.0.0.1:8200 BAO_CACERT=/tmp/openbao-ca.crt
export BAO_TOKEN=$(kubectl -n openbao create token openbao-admin --audience openbao --duration 10m \
  | bao write -field=token auth/kubernetes/login role=admin jwt=-)
```

The resulting OpenBao token lasts 1h (8h max with `bao token renew`). The
`bao` CLI is the `openbao` package in `Brewfile`/`pkglist.txt`.

Policies and roles are code: edit `policies/*.hcl` or the roles at the
bottom of `configure.sh`, get the change reviewed, then run
`apps/openbao/configure.sh`. With no `BAO_TOKEN` set, it logs in as above
and revokes its token when done. It never deletes anything, so remove a
dropped policy or role by hand.

## Operations

- **Audit log**: every request and response goes to the pods' stdout,
  HMAC'd so secret values never appear in clear, and from there into
  VictoriaLogs. OpenBao refuses requests it can't audit, which is what
  `OpenBaoAuditLogFailing` pages for.
- **Upgrades**: the StatefulSet uses `updateStrategyType: OnDelete` (the
  chart default), so a chart or image bump restarts nothing on its own.
  Delete the standby pods one at a time, waiting for each to rejoin
  (`bao operator raft list-peers`), then the active one. Bump the image tag
  of the `plugin-directory` init container and the `tls-reloader` sidecar
  in `values.yaml` with the chart.
- **Certificates**: the server certificate renews every 60 days, and the
  `tls-reloader` sidecar sends OpenBao a SIGHUP when the mounted file
  changes, so there is no restart. The CA in `tls.yaml` lasts 10 years.
- **Backups**: take Raft snapshots as the admin role with
  `bao operator raft snapshot save openbao.snap`. A snapshot is only
  readable with the unseal key (the KMS key on EKS), which is the point, so
  keep that key's lifecycle in mind. The chart's `snapshotAgent` (a CronJob
  that ships snapshots to S3) is not wired up yet.
- **Losing a node's volume**: the replacement pod rejoins through
  `retry_join` and replicates everything from the leader. This was tested
  by deleting a PVC.
