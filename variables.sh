#!/usr/bin/env bash

export KUBECONFIG="${HOME}/.kube/project1-dev"
export cluster_name=project1-dev
export flux_path=flux
export git_owner=devopscoop
export git_repo=project1-dev-deploy
export k8s_platform=eks # eks, k0s, talos
export region=us-east-2 # used by loki

# GitHub App config for `flux-operator create secret githubapp` (see deploy.sh).
# None of these are secret: the App ID appears in the JWTs the app signs, and
# both IDs are visible in your GitHub App's settings UI. Find the App ID on the
# app's General page and the Installation ID in the "Install App" URL
# (https://github.com/settings/installations/<INSTALLATION_ID>).
export GITHUB_APP_ID=000000
export GITHUB_APP_INSTALLATION_ID=00000000
# The GitHub App private key (the actual secret) is decrypted further down,
# once the age identity ($SOPS_AGE_KEY) is loaded -- see GITHUB_APP_PRIVATE_KEY_FILE.

# Path to the new age key file used to seed the in-cluster sops-age secret via
# `flux-operator create secret sops --age-key-file`. Create one with age-keygen.
export new_key="${HOME}/.config/sops/age/keys.txt"

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
# `flux-operator create secret githubapp` needs a plaintext file path, so we
# decrypt it non-interactively with the identity in $SOPS_AGE_KEY to a temp file
# (mktemp -> mode 600, in $TMPDIR, never the repo) and wipe it on exit.
# SCRIPT_DIR is set by deploy.sh before it sources this file.
GITHUB_APP_PRIVATE_KEY_FILE="$(mktemp)"
export GITHUB_APP_PRIVATE_KEY_FILE
trap 'rm -f "${GITHUB_APP_PRIVATE_KEY_FILE}"' EXIT
age -d -i <(printf '%s\n' "$SOPS_AGE_KEY") "${SCRIPT_DIR}/github-app.private-key.pem.age" > "${GITHUB_APP_PRIVATE_KEY_FILE}"
