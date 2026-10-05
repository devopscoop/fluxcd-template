# renovate

[Renovate](https://docs.renovatebot.com/) keeps dependencies current. It finds the dependency files in a repo, looks up newer versions in their registries, and lists every available update on a Dependency Dashboard issue in that repo. This app runs it from the [official chart](https://github.com/renovatebot/helm-charts) as a CronJob. Every weekday at 10:33 UTC a Job starts one pod, which works through each repo and exits. Nothing runs between runs.

New repos default to dashboard-only mode. Renovate opens a PR for an update only after someone ticks its box on the dashboard.

This app is optional and not in `deploy.sh`'s app lists.

## Setup

1. Create a GitHub App in the organization's settings under Developer settings → GitHub Apps. Turn off the webhook. Give it these repository permissions, from [Renovate's GitHub docs](https://docs.renovatebot.com/modules/platform/github/#running-as-a-github-app):

   | Permission        | Access         |
   | ----------------- | -------------- |
   | Checks            | Read and write |
   | Commit statuses   | Read and write |
   | Contents          | Read and write |
   | Issues            | Read and write |
   | Pull requests     | Read and write |
   | Workflows         | Read and write |
   | Administration    | Read           |
   | Dependabot alerts | Read           |
   | Metadata          | Read           |

   Add the organization permission Members: Read.

2. Generate a private key on the app's General page. Install the app on the repos Renovate should manage. Renovate discovers repos through the installation, so the installation's repo list is the only list to maintain.

3. Fill in `github-app.secrets.yaml.decrypted` with the App ID, the installation ID, and the full PEM private key. Encrypt it with `./encrypt_secrets.sh`.

4. Register the app the same way `deploy_new_app.sh --deploy` would:

   ```shell
   yq -i '.resources = (.resources + ["renovate.yaml"] | unique)' flux/flux-system/kustomization.yaml
   ```

To start a run without waiting for the schedule, for example right after ticking a box on a dashboard:

```shell
kubectl -n renovate create job --from=cronjob/renovate "renovate-manual-$(date +%s)"
```

The first run opens a "Configure Renovate" PR in each repo. Merging it adds the repo's `renovate.json` and creates the dashboard issue. To let Renovate open PRs on its own in a repo, remove `dependencyDashboardApproval` from that repo's `renovate.json`.

## Authentication

Renovate signs in with a GitHub App installation token, which expires after one hour and which Renovate cannot mint from the app's private key. The `github-app-token` init container mints a fresh token for every run and passes it to Renovate through an in-memory volume. The private key is mounted only into the init container. The Renovate container runs package-manager commands from the repos it updates, so it never sees the key.

Because the token expires after an hour, `activeDeadlineSeconds` stops a run after 55 minutes.

## Monitoring

Renovate has no metrics endpoint, so this app adds no scrape. A failed run fires `KubeJobFailed`, a warning from the bundled `kubernetes-apps` rules in `apps/victoria-metrics`, which pages. The alert keeps firing until the failed Job is deleted:

```shell
kubectl -n renovate delete job <job-name>
```

The run's logs are in the cluster's log store under the `renovate` namespace.

## Upgrading

Bump the chart tag in `ocirepo.yaml`. Then set the init container's image in `values.yaml` to the new chart's `appVersion`, so both containers run the same Renovate release.
