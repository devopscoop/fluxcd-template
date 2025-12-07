#!/usr/bin/env bash

# https://vaneyckt.io/posts/safer_bash_scripts_with_set_euxo_pipefail/
set -Eexuo pipefail

# https://stackoverflow.com/questions/59895/how-do-i-get-the-directory-where-a-bash-script-is-located-from-within-the-script
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

if [[ $# -ne 5 ]]; then
  cat <<TOC >&2

Usage:

  $0 app_name repo_name repo_url chart_name chart_version

Examples:

  # Using OCIRepository
  $0 my-api devopscoop oci://registry.gitlab.com/devopscoop/charts app 0.7.1

  # Using HelmRepository
  $0 my-harbor harbor https://helm.goharbor.io harbor 1.17.2

TOC
  exit 1
fi

export app_name=$1
export repo_name=$2

# Removing trailing slash to normalize input
export repo_url=${3%%/}

export chart_name=$4
export chart_version=$5

if [[ -d "${SCRIPT_DIR}/apps/${app_name}" ]]; then
  echo "ERROR: An app named ${app_name} already exists in the apps directory." >&2
  exit 1
fi
cp -r "${SCRIPT_DIR}/apps/templates/helm" "${SCRIPT_DIR}/apps/${app_name}"

# Search for the string "app-template", and replace it with your Helm chart's name.
grep -rIl app-template "${SCRIPT_DIR}/apps/${app_name}" | xargs sed -i.bak "s/app-template/${app_name}/g"
find "${SCRIPT_DIR}/apps/${app_name}" -name '*.bak' -delete

if [[ "${repo_url}" =~ ^oci: ]]; then

  # Pull the default values for this Helm chart.
  helm pull "${repo_url}/${chart_name}" --version "${chart_version}"
  tar -xf "${chart_name}-${chart_version}.tgz" "${chart_name}/values.yaml" -O > "${SCRIPT_DIR}/apps/${app_name}/values.yaml"
  rm "${chart_name}-${chart_version}.tgz"

  # Update ocirepo.yaml
  yq -i "
    .metadata.name = \"${repo_name}-${chart_name}\" |
    .spec.url = \"${repo_url}/${chart_name}\" |
    .spec.ref.tag = \"${chart_version}\"
  " "${SCRIPT_DIR}/apps/${app_name}/ocirepo.yaml"

  # Uncomment ocirepo and delete helmrepo
  sed -i.bak '
    s/^  # - ocirepo.yaml$/  - ocirepo.yaml/;
    /^  # - helmrepo.yaml$/d;
  ' "${SCRIPT_DIR}/apps/${app_name}/kustomization.yaml"
  rm "${SCRIPT_DIR}/apps/${app_name}/kustomization.yaml.bak"
  rm "${SCRIPT_DIR}/apps/${app_name}/helmrepo.yaml"

  # Update release.yaml
  yq -i "
    .spec.chartRef.kind = \"OCIRepository\" |
    .spec.chartRef.name = \"${repo_name}-${chart_name}\"
  " "${SCRIPT_DIR}/apps/${app_name}/release.yaml"

else

  # Add or update the repo, so we have the latest chart versions.
  helm repo add "${repo_name}" "${repo_url}" || helm repo update

  # Pull the default values for this Helm chart.
  helm show values "${repo_name}/${chart_name}" --version "${chart_version}" > "${SCRIPT_DIR}/apps/${app_name}/values.yaml"

  # Update helmrepo.yaml
  yq -i "
    .metadata.name = \"${repo_name}\" |
    .spec.url = \"${repo_url}\"
  " "${SCRIPT_DIR}/apps/${app_name}/helmrepo.yaml"

  # Uncomment helmrepo and delete ocirepo
  sed -i.bak '
    s/^  # - helmrepo.yaml$/  - helmrepo.yaml/;
    /^  # - ocirepo.yaml/d;
  ' "${SCRIPT_DIR}/apps/${app_name}/kustomization.yaml"
  rm "${SCRIPT_DIR}/apps/${app_name}/kustomization.yaml.bak"
  rm "${SCRIPT_DIR}/apps/${app_name}/ocirepo.yaml"

  # Update release.yaml
  yq -i "
    .spec.chart.spec.chart = \"${chart_name}\" |
    .spec.chart.spec.version = \"${chart_version}\" |
    .spec.chart.spec.sourceRef.name = \"${repo_name}\"
  " "${SCRIPT_DIR}/apps/${app_name}/release.yaml"

fi

cp "${SCRIPT_DIR}/flux/flux-system/app-template.yaml" "${SCRIPT_DIR}/flux/flux-system/${app_name}.yaml"

# Replace app-template with your chart name, and uncomment the file.
sed -i.bak "s/app-template/${app_name}/g;s/^# //;" "${SCRIPT_DIR}/flux/flux-system/${app_name}.yaml"
rm "${SCRIPT_DIR}/flux/flux-system/${app_name}.yaml.bak"

# Add new app kustomization to flux-system kustomization
yq -i ".resources = (.resources + [\"${app_name}.yaml\"] | unique)" "${SCRIPT_DIR}/flux/flux-system/kustomization.yaml"

# Add ImageRepository
if ! grep -q "name: ${app_name}$" "${SCRIPT_DIR}/flux/flux-system/imagerepositories.yaml"; then
  cat << EOF >> "${SCRIPT_DIR}/flux/flux-system/imagerepositories.yaml"
---
apiVersion: image.toolkit.fluxcd.io/v1beta2
kind: ImageRepository
metadata:
  name: ${app_name}
  namespace: flux-system
spec:
  image: ghcr.io/dfinity-ops/${app_name}
  interval: 1m0s
  secretRef:
    name: sa-github-api
EOF
fi

# Add ImagePolicy
if ! grep -q "name: ${app_name}$" "${SCRIPT_DIR}/flux/flux-system/imagepolicies.yaml"; then
  cat << EOF >> "${SCRIPT_DIR}/flux/flux-system/imagepolicies.yaml"
---
apiVersion: image.toolkit.fluxcd.io/v1beta2
kind: ImagePolicy
metadata:
  name: ${app_name}
  namespace: flux-system
spec:
  filterTags:
    extract: \$ts
    pattern: ^dev-[a-f0-9]+-(?P<ts>[0-9]+)
  imageRepositoryRef:
    name: ${app_name}
    namespace: flux-system
  policy:
    numerical:
      order: asc
EOF
fi
