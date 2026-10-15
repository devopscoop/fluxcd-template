# Woodpecker CI

[Woodpecker CI](https://woodpecker-ci.org/) — a self-hosted CI server and agents on the [upstream Helm chart](https://github.com/woodpecker-ci/helm) (`release.yaml`), served at <https://woodpecker.project1-dev.devops.coop>. Pipelines are `.woodpecker/*.yaml` files in the repos; the agents run them on the Kubernetes backend, one pod per step, in this namespace. GitHub is the forge: users log in with GitHub OAuth, enable repos from the UI, and the server registers a webhook on each. State lives in PostgreSQL (`db-cluster.yaml`, a CloudNativePG cluster from `apps/templates/cnpg-database`, cert-authenticated), pipeline logs included. The comparison that picked Woodpecker over GitHub Actions on self-hosted runners is `arguments/woodpecker_vs_github_actions_arc.argdown`.

Opt-in: `deploy.sh` never registers this app. Add `woodpecker.yaml` to the `resources` list in `flux/flux-system/kustomization.yaml` (`yq -i '.resources += ["woodpecker.yaml"] | .resources |= unique' flux/flux-system/kustomization.yaml`), then follow the steps below.

## First run

1. Register a GitHub **OAuth App** (not a GitHub App: Woodpecker's docs warn those break token refresh) under the organization — Settings → Developer settings → OAuth Apps → New OAuth App — with Homepage URL `https://woodpecker.project1-dev.devops.coop` and Authorization callback URL `https://woodpecker.project1-dev.devops.coop/authorize`. Put the client id and a generated client secret into `helm_secrets.yaml.decrypted` and run `../../encrypt_secrets.sh` (on a running cluster: `sops helm_secrets.yaml`).
2. In `values.yaml`, set `WOODPECKER_ADMIN` to the GitHub usernames that administer the instance and `WOODPECKER_ORGS` to the organizations whose members may log in. Both before the first login: registration is closed to everyone else, and the first user in is not made admin.
3. On EKS, add the database to `local.cnpg_databases` in aws-eks-template `cluster/cnpg-backups.tf` (`{ woodpecker = "woodpecker-db" }`) and copy the bucket name and role ARN the apply outputs into `db-cluster.yaml` (the ObjectStore's `destinationPath` and the IRSA annotation's `ACCOUNT_ID`).
4. Let Flux reconcile; the flux Kustomization `dependsOn` cert-manager, cnpg, and cnpg-barman-plugin, so ordering is handled. First boot also runs the schema migrations:

   ```shell
   kubectl -n woodpecker get cluster woodpecker-db   # wait for "Cluster in healthy state"
   kubectl -n woodpecker rollout status statefulset/woodpecker-server
   kubectl -n woodpecker rollout status statefulset/woodpecker-agent
   ```

5. Turn on the monitoring with the app: `./toggle_blocks.sh --enable woodpecker` (see Monitoring below).
6. Log in at <https://woodpecker.project1-dev.devops.coop>, open **Repositories → Add repository**, and enable a repo. Woodpecker creates the webhook; the next push carrying a `.woodpecker/*.yaml` file runs.

## How pipelines run

Each step of a workflow is a pod in this namespace, created by the agent (the chart's Role grants it pods, pods/log, PVCs, Services, and Secrets here and nothing elsewhere). The steps of one workflow share a workspace volume — a temporary PVC the agent creates for the run and deletes after it — so every run starts clean. Two settings in `values.yaml` shape those pods: `WOODPECKER_BACKEND_K8S_STORAGE_RWX` is `false`, because the EBS-backed default storage class on EKS cannot provide ReadWriteMany, so a workflow's steps all land on one node (set it to `true` on a platform with a RWX default class); and on EKS the per-run volumes use `gp3-dangerous` (the `eks` marker block), keeping them out of the DLM snapshot policy.

Nothing persists between runs unless a pipeline step does it. This repo's assumption is the [S3 cache plugin](https://woodpecker-ci.org/plugins/s3-cache): restore and save steps keyed by branch (`{{branch}}-{{arch}}` by default; the pull request's source branch for PRs). It restores exactly one key with no fallback, so the convention for a cache that should warm pull requests is to read the default branch's key and limit the save step to pushes on that branch with `when`. The bucket and the credentials the plugin needs are not provided by this app — a per-organization Woodpecker secret, or a service account with IRSA named in `backend_options.kubernetes.serviceAccountName`, are the two options.

Privileged steps — image builds with the docker-buildx plugin, a Docker-in-Docker service — need two things this app ships without: the image listed in `WOODPECKER_PLUGINS_PRIVILEGED` on the server, and the repo marked trusted by an admin. Add both deliberately, per image, when the first build pipeline needs them. A BuildKit server in the cluster reached with the buildx remote driver is the alternative that keeps the step pods unprivileged.

## Database

`db-cluster.yaml` is the standard per-app CNPG cluster: three instances, synchronous replication, barman backups to S3, and client-certificate auth (`db-client-cert.yaml`) as the only login for the `woodpecker` role — the DSN in `values.yaml` carries no password. Woodpecker applies its own schema migrations at startup. Logs live in the database (`WOODPECKER_LOG_STORE=database`), so its 1Gi data volume (this repo's default) will need growing with pipeline volume, or old logs purged through the API. Connecting a client: `runbooks/connect-cnpg-database.md`; restoring: `runbooks/restore-cnpg-database.md`.

## Monitoring

The server serves Prometheus metrics on `:9001` (`WOODPECKER_METRICS_SERVER_ADDR` in `values.yaml`), scraped by `apps/victoria-metrics-custom-resources/woodpecker-vm.yaml`, whose VMRule pages when no agent is connected and warns when steps sit pending for 30 minutes. Both sit behind the `woodpecker` marker block in that app's `kustomization.yaml` — `./toggle_blocks.sh --enable woodpecker` turns them on with this app (restore `woodpecker-vm.yaml` from fluxcd-template first if `deploy.sh`'s removal step already deleted it). No dashboard is downloaded; `woodpecker-vm.yaml`'s header explains why. The database is covered by the fleet-wide cnpg-instances scrape.

## Networking

`httproute.yaml` puts the server on the public Gateway: GitHub must reach `/hook` to deliver webhooks, and the UI and API ride along behind Woodpecker's own login. If `apps/coraza` is enabled on `eg-public`, watch for WAF 403s on `/hook` — webhook payloads are JSON bodies the ruleset has not been tuned for here. The agents reach the server in-cluster over gRPC (`woodpecker-server:9000`), never through the Gateway.
