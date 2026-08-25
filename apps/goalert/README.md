# GoAlert

[GoAlert](https://github.com/target/goalert) on-call scheduling, escalation policies, and paging, served at <https://goalert.devops.coop> (private Gateway — see the tradeoff note in `httproute.yaml`). It is the alerting tail of the alternative observability stack: the Alertmanager in `apps/victoria-metrics` routes alerts to it, and GoAlert decides who gets paged, how, and what happens when they don't answer.

Why GoAlert: Grafana OnCall OSS went into maintenance mode in March 2025 and its repo was archived in March 2026, which leaves GoAlert (built and run by Target, actively maintained) as the serious self-hosted on-call scheduler. There is no official Helm chart and the community ones are stale toys, so this app is plain manifests: a CloudNativePG `Cluster` for Postgres (`db-cluster.yaml`) plus a stateless Deployment (`deployment.yaml`) — GoAlert keeps all state in the database and applies its own schema migrations at startup.

## First run

1. Before the first deploy, create the data-encryption key (see below). Flux blocks on the SOPS Secret existing.
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

`data-encryption-key.secrets.yaml` (SOPS) holds `GOALERT_DATA_ENCRYPTION_KEY`. GoAlert passes it through a key derivation function and encrypts sensitive data it stores in Postgres (e.g. signing keys) with the result — so it can be any string, but losing or changing it invalidates that data, and every replica must use the same value. To create or rotate: recreate `data-encryption-key.secrets.yaml.decrypted` (see git history for the shape), fill in a value from `openssl rand -base64 32`, and run `../../encrypt_secrets.sh`.

## Wiring Alertmanager to GoAlert

Alerts enter GoAlert through a per-service integration key:

1. In GoAlert, open the service that should own the alerts → **Integration Keys** → create one with **Key Type: Prometheus Alertmanager**, and copy the generated URL. It has the shape:

   ```text
   https://goalert.devops.coop/api/v2/prometheusalertmanager/incoming?token=<integration-key>
   ```

2. In `apps/victoria-metrics`, add a webhook receiver and a route to the Alertmanager config. The URL embeds the integration key — anyone holding it can open (and close) alerts — so the receiver belongs in that app's `helm_secrets.yaml`, not `values.yaml`:

   ```yaml
   route:
     routes:
       - receiver: goalert
         matchers:
           - severity = critical
   receivers:
     - name: goalert
       webhook_configs:
         - url: https://goalert.devops.coop/api/v2/prometheusalertmanager/incoming?token=<integration-key>
           send_resolved: true
   ```

   `send_resolved: true` lets GoAlert auto-close the alert when Alertmanager resolves it.

## Notification channels

Out of the box GoAlert only "notifies" via the web UI. Contact methods that actually page someone — Twilio SMS/voice, Slack, email — are configured after first login on the **Admin** page (stored in the database, not in this repo); only the inbound-email SMTP listener is a startup flag. See the [GoAlert docs](https://goalert.me/) for provider setup. Out of scope here.
