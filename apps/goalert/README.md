# GoAlert

[GoAlert](https://github.com/target/goalert) on-call scheduling, escalation policies, and paging, served at <https://goalert.devops.coop> (public Gateway, so on-call can reach it from a phone off VPN — see the tradeoff note in `values.yaml`'s `httpRoute` block). It is the alerting tail of the observability stack: the Alertmanager in `apps/victoria-metrics` routes alerts to it, and GoAlert decides who gets paged, how, and what happens when they don't answer.

Why GoAlert: Grafana OnCall OSS went into maintenance mode in March 2025 and its repo was archived in March 2026, which leaves GoAlert (built and run by Target, actively maintained) as the serious self-hosted on-call scheduler. GoAlert publishes no Helm chart of its own and the community ones are stale toys, so this app runs the image on the generic [devopscoop app chart](https://github.com/devopscoop/charts/tree/main/devopscoop/app) (the same chart `deploy_new_app.sh` scaffolds with): the chart renders the Deployment, Service, and HTTPRoute from `values.yaml`, and a CloudNativePG `Cluster` (`db-cluster.yaml`) provides Postgres — GoAlert keeps all state in the database and applies its own schema migrations at startup.

## First run

1. Before the first deploy, set the data-encryption key in `helm_secrets.yaml.decrypted` (see below). Nothing blocks on it — deploy.sh would happily encrypt the `CHANGEME` placeholder, which then silently becomes the key.
2. Wait for the database and the app to come up (the flux Kustomization `dependsOn` cnpg, so ordering is handled; first boot also runs the schema migrations):

   ```shell
   kubectl -n goalert get cluster goalert-db   # wait for "Cluster in healthy state"
   kubectl -n goalert rollout status deploy/goalert
   ```

3. Create the first admin user with GoAlert's CLI inside the running pod (it reuses the pod's `GOALERT_DB_URL`; you are prompted for the password):

   ```shell
   kubectl -n goalert exec -it deploy/goalert -- \
     sh -c 'goalert add-user --admin --user admin --email admin@devops.coop --db-url "$GOALERT_DB_URL"'
   ```

4. Log in at <https://goalert.devops.coop> and build the on-call structure: users → a schedule → an escalation policy → a service.

## Data-encryption key

`helm_secrets.yaml` (SOPS) holds `GOALERT_DATA_ENCRYPTION_KEY` under the chart's `envSecret` key — the chart creates a Secret from it and envFroms it into the Deployment. GoAlert passes the value through a key derivation function and encrypts sensitive data it stores in Postgres (e.g. signing keys) with the result — so it can be any string, but losing or changing it invalidates that data, and every replica must use the same value. Before bootstrap: fill a value from `openssl rand -base64 32` into `helm_secrets.yaml.decrypted` and run `../../encrypt_secrets.sh`. On a running cluster: edit in place with `sops helm_secrets.yaml`.

## Wiring Alertmanager to GoAlert

Alerts enter GoAlert through a per-service integration key:

1. In GoAlert, open the service that should own the alerts → **Integration Keys** → create one with **Key Type: Prometheus Alertmanager**, and copy the generated URL. It has the shape:

   ```text
   https://goalert.devops.coop/api/v2/prometheusalertmanager/incoming?token=<integration-key>
   ```

2. In `apps/victoria-metrics`, paste the URL into the `webhook_configs` entry of the `default` receiver in that app's Alertmanager config. The URL embeds the integration key — anyone holding it can open (and close) alerts — so it belongs in that app's `helm_secrets.yaml`, not `values.yaml`:

   ```yaml
   receivers:
     - name: default
       slack_configs:
         # ... GoAlert shares this receiver with Slack: the Alertmanager UI
         # lists each alert group once per receiver, so a separate goalert
         # receiver would display every alert twice.
       webhook_configs:
         - url: https://goalert.devops.coop/api/v2/prometheusalertmanager/incoming?token=<integration-key>
           send_resolved: true
   ```

   `send_resolved: true` lets GoAlert auto-close the alert when Alertmanager resolves it.

## Notification channels

Out of the box GoAlert only "notifies" via the web UI. Contact methods that actually page someone — Twilio SMS/voice, Slack, email — are configured after first login on the **Admin** page (stored in the database, not in this repo); only the inbound-email SMTP listener is a startup flag. See the [GoAlert docs](https://goalert.me/) for provider setup. Out of scope here.
