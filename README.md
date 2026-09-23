# fluxcd-template

## Overview

This is a template repo that can be used to deploy applications via FluxCD. It has a helper script that can be used to deploy additional applications that are not already present in this repo. The apps/templates/helm boilerplate that uses configMapGenerator and secretGenerator is a little obtuse, but it allows us to have encrypted Helm values.yaml secrets (as opposed to using external Secrets). It also has the advantage of separate values.yaml and helm_secrets.yaml files (as opposed to putting them in the HelmRelease object under `.spec.values`), so you can easily prototype things by using standard helm commands like:

```shell
helm install nxrm-ha sonatype/nxrm-ha --create-namespace --namespace nxrm-ha --version 82.0.0 --values values.yaml --values <(sops -d helm_secrets.yaml)
```

## Install required packages

This repo ships package manifests that install every CLI tool it uses (`age`, `bash`, `curl`, `dyff`, `flate`, `flux-operator`, `git`, `helm`, `jq`, `kubectl-cnpg`, `pre-commit`, `psql`, `python`, `sops`, `vim`, and the Go `yq`):

- macOS, using [Homebrew](https://brew.sh/) and the `Brewfile`:

  ```shell
  brew bundle
  ```

- Arch Linux, using the `pkglist.txt`. This requires an AUR helper such as [yay](https://github.com/Jguer/yay) or [paru](https://github.com/Morganamilo/paru), because `autokuma-cli`, `dyff`, `flux-operator`, and `kubectl-cnpg` are AUR packages (`flate` has no Arch package; see below):

  ```shell
  grep -vE '^(#|$)' pkglist.txt | yay -S --needed -
  ```

On other operating systems, install the tools listed above manually. Two gotchas: the scripts need the Flux Operator CLI (`flux-operator`), not the standard `flux` CLI; and `yq` must be the Go (mikefarah) implementation — on Arch that package is named `go-yq`.

`kuma-cli` has no Homebrew formula (the AUR has `autokuma-cli`): on macOS,
download the `kuma-mac` binary from the
[AutoKuma releases](https://github.com/BigBoot/AutoKuma/releases) and put it
on your `PATH` as `kuma-cli`. It manages Uptime Kuma entities; see
`apps/uptime-kuma/README.md`.

`flate` has no Arch package: put a release binary from
[home-operations/flate](https://github.com/home-operations/flate/releases) on
your `PATH`, or run `go install github.com/home-operations/flate/cmd/flate@latest`.
`flux_diff.sh` and the flux-diff GitHub workflow render the cluster with it; see
"Continuous integration" below.

## Deploying Flux

1. Choose an installation method - either Fork or Subtree:
   - Fork if you want a new git repo for this cluster:
      1. Click the "Fork" button in this repo to create a repo in your organization with a name like `${cluster}-fluxcd`.
   - Subtree if you want to put this code in an existing infrastructure as code git repo:
      1. Change directory to your existing repo.
      1. Checkout a new branch, use subtree to add this repo to a subdirectory, then change directory to it:

         ```bash
         git checkout -b $branch_name
         git subtree add --prefix fluxcd git@github.com:devopscoop/aws-eks-template.git main
         cd fluxcd
         ```

1. Create a GitHub App for Flux to authenticate with this repository:
   1. Go to your GitHub organization settings: **Settings → Developer settings → GitHub Apps**.
   1. Click **New GitHub App**.
   1. Fill in the form:
      - **GitHub App name**: `furlai-dev-infra-flux` (or any unique name)
      - **Homepage URL**: `https://github.com/furlai/dev-infra`
      - **Webhook**: uncheck **Active** (Flux doesn't need webhooks)
      - **Permissions → Repository permissions**:
        - **Contents**: Read and write (Flux reads the repo; image-automation-controller writes commits)
        - **Metadata**: Read-only (required by GitHub)
      - **Where can this GitHub App be installed**: Only on this account
   1. Click **Create GitHub App**. Note the **App ID** shown at the top of the next page.
   1. Scroll down to **Private keys** and click **Generate a private key**. Save the downloaded `.pem` file somewhere safe (e.g., `~/.config/flux/furlai-dev-infra-flux.pem`).
   1. Click **Install App** in the left sidebar, then install it on the `furlai` organization and select only the `dev-infra` repository.
   1. After installing, the URL will be `https://github.com/organizations/furlai/settings/installations/<installation-id>`. Note that **Installation ID**.
   1. Download the `*.pem` file - you will need it later. DO NOT COMMIT IT - IT IS A SECRET!
1. Edit variables.sh.
1. Source variables.sh:

   ```bash
   source variables.sh
   ```

1. Ensure that sops dir exists:

   ```bash
   mkdir -p "${sops_dir}"
   ```

1. Decrypt your existing SOPS age keys.txt file (if you have one):

   ```bash
   export decrypted_keys=$(mktemp --tmpdir=$HOME)
   age -d "${sops_dir}/keys.txt" > "${decrypted_keys}"
   ```

1. Create a new key for this cluster:

   ```bash
   export new_key=$(mktemp --tmpdir=$HOME)
   age-keygen | tee -a "${new_key}"
   ```

1. Add this new age public and private key to your organization's password manager.
1. Add the new key to your existing keys.txt file:

   ```bash
   cat "${new_key}" >> "${decrypted_keys}"
   ```

1. Re-encrypt your keys.txt:

   ```bash
   cp "${sops_dir}/keys.txt" "${sops_dir}/keys.txt.$(date +%s)"
   age -p "${decrypted_keys}" > "${sops_dir}/keys.txt"
   ```

1. Add the public age key to .sops.yaml.
1. Encrypt the GitHub App `*.pem` file using your new SOPS key (this encrypted file will be committed later):

   ```bash
   age -r your_sops_public_key -o devopscoop-project1-dev-flux.2026-06-16.private-key.pem.age ~/Downloads/devopscoop-project1-dev-flux.2026-06-16.private-key.pem
   ```

1. Commit and add your files:

   ```bash
   git add \
    .sops.yaml \
    *.pem.age \
    variables.sh
   git commit -m "Pre-deploy commit."
   git push
   ```

1. Run `./deploy.sh`
1. Clean up cleartext secrets once you're sure you've encrypted them and/or saved them in a password manager:

   ```bash
   rm -v "${decrypted_keys}" "${new_key}"
   ```

## Deploying applications

### Helm

To deploy an application with a Helm chart:

1. Find the app you want to deploy on [ArtifactHub](https://artifacthub.io/). Sort by Stars to find the legit (or at least the most popular) chart for your application.
1. Click the Install button.
1. The "Add repository" section contains the repo name and URL.
1. The "Install chart" section contains the chart name and version.
1. Figure out your app's name. If there is only going to be a single instance of this app in the this cluster, use the chart name as the app's name (e.g., you probably won't have more than one Sonatype Nexus Repository, so when installing the nxrm-ha chart, your app name should be "nxrm-ha". If there could be multiple instances of a Helm release, like a valkey instance for an app named "worker", use the naming scheme "release-chart" (e.g., "worker-valkey".)
1. Some applications (like [Rook](https://rook.io/docs/rook/latest-release/Helm-Charts/operator-chart/#introduction)) need to be installed in a particular namespace. Do your research. If the app doesn't recommend a specific namespace name, just use the app name as the namespace.
1. Run the deploy_new_app.sh script to figure out how to run deploy_new_app.sh script, haha:

   ```bash
   ./deploy_new_app.sh
   ```

1. Now run the deploy_new_app.sh script with the right arguments!
1. Edit the values.yaml file. Remove the lines you aren't changing - the end result should not have any default values in it.

   ```bash
   vim "apps/${app_name}/values.yaml"
   ```

1. If there are any secrets (passwords, tokens, API keys, etc.) in your values.yaml, open the helm_secrets.yaml file with sops, and move the secrets into it. You should not be committing any unencrypted secrets! WARNING: never edit this file with vim or any other text editor - you must use sops!

   ```bash
   sops apps/your_app/helm_secrets.yaml
   ```

1. Commit and push your changes, and your app should deploy.

## Promoting changes to other environments

This template assumes one git repo per cluster. The recommended multi-environment setup:

- Your continuously-deployed environment (call it dev) runs Flux image automation: image-reflector-controller polls the registry, and image-automation-controller (fluxcdbot) commits tag updates to the `# {"$imagepolicy": ...}` setter markers in `apps/*/values.yaml` whenever a new image is pushed.
- Production-like environments live in their own repo, with the dev repo configured as a git upstream remote, and do NOT run image automation. To promote, merge dev into prod via a pull request — the diff shows exactly which image tags, values, and apps are changing. Because prod never writes to the tag lines, fluxcdbot's commits always merge cleanly, and the sync PR doubles as the deploy manifest.
- Changes that must differ per environment (secrets encrypted with each cluster's age key, replica counts, hostnames) stay in each repo's own files. When a sync PR conflicts on one of these, that's the intentional prompt to update the prod copy by hand.

To disable image automation in a prod-like repo:

1. Remove `image-reflector-controller` and `image-automation-controller` from `spec.components` in `flux/flux-system/flux-instance.yaml`.
1. Remove `imagepolicies.yaml`, `imagerepositories.yaml`, and `imageupdateautomation.yaml` from whatever applies them (e.g. the `resources` list in `flux/flux-system/kustomization.yaml`). Leave the files themselves in the repo — they sync from dev and are inert without the controllers.
1. Leave the `# {"$imagepolicy": ...}` markers in `apps/*/values.yaml` alone. They are plain comments; nothing rewrites them without the automation controllers, and keeping the files identical to dev keeps syncs conflict-free.

Caveat: the synced values files reference images by full registry URL, so every environment that deploys them must be able to pull those exact name:tag pairs. Same-account registries, cross-account pull permissions, registry replication, or CI pushing to every environment's registry are all valid ways to get there — that part is up to you.

## Continuous integration

`.github/workflows/flux-diff.yaml` runs on every pull request that touches `apps/` or `flux/`. It runs `./flux_diff.sh`, which renders the cluster twice with [flate](https://github.com/home-operations/flate) — once at the PR's merge-base, once at its head — entirely offline (no kubeconfig, no cluster), and posts the rendered diff as one sticky PR comment, updated in place on every push, and in the job summary. That is the diff of what Flux would actually apply: HelmReleases are templated with their `values.yaml` and `helm_secrets.yaml`, so a chart bump or a values edit shows up as the resulting Deployment or ConfigMap change, not as a one-line version diff.

Run the same diff before pushing. It compares your working tree, uncommitted changes included, against the merge-base with `origin/main`, renders from copies, and never modifies the working tree:

```shell
./flux_diff.sh                    # human-readable, against origin/main
./flux_diff.sh -o github HEAD~3   # the PR comment's style, against another revision
```

How to read it:

- Each `@@ <field> @@` block is one changed field of one rendered resource, named in the `# group/version/Kind/namespace/name` line under it. A resource appears only when something about it changed.
- A values change also shows the generated `<app>-values-<hash>` ConfigMap as one document removed and one added, with the HelmRelease's `valuesFrom` names changing to match. That is accurate — kustomize's hash suffix gives the ConfigMap a new name — so skim past it to the workload diff.
- "No rendered changes" means the PR changes nothing Flux would apply: comments, docs, scripts, or files of apps that aren't enabled.
- A render failure on the PR's side (a broken kustomization, a chart version that doesn't exist, values that fail the chart's schema) is exit code 1: the job fails and the log is quoted at the top of the comment. Flux would fail the same way, so fix it before merging. In that log, "orig snapshot" is the merge-base and "current snapshot" is the PR. If only the merge-base fails to render (`main` is already broken and the PR may be the fix), that is exit code 2: the comment says so and the job passes. A non-empty diff never fails the job.
- Dependabot and fork PRs run with a read-only token, so the comment can't be posted there; the diff is still in the job summary.

What gets rendered — the header comment of `flux_diff.sh` is the full account:

- Only the apps enabled in the `resources` list of `flux/flux-system/kustomization.yaml`, exactly as in the cluster. flate ignores kustomize `resources` lists when pointed at a directory, so the script hands it a generated root Kustomization whose `spec.path` is that directory — the same object the FluxInstance's sync creates in the cluster.
- In this template repo the list is empty (deploy.sh fills it in at bootstrap), so the script renders every Kustomization in `flux/flux-system/` whose `spec.path` exists instead, after copying the tracked `*.decrypted` boilerplate to the filenames the kustomizations reference. Kustomizations whose path is missing are skipped with a warning (an annotation on the run). Template mode also renders with `--skip-schema-validation`, because placeholders such as falcon-platform's `CHANGEME-CID` fail chart values schemas and flate fails the whole run on any app it can't render; cluster repos, where the values are real, keep the schema check, so a schema violation surfaces on the PR that carries the change there.
- Secrets never reach the output. flate excludes `Secret` objects from rendered output by default and cannot decrypt SOPS, so an encrypted `helm_secrets.yaml` still renders its HelmRelease (with placeholder values), and neither plaintext nor ciphertext appears in the diff.

The workflow and `.github/scripts/flux-diff-comment.js` live at the repo root. In a subtree install, copy both into the host repo's `.github/` and set the workflow's `FLUX_DIR` to the subtree prefix; `flux_diff.sh` finds the Flux entry with `git ls-files`, so the prefix needs no other configuration.
