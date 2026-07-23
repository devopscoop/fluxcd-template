# kube-prometheus-stack

## Slack alerts

Alertmanager can send every alert to a Slack channel. To enable it before running deploy.sh:

1. Create a [Slack incoming webhook](https://api.slack.com/messaging/webhooks) and put its URL in helm_secrets.yaml.decrypted (`alertmanager.config.global.slack_api_url`).
1. Set your channel in the `>>> slack` block in values.yaml.
1. Set `slack_alerts=true` in variables.sh. deploy.sh uncomments the `>>> slack` block and encrypts the webhook.

To enable it on an already-deployed cluster instead, uncomment the `>>> slack` block in values.yaml by hand (strip the leading `# ` between the markers, leaving the markers in place), and edit your webhook URL into the encrypted secrets with `sops helm_secrets.yaml`.

TODO:

- Enable persistence for prometheus metrics
