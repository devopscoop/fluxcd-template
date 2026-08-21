# Gathio

[Gathio](https://github.com/lowercasename/gathio) — self-destructing, shareable,
no-registration event pages. Also the reference example for the in-house
`devopscoop/charts/app` chart in this repo.

Scaffolded with:

```shell
./deploy_new_app.sh gathio devopscoop oci://registry.gitlab.com/devopscoop/charts app 0.11.1
```

## How it is wired

- StatefulSet, because user-uploaded event images are written to disk at
  `/app/public/events`. That path is the `events` volumeClaimTemplate (5Gi).
- `config.yaml` holds the `config` ConfigMap, mounted over
  `/app/config/config.toml` — the only config file gathio reads (it looks for
  `./config/config.toml` relative to its `/app` workdir).
- Any string in `config.toml` can interpolate a `GATHIO_`-prefixed environment
  variable as `${GATHIO_FOO}`. The MongoDB URL is set that way, from
  `envSecret.GATHIO_MONGODB_URL` in `helm_secrets.yaml`.
- Image is digest-pinned to 1.6.5, written as `<version>@sha256:<digest>` like
  `apps/radicle` (upstream publishes `linux/amd64`, `linux/arm/v7` and
  `linux/arm64`). Upstream re-pushes release tags, so re-derive the digest from
  the tag when bumping rather than trusting an old one.

## Before this can be enabled

1. **MongoDB.** It lives in [`../mongodb-gathio`](../mongodb-gathio/README.md),
   in this same namespace, so the Service is
   `mongodb-gathio.gathio.svc.cluster.local:27017`. Fill in the credentials on
   both sides — `userDatabase` there and `GATHIO_MONGODB_URL` here — and run
   `./encrypt_secrets.sh`. Deploy `mongodb-gathio.yaml` too: this app
   `dependsOn` it, so Flux will not apply gathio until that Kustomization is
   ready.
1. **Gateway listener.** `values.yaml` attaches an HTTPRoute for
   `gathio.project1-dev.devops.coop`, but `eg-public` ships with only its `http`
   listener. Add an HTTPS listener with `certificateRefs` →
   `gathio-project1-dev-devops-coop-tls` to
   `apps/eg-custom-resources/gateway-public.yaml`, and make sure the hostname
   resolves so cert-manager's HTTP-01 challenge can complete.
1. **Contact email.** `config.yaml` has a placeholder address, and
   `mail_service` is `none`, so gathio sends no mail at all — event creators
   get no edit links by email — until it is set to
   `nodemailer`/`sendgrid`/`mailgun` with credentials in `helm_secrets.yaml`.
1. **Open instance.** `creator_email_addresses = []` means anyone who can reach
   the URL can create events, and `is_federated = true` publishes them over
   ActivityPub. Changing `domain` later breaks existing federated events.
1. Add `- gathio.yaml` to `flux/flux-system/kustomization.yaml`.

## Notes

- Gathio serves `/` without touching MongoDB, and `mongoose.connect` failures
  are only logged — so with the database down the pod still passes its probes
  and reports Ready, while every event operation 500s.
- The driver/server version caveat and the credential rotation procedure are in
  [`../mongodb-gathio/README.md`](../mongodb-gathio/README.md).

## Local prototyping

```shell
helm install gathio oci://registry.gitlab.com/devopscoop/charts/app \
  --namespace gathio --version 0.11.1 \
  --values values.yaml --values <(sops -d helm_secrets.yaml)
```
