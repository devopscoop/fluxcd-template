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
- Image is digest-pinned to 1.6.5 (upstream publishes `linux/amd64`,
  `linux/arm/v7` and `linux/arm64`). Upstream re-pushes release tags, so
  re-derive the digest from the tag when bumping rather than trusting an old
  one.

## Before this can be enabled

1. **MongoDB.** Gathio needs one and this repo ships none. `groundhog2k/mongodb`
   is the least machinery: a plain StatefulSet around the official `mongo`
   image, no operator and no CRDs, and its `userDatabase` block runs
   `createUser` inside the application database, so the connection string needs
   no `?authSource=admin`. Bitnami's chart can only pull
   `bitnami/mongodb:latest` since the August 2025 catalogue change moved every
   pinned tag to the frozen `bitnamilegacy` repo; Percona's `psmdb` operator is
   the right answer only if you want replica sets and PBM backups.
   Put the URL in `helm_secrets.yaml` and run `./encrypt_secrets.sh`.
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
- Gathio 1.6.x pins `mongoose ^5.13.22` (Node driver 3.x), which MongoDB only
  officially supports against server 4.4 and older. Upstream runs `mongo:latest`
  in `docker-compose.yml` and CI, so current servers work in practice — pin an
  explicit tag rather than tracking `latest`. On x86-64, MongoDB 5.0+ requires
  AVX support on the node CPU.

## Local prototyping

```shell
helm install gathio oci://registry.gitlab.com/devopscoop/charts/app \
  --namespace gathio --version 0.11.1 \
  --values values.yaml --values <(sops -d helm_secrets.yaml)
```
