#!/usr/bin/env bash

# Pins every EC2NodeClass in this directory to the newest AL2023 EKS-optimized
# AMI release for the cluster's Kubernetes version:
#
#   amiSelectorTerms:
#     - alias: al2023@v20260930
#
# Merging the bump drifts every node built from these classes, so Karpenter
# replaces them at the pace each NodePool's disruption budget allows.
#
# Usage: ./update_ami.sh [CLUSTER_VERSION]
#
# With no argument, cluster_version and region come from aws-eks-template's
# tfvars, found at ../aws-eks/cluster/ relative to this repo's root when both
# templates are subtrees of one infra repo (aws-eks/ and fluxcd/). That is the
# same source aws-eks's cluster/update_node_ami.sh reads for the managed node
# groups; after an EKS upgrade, run both. In a standalone fork of this repo,
# pass the cluster's Kubernetes minor (e.g. 1.35) instead; the region is then
# whatever the AWS CLI is configured with. The AMI metadata is public SSM
# parameters, so any credentials will do.

# https://vaneyckt.io/posts/safer_bash_scripts_with_set_euxo_pipefail/
# Not using "-x" because we aren't debugging.
set -Eeuo pipefail

# https://stackoverflow.com/questions/59895/how-do-i-get-the-directory-where-a-bash-script-is-located-from-within-the-script
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

if [[ $# -gt 1 ]]; then
  echo "Usage: $0 [CLUSTER_VERSION]" >&2
  exit 1
fi

if [[ $# -eq 1 ]]; then
  cluster_version=$1
else
  # Don't hardcode the tfvars name: forks rename it (e.g. prod.auto.tfvars).
  tfvars_file=$(grep -lE '^cluster_version' "${SCRIPT_DIR}"/../../../aws-eks/cluster/*.tfvars 2>/dev/null) \
    || { echo "ERROR: no aws-eks/cluster/*.tfvars with cluster_version next to this repo; pass CLUSTER_VERSION (e.g. 1.35)." >&2; exit 1; }

  AWS_REGION=$(sed -nE "s/^region[^=]*=[ \t]+['\"]?([^'\"]+)['\"]?/\1/p" "$tfvars_file")
  export AWS_REGION
  cluster_version=$(sed -nE "s/^cluster_version[^=]*=[ \t]+['\"]?([^'\"]+)['\"]?/\1/p" "$tfvars_file")
fi

# The alias version is the AMI name's date suffix
# (amazon-eks-node-al2023-x86_64-standard-1.35-v20260930). The NodePools are
# amd64-only (nodepool.yaml), hence the x86_64 tree; the alias pins arm64 to
# the same release too.
image_name=$(aws ssm get-parameter \
  --name "/aws/service/eks/optimized-ami/${cluster_version}/amazon-linux-2023/x86_64/standard/recommended/image_name" \
  --query Parameter.Value --output text)
ami_version=${image_name##*-}

# A malformed version would make Karpenter fail to resolve any AMI, and then it
# can't launch nodes at all.
[[ "${ami_version}" =~ ^v[0-9]{8}$ ]] || { echo "ERROR: no AMI version in '${image_name}'." >&2; exit 1; }

files=$(grep -lE 'alias: al2023@' "${SCRIPT_DIR}"/*.yaml) \
  || { echo "ERROR: no 'alias: al2023@' in ${SCRIPT_DIR}/*.yaml." >&2; exit 1; }

echo "al2023@${ami_version} (EKS ${cluster_version}, ${AWS_REGION:-${AWS_DEFAULT_REGION:-AWS CLI default region}}):"
while IFS= read -r file; do
  sed -i.bak -E "s/(alias: al2023@)[^[:space:]]+/\1${ami_version}/" "$file"
  rm "${file}.bak"
  echo "  ${file##*/}"
done <<< "$files"
