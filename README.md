# fluxcd-template

## Overview

This is a template repo that can be used to deploy applications via FluxCD. It has a helper script that can be used to deploy additional applications that are not already present in this repo. The apps/templates/helm boilerplate that uses configMapGenerator and secretGenerator is a little obtuse, but it allows us to have encrypted Helm values.yaml secrets (as opposed to using external Secrets). It also has the advantage of separate values.yaml and helm_secrets.yaml files (as opposed to putting them in the HelmRelease object under `.spec.values`), so you can easily prototype things by using standard helm commands like:

```shell
helm install nxrm-ha sonatype/nxrm-ha --create-namespace --namespace nxrm-ha --version 82.0.0 --values values.yaml --values <(sops -d helm_secrets.yaml)
```

## Deploying Flux

https://fluxcd.io/flux/installation/bootstrap/github/

1. Edit variables.sh.
1. Go to [Fine-grained personal access token](https://github.com/settings/tokens?type=beta).
1. Click on "Generate new token".
1. Use default settings, except for these:
   - Token name: project1-dev (name of the git repo)
   - Resource owner: devopscoop (name of the git organization)
   - Repository access: only select repositories
   - Select repositories: find this repo and select it.
   - Add Permissions -> Administration -> Read and write.
   - Add Permissions -> Contents -> Read and write.
1. Create some environment variables, and ensure that sops dir exists:
   ```bash
   export GITHUB_TOKEN=put_your_token_here
   if [[ "$OSTYPE" == "darwin"* ]]; then
     export sops_dir="${HOME}/Library/Application Support/sops/age"
   elif [[ "$OSTYPE" == "linux"* ]]; then
     export sops_dir="${HOME}/.config/sops/age"
   fi
   mkdir -p "${sops_dir}"
   ```
1. TODO: Warning/admonition about encrypting keys.txt...
1. Decrypt your existing SOPS age keys.txt file (if you have one), then create a new age key for this cluster:
   ```
   export temp_key=$(mktemp --tmpdir=$HOME)
   age -d "${sops_dir}/keys.txt" > "${temp_key}"
   age-keygen >> "${temp_key}"
   ```
1. Add this new age public and private key to your organization's password manager.
1. Re-encrypt your secrets, and delete the cleartext secret:
   ```bash
   cp "${sops_dir}/keys.txt" "${sops_dir}/keys.txt.$(date +%s)"
   age -p "${temp_key}" > "${sops_dir}/keys.txt"
   rm -v "${temp_key}"
   ```
1. Add the public age key to .sops.yaml.
1. Create a sops-encrypted copy of the age key:
   ```
   sops flux/flux-system/sops-age.secrets.yaml
   ```
   with content like this:
   ```
   apiVersion: v1
   kind: Secret
   metadata:
     name: sops-age
     namespace: flux-system
   stringData:
     age.agekey: |
       # created: 2025-02-18T13:13:26-05:00
       # public key: age159dey5adr2eafv62ktuxt3churncy4h8dzclqm5x0xq774sdpc7qkklsxh
       AGE-SECRET-KEY-<redacted>
   type: Opaque
   ```
1. Commit and add your files:
   ```
   git add \
    .sops.yaml \
    flux/flux-system/sops-age.secrets.yaml \
    variables.sh
   git commit -m "Pre-deploy commit."
   git push
   ```
1. Run `./deploy.sh`

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
   ```
   ./deploy_new_app.sh
   ```
1. Now run the deploy_new_app.sh script with the right positional parameters!
1. Edit the values.yaml file. Remove the lines you aren't changing - the end result should not have any default values in it.
   ```
   vim "apps/${app_name}/values.yaml"
   ```
1. If there are any secrets (passwords, tokens, API keys, etc.) in your values.yaml, open the helm_secrets.yaml file with sops, and move the secrets into it. You should not be committing any unencrypted secrets! WARNING: never edit this file with vim or any other text editor - you must use sops!
   ```
   sops apps/your_app/helm_secrets.yaml
   ```
1. Commit and push your changes, and your app should deploy.
