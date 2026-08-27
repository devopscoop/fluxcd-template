#!/usr/bin/env bash

export AWS_PROFILE=project1-dev:AdministratorAccess
export KUBECONFIG="${HOME}/.kube/project1-dev"
export cluster_name=project1-dev
export flux_path=flux
export git_owner=devopscoop
export git_repo=project1-dev-deploy
export k8s_platform=eks # eks, k0s, talos
export region=us-east-2 # used by loki
# true to have Alertmanager send alert notifications to Slack. Also set your
# webhook URL and channel first -- see apps/kube-prometheus-stack/README.md.
export slack_alerts=false

# GitHub App config for `flux-operator create secret githubapp` (see deploy.sh).
# None of these are secret: the App ID appears in the JWTs the app signs, and
# both IDs are visible in your GitHub App's settings UI. Find the App ID on the
# app's General page and the Installation ID in the "Install App" URL
# (https://github.com/settings/installations/<INSTALLATION_ID>).
export GITHUB_APP_ID=000000
export GITHUB_APP_INSTALLATION_ID=00000000
# The GitHub App private key (the actual secret) is decrypted further down,
# once the age identity ($SOPS_AGE_KEY) is loaded -- see GITHUB_APP_PRIVATE_KEY.

# Have to decrypt our encrypted keys.txt like this because of this bug:
# https://github.com/getsops/sops/issues/933
if [[ "$OSTYPE" == "darwin"* ]]; then
 export sops_dir="${HOME}/Library/Application Support/sops/age"
elif [[ "$OSTYPE" == "linux"* ]]; then
 export sops_dir="${HOME}/.config/sops/age"
fi
# shellcheck disable=SC2155
export SOPS_AGE_KEY=$(age -d "${sops_dir}/keys.txt")

# GitHub App private key -- this IS the secret. It's stored age-encrypted in
# this directory (github-app.private-key.pem.age), encrypted to the same age
# recipient as our sops secrets, so it can live in the repo safely. Encrypt
# yours with (your public key is the one in .sops.yaml):
#   age -r <your-age-recipient> -o github-app.private-key.pem.age /path/to/app.private-key.pem
# Decrypted non-interactively with the identity in $SOPS_AGE_KEY into a shell
# variable; deploy.sh hands it to `flux-operator create secret githubapp` via
# process substitution at the call site (same pattern as --age-key-file), so
# the key never touches the filesystem. Don't assign a process substitution
# here instead -- bash closes its /dev/fd/<n> as soon as the assignment
# completes, so the path would be dead before deploy.sh could use it.
# Not exported: deploy.sh sources this file, and keeping it out of the
# environment means child processes can't read it from their env.
# SCRIPT_DIR is set by deploy.sh before it sources this file.
# shellcheck disable=SC2034 # consumed by deploy.sh, which sources this file
GITHUB_APP_PRIVATE_KEY=$(age -d -i <(printf '%s\n' "$SOPS_AGE_KEY") "${SCRIPT_DIR}/furlai-dev-infra-flux.2026-05-05.private-key.pem.age")
