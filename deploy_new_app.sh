#!/usr/bin/env bash

# TODO: Remove x to disable debug output after someone with a Mac tests this script.
# https://vaneyckt.io/posts/safer_bash_scripts_with_set_euxo_pipefail/
set -Eexuo pipefail

# https://stackoverflow.com/questions/59895/how-do-i-get-the-directory-where-a-bash-script-is-located-from-within-the-script
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

if [[ $# -ne 5 ]]; then
  cat <<TOC >&2

Usage:

  $0 helm_repo_name helm_repo_url app_name helm_chart_name helm_chart_version

Example:

  $0 harbor https://helm.goharbor.io my-harbor harbor 1.17.2

TOC
  exit 1
fi

export helm_repo_name=$1

# Removing trailing slash to normalize input
export helm_repo_url=${2%%/}

export app_name=$3
export helm_chart_name=$4
export helm_chart_version=$5

if [[ -d "${SCRIPT_DIR}/apps/${app_name}" ]]; then
  echo "ERROR: An app named ${app_name} already exists in the apps directory." >&2
  exit 1
fi
cp -r "${SCRIPT_DIR}/apps/templates/helm" "${SCRIPT_DIR}/apps/${app_name}"

# Search for the string "app-template", and replace it with your Helm chart's name.
grep -rIl app-template "${SCRIPT_DIR}/apps/${app_name}" | xargs sed -i.bak "s/app-template/${app_name}/g"
find "${SCRIPT_DIR}/apps/${app_name}" -name '*.bak' -delete

# Pull the default values for this Helm chart.
if [[ "${helm_repo_url}" =~ ^oci: ]]; then
  helm pull "${helm_repo_url}/${helm_chart_name}" --version "${helm_chart_version}"
  tar -xf "${helm_chart_name}-${helm_chart_version}.tgz" "${helm_chart_name}/values.yaml" -O > "${SCRIPT_DIR}/apps/${app_name}/values.yaml"
  rm "${helm_chart_name}-${helm_chart_version}.tgz"
else
  # Add or update the repo, so we have the latest chart versions.
  helm repo add "${helm_repo_name}" "${helm_repo_url}" || helm repo update
  helm show values "${helm_repo_name}/${helm_chart_name}" --version "${helm_chart_version}" > "${SCRIPT_DIR}/apps/${app_name}/values.yaml"
fi

yq -i "(select(.kind == \"HelmRepository\") | .metadata.name) = \"${helm_repo_name}\"" "${SCRIPT_DIR}/apps/${app_name}/release.yaml"
if [[ "${helm_repo_url}" =~ ^oci: ]]; then
  yq -i "(select(.kind == \"HelmRepository\") | .spec.type) = \"oci\"" "${SCRIPT_DIR}/apps/${app_name}/release.yaml"
fi
yq -i "(select(.kind == \"HelmRepository\") | .spec.url) = \"${helm_repo_url}\"" "${SCRIPT_DIR}/apps/${app_name}/release.yaml"
yq -i "(select(.kind == \"HelmRelease\") | .spec.chart.spec.chart) = \"${helm_chart_name}\"" "${SCRIPT_DIR}/apps/${app_name}/release.yaml"
yq -i "(select(.kind == \"HelmRelease\") | .spec.chart.spec.version) = \"${helm_chart_version}\"" "${SCRIPT_DIR}/apps/${app_name}/release.yaml"
yq -i "(select(.kind == \"HelmRelease\") | .spec.chart.spec.sourceRef.name) = \"${helm_repo_name}\"" "${SCRIPT_DIR}/apps/${app_name}/release.yaml"

cp "${SCRIPT_DIR}/flux/flux-system/app-template.yaml" "${SCRIPT_DIR}/flux/flux-system/${app_name}.yaml"

# Replace app-template with your chart name, and uncomment the file.
sed -i.bak "s/app-template/${app_name}/g;s/^# //;" "${SCRIPT_DIR}/flux/flux-system/${app_name}.yaml"
rm "${SCRIPT_DIR}/flux/flux-system/${app_name}.yaml.bak"

yq -i '.spec.suspend = false' "${SCRIPT_DIR}/flux/flux-system/${app_name}.yaml"
