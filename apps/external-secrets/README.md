# external-secrets

[External Secrets Operator](https://external-secrets.io/) (ESO) turns
`ExternalSecret` objects in git into ordinary Kubernetes Secrets whose
values it reads from OpenBao (`apps/openbao`). Apps keep consuming plain
Secrets and never talk to OpenBao themselves. What git records is *which*
secret an app gets (a path, a key, optionally a pinned version), never the
value.

It reads through one `ClusterSecretStore` named `openbao`
(`apps/external-secrets-custom-resources/clustersecretstore.yaml`): OpenBao's
kv v2 engine at `secret/`, over TLS to the active node, logged in as this
controller's ServiceAccount with a 10-minute, audience-bound token. Its
OpenBao policy (`apps/openbao/policies/external-secrets.hcl`) is read-only.

This app is optional. Enable it together with OpenBao, as described in
`apps/openbao/README.md` → "Enabling".

## Adding a secret

Use one path per Kubernetes Secret, laid out as
`secret/<namespace>/<secret-name>`. Write it as the admin role
(`apps/openbao/README.md` → "Administering OpenBao"), passing values on
stdin so they stay out of shell history:

```shell
bao kv put secret/my-app/api-credentials - <<'EOF'
{"clientId": "...", "clientSecret": "..."}
EOF
```

Then commit an `ExternalSecret` next to the app that uses it (in the app's
`kustomization.yaml` `resources`, like any other manifest):

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: api-credentials
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: openbao
  target:
    name: api-credentials
  dataFrom:
    - extract:
        key: my-app/api-credentials
```

The `key` is the path without the `secret/` mount. `dataFrom.extract` copies
every field into the Secret. To pick and rename fields, use `data` with
`remoteRef.property` instead. The app's Flux Kustomization must `dependsOn`
`external-secrets-custom-resources`: the `ExternalSecret` CRD has to exist
before Flux's dry-run.

## Helm values secrets

The Helm app pattern's `helm_secrets.yaml` (a SOPS-encrypted values file,
see AGENTS.md → "The Helm app pattern") becomes an `ExternalSecret` that
renders a `values.yaml` key. Point `valuesFrom` at it in place of the
generated `<app>-secrets` Secret, and drop the `secretGenerator` entry and
`helm_secrets.yaml`. For `apps/falcon-platform`, with its three values in
`secret/falcon-platform/helm-values`:

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: falcon-platform-secrets
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: openbao
  target:
    name: falcon-platform-secrets
    template:
      metadata:
        labels:
          # helm-controller watches Secrets with this label and upgrades the
          # release when one changes. Without it, a changed value only lands
          # on the next unrelated upgrade.
          reconcile.fluxcd.io/watch: Enabled
      data:
        values.yaml: |
          global:
            containerRegistry:
              configJSON: {{ .configJSON | quote }}
          falcon-image-analyzer:
            crowdstrikeConfig:
              clientID: {{ .clientID | quote }}
              clientSecret: {{ .clientSecret | quote }}
  dataFrom:
    - extract:
        key: falcon-platform/helm-values
```

## Seeing value changes in git

By default an `ExternalSecret` follows the latest version of its path, so
`bao kv put` changes the Secret within `refreshInterval` and git never
sees it. OpenBao still records it: the audit log, plus kv v2's version
history (`bao kv metadata get secret/<path>`).

If a secret should only change through a reviewed commit, pin the version.
The change then takes two steps, `bao kv put` and a commit bumping
`version`, and the commit shows up in git log and in the PR's flux-diff:

```yaml
  data:
    - secretKey: clientSecret
      remoteRef:
        key: my-app/api-credentials
        property: clientSecret
        version: "3"
```

## Migrating a SOPS secret

1. Decrypt it and write it to OpenBao. For a `*secrets.yaml` Kubernetes
   Secret:

   ```shell
   sops -d apps/<app>/<name>.secrets.yaml \
     | yq -o=json '(.stringData // {}) + ((.data // {}) | map_values(@base64d))' \
     | bao kv put secret/<namespace>/<name> -
   ```

   For a `helm_secrets.yaml`, store the individual values and template them
   back as shown above.
2. Replace the encrypted file with an `ExternalSecret` that produces a
   Secret of the same name and keys, and remove the file from the
   kustomization, in one commit. Check the rendered diff in the PR's
   flux-diff comment.
3. **Rotate the value.** Moving a secret into OpenBao keeps its *future*
   values out of git, but the old ciphertext stays in git history forever,
   so anyone with the repo and the age key can still read the migrated
   value. Issue a new credential upstream, `bao kv put` it, and revoke the
   old one.
