#!/usr/bin/env bash

export KUBECONFIG="${HOME}/.kube/project1-dev"
export cluster_name=project1-dev
export flux_path=flux
export git_owner=devopscoop
export git_platform=gitlab
export git_repo=project1-dev-deploy
export k8s_platform=eks # eks, k0s, talos

# Have to decrypt our encrypted keys.txt like this because of this bug:
# https://github.com/getsops/sops/issues/933
if [[ "$OSTYPE" == "darwin"* ]]; then
 export sops_dir="${HOME}/Library/Application Support/sops/age"
elif [[ "$OSTYPE" == "linux"* ]]; then
 export sops_dir="${HOME}/.config/sops/age"
fi
# shellcheck disable=SC2155
export SOPS_AGE_KEY=$(age -d "${sops_dir}/keys.txt")

# https://github.com/fluxcd/flux2/releases/
export flux_version=2.6.4

# https://dl.k8s.io/release/stable.txt
export kubectl_version=1.34.1

# https://github.com/getsops/sops/releases/
export sops_version=3.10.2

# https://github.com/mikefarah/yq/releases
export yq_version=4.47.2
