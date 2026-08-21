# Uptime Kuma

[Uptime Kuma](https://github.com/louislam/uptime-kuma) site monitoring
(Helm chart via `release.yaml`), served at
<https://status.devops.coop>.

## AutoKuma

[AutoKuma](https://github.com/BigBoot/AutoKuma) provides config-as-code for
the Uptime Kuma instance and deploys alongside it from this directory
(`deployment.yaml`/`pvc.yaml`). Uptime Kuma keeps all of its
configuration in a SQLite database with no declarative API, so this Deployment
reconciles the definitions in [`monitors/`](monitors/) into the running
instance over its socket.io API.

### Adding or changing a monitor

1. Create or edit a `.toml`/`.json` file under `monitors/`. The **filename is
   the AutoKuma id** of the entity. Example `monitors/website.toml`:

   ```toml
   type = "http"
   name = "Website"
   url = "https://devops.coop/"
   max_retries = 3
   ```

   Keep definitions minimal — declare only fields that differ from Uptime
   Kuma's defaults (`monitorDefaults` in Uptime Kuma's `EditMonitor.vue`).
   Omitted fields are left untouched on an existing monitor (AutoKuma merges
   definitions over current server state — `serde_merge::omerge` in its
   `entity.rs`) and take Uptime Kuma's defaults on creation. That is why the
   monitors here declare `expiryNotification = true`: the default is `false`,
   and we want cert-expiry alerts.

2. If the file is new, list it under `configMapGenerator:` in
   [`kustomization.yaml`](kustomization.yaml) (kustomize does not glob).
3. Commit and push. Flux updates the ConfigMap, the content-hash suffix change
   rolls the Deployment, and AutoKuma creates/updates the monitor.

Deleting a definition file deletes the monitor in Uptime Kuma
(`AUTOKUMA__ON_DELETE=delete`). AutoKuma only ever deletes entities it created
itself — monitors made by hand in the UI are never touched, but that also
means it cannot *adopt* them: a UI-created monitor that you re-declare in
`monitors/` will be duplicated, and the UI original must be deleted manually
(e.g. with `kuma-cli monitor delete`).

Beyond plain monitors, files can declare `type = "group"`, `"notification"`,
`"tag"`, and `"status_page"` — see the
[entity examples](https://github.com/BigBoot/AutoKuma/tree/master/monitors)
and cross-reference fields like `parent_name` and `notification_name_list`
(they take AutoKuma ids, i.e. filenames, not display names).

**The status page is deliberately NOT managed here.** AutoKuma's status page
model references monitors by database id (`publicGroupList[].monitorList[].id`)
with no name resolution, and the page's logo is an uploaded file living on the
uptime-kuma volume — neither survives declarative management. Keep editing the
status page in the UI at <https://status.devops.coop/status/default>.

### Credentials

AutoKuma logs in with the Uptime Kuma admin account, from the
`autokuma-kuma-credentials` Secret (`kuma-credentials.secrets.yaml`, SOPS).
To rotate: recreate `kuma-credentials.secrets.yaml.decrypted` (see git history
for the shape), fill in `stringData`, and run `../../encrypt_secrets.sh`.

### kuma-cli

[`kuma-cli`](https://github.com/BigBoot/AutoKuma#kuma-cli) (same project) is
handy for inspecting live state or exporting existing entities as JSON to seed
new definition files. No Homebrew formula — download the `kuma-mac`/`kuma-linux`
binary from the GitHub releases page. Log in once, storing a token so the
password doesn't end up in shell history:

```shell
kuma-cli --url https://status.devops.coop \
  --username <user> --password '<pass>' --store-token login
kuma-cli --url https://status.devops.coop monitor list
kuma-cli --url https://status.devops.coop monitor get <id>
```
