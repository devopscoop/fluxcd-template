# GoAlert

[GoAlert](https://github.com/target/goalert) on-call scheduling, escalation policies, and paging, served at <https://goalert.project1-dev.devops.coop> (public Gateway, so on-call can reach it from a phone off VPN — see the tradeoff note in `values.yaml`'s `httpRoute` block). It is the alerting tail of the observability stack: the Alertmanager in `apps/victoria-metrics` routes alerts to it, and GoAlert decides who gets paged, how, and what happens when they don't answer.

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

4. Log in at <https://goalert.project1-dev.devops.coop> and build the on-call structure: users → rotations → schedules → an escalation policy → a service. [Recommended on-call structure](#recommended-on-call-structure-follow-the-sun) below lays out a follow-the-sun version.

## Data-encryption key

`helm_secrets.yaml` (SOPS) holds `GOALERT_DATA_ENCRYPTION_KEY` under the chart's `envSecret` key — the chart creates a Secret from it and envFroms it into the Deployment. GoAlert passes the value through a key derivation function and encrypts sensitive data it stores in Postgres (e.g. signing keys) with the result — so it can be any string, but losing or changing it invalidates that data, and every replica must use the same value. Before bootstrap: fill a value from `openssl rand -base64 32` into `helm_secrets.yaml.decrypted` and run `../../encrypt_secrets.sh`. On a running cluster: edit in place with `sops helm_secrets.yaml`.

## Recommended on-call structure: follow-the-sun

For a team spread across APAC, EMEA, and AMER, the structure is one schedule per tier, with each region owning a slice of the day, rather than one schedule per person. Each region gets its own rotations, and a single schedule stitches the three regions together using assignment rules. GoAlert's [Schedules](https://goalert.me/docs/goalert-features/schedules/) docs name this use for rules (sharing an on-call schedule between Minneapolis and Bangalore), and [Alerting Configuration](https://goalert.me/docs/alerting/) walks through that two-region case.

### Anchor the windows in UTC

A schedule has one time zone, and its assignment rules are evaluated in that zone. You could instead build per-region schedules in local time, but the US, EU, and Australia change clocks on different dates and Singapore doesn't change at all, so local windows would open hour-long gaps twice a year. A single schedule in UTC guarantees the three windows always tile 24 hours exactly. The cost is that each region's local hours slide by an hour across DST.

Suggested windows, assuming APAC is roughly Singapore/Sydney, EMEA is London, and AMER is the US West Coast:

| Region | UTC window | Local hours |
| --- | --- | --- |
| APAC | 00:00–08:00 | 8am–4pm Singapore; 10–11am to 6–7pm Sydney |
| EMEA | 08:00–16:00 | 8am–4pm (winter) / 9am–5pm (summer) London |
| AMER | 16:00–24:00 | 8am–4pm (winter) / 9am–5pm (summer) US Pacific |

### Rotations (6)

Create a primary and a secondary rotation per region. All six are weekly, shift length 1, time zone UTC, with the handoff on Monday at the start of that region's window, so a handoff never lands mid-shift:

| Rotations | Handoff |
| --- | --- |
| APAC Primary, APAC Secondary | Mon 00:00 UTC |
| EMEA Primary, EMEA Secondary | Mon 08:00 UTC |
| AMER Primary, AMER Secondary | Mon 16:00 UTC |

Both rotations in a region hold the same engineers. In the secondary, use **Set Active** on a different person than the primary's active one, so each engineer cycles through a primary week, a secondary week, and then off weeks until their turn comes round again. With the same order in both, picking the person just before the primary's active one makes last week's primary this week's secondary, so the backup already has context.

### Schedules (2), both in UTC

- **Follow-the-Sun Primary** has three assignments, all Sun–Sat: APAC Primary (00:00–08:00), EMEA Primary (08:00–16:00), and AMER Primary (16:00–24:00, entered as an end time of 00:00 — a rule whose end is before its start runs past midnight).
- **Follow-the-Sun Secondary** has the same three windows, using the Secondary rotations.

After saving, open the **Shifts** view on each schedule (the calculated result after assignments, rules, and overrides) and confirm there are no gaps at the 00:00, 08:00, and 16:00 boundaries.

### Escalation policy (1)

Name it `Production – Follow-the-Sun`, and point the service that holds the Alertmanager integration key (see [Wiring Alertmanager to GoAlert](#wiring-alertmanager-to-goalert)) at it:

1. Follow-the-Sun Primary, wait 15 min.
2. Follow-the-Sun Secondary, wait 15 min.
3. An engineering lead (or a small "escalation" rotation), plus your incidents Slack channel (Slack targets need Slack set up first — see [Notification channels](#notification-channels)).

Repeat: 3 times.

Keeping both tiers in the same region means a page never wakes someone in another hemisphere just because the primary was in the shower.

### Operational notes

- **Holidays** are regional, so handle them with **Replace** overrides within the region, such as an EMEA engineer covering for an EMEA colleague. Don't try to hand a holiday to another region: those hours fall outside their window, in their night.
- **Weekends**: if you don't want weekend coverage, drop Sat/Sun from the rules. AMER's Friday window ends at Saturday 00:00 UTC, so it still reads as Friday locally — keep Friday in that rule.

## Wiring Alertmanager to GoAlert

Alerts enter GoAlert through a per-service integration key:

1. In GoAlert, open the service that should own the alerts → **Integration Keys** → create one with **Key Type: Prometheus Alertmanager**, and copy the generated URL. It has the shape:

   ```text
   https://goalert.project1-dev.devops.coop/api/v2/prometheusalertmanager/incoming?token=<integration-key>
   ```

2. In `apps/victoria-metrics`, paste the URL into the `webhook_configs` entry of the `default` receiver in that app's Alertmanager config, with the scheme and host swapped for GoAlert's in-cluster Service (`http://goalert.goalert.svc.cluster.local:8081`) — keep the path and token. The URL embeds the integration key — anyone holding it can open (and close) alerts — so it belongs in that app's `helm_secrets.yaml`, not `values.yaml`:

   ```yaml
   receivers:
     - name: default
       slack_configs:
         # ... GoAlert shares this receiver with Slack: the Alertmanager UI
         # lists each alert group once per receiver, so a separate goalert
         # receiver would display every alert twice.
       webhook_configs:
         - url: http://goalert.goalert.svc.cluster.local:8081/api/v2/prometheusalertmanager/incoming?token=<integration-key>
           send_resolved: true
   ```

   `send_resolved: true` lets GoAlert auto-close the alert when Alertmanager resolves it.

   Why the in-cluster Service and not the public URL: the public URL goes out through public DNS and back in through `eg-public`, and that path drops alerts.

   - With [Coraza](../coraza/README.md) enabled, the WAF inspects every webhook body. Alert annotations are free text, and runbook snippets in them read as attacks: a SQL query in a `description` trips CRS 942190, one critical match per alert in the group. The WAF answers with a 403, Alertmanager treats a 4xx as unrecoverable and never retries, and that alert stops paging while still showing in Slack and the Alertmanager UI. The only trace is `unexpected status code 403` in the Alertmanager logs.
   - The gateway's access logs record the full request path, query string included, so every notification writes the integration key to them.
   - Paging also depends on public DNS and the gateway being up. A failed lookup of the public hostname has blocked delivery before.

   The in-cluster hop is plain HTTP on the pod network, the same as Alertmanager's other in-cluster traffic. GoAlert accepts it: its HTTP→HTTPS redirect only fires for requests whose Host matches `GOALERT_PUBLIC_URL`, and integration-key auth doesn't check the Referer.

## Notification channels

Out of the box GoAlert only "notifies" via the web UI. Contact methods that actually page someone — Twilio SMS/voice, Slack, email — are configured after first login on the **Admin** page (stored in the database, not in this repo); only the inbound-email SMTP listener is a startup flag. See the [GoAlert docs](https://goalert.me/) for provider setup. Out of scope here.

## Monitoring

GoAlert serves Prometheus metrics on `:2112` (`GOALERT_LISTEN_PROMETHEUS` in values.yaml), scraped by `vmpodscrape.yaml`; `vmrule.yaml` pages when the engine stops cycling, notifications stop leaving, or the webhook endpoint errors. The database is covered by the fleet-wide cnpg-instances scrape (see db-cluster.yaml's monitoring note).

The caveat: those rules route *through* GoAlert, so when they fire, only the Slack half of the combined Alertmanager receiver is guaranteed to deliver. The genuinely external check is still open: point an Uptime Kuma `push` monitor at the Watchdog alert (which is currently blackholed — apps/victoria-metrics/README.md → "Alert routing") so something outside the stack notices the stack going quiet.
