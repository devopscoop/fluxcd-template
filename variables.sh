#!/usr/bin/env bash

export flux_github_owner='devopscoop'
export cluster_name='project1-dev'
export KUBECONFIG="${HOME}/.kube/project1-dev"
export flux_path="flux"
export k8s_platform="eks" # eks or k0s

# Have to decrypt our encrypted keys.txt like this because of this bug:
# https://github.com/getsops/sops/issues/933
if [[ "$OSTYPE" == "darwin"* ]]; then
 export sops_dir="${HOME}/Library/Application Support/sops/age"
elif [[ "$OSTYPE" == "linux"* ]]; then
 export sops_dir="${HOME}/.config/sops/age"
fi
export SOPS_AGE_KEY=$(age -d "${sops_dir}/keys.txt")

# Tool versions
export flux_version='2.6.3'
export kubectl_version='1.33.2'
export kubernetes_version='1.33.1'
export sops_version='3.10.2'
export yq_version='4.45.4'
