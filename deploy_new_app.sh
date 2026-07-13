#!/usr/bin/env bash

# https://vaneyckt.io/posts/safer_bash_scripts_with_set_euxo_pipefail/
set -Eexuo pipefail

# https://stackoverflow.com/questions/59895/how-do-i-get-the-directory-where-a-bash-script-is-located-from-within-the-script
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

usage() {
  cat <<TOC >&2

Usage:

  $0 --app-name NAME --repo-name NAME --repo-url URL --chart-name NAME --chart-version VERSION [--deploy] [--image-automation]

Options:

  --app-name          Name for the app directory and Flux Kustomization.
  --repo-name         Name for the HelmRepository/OCIRepository object.
  --repo-url          Chart repository URL (https://... or oci://...).
  --chart-name        Name of the chart within the repository.
  --chart-version     Version of the chart to deploy.
  --deploy            Register the app in flux/flux-system/kustomization.yaml
                      so Flux deploys it.
  --image-automation  Also create Flux ImageRepository/ImagePolicy entries for
                      ghcr.io/devopscoop/APP_NAME. Only useful for first-party
                      apps whose images are pushed there.

Examples:

  # Using OCIRepository
  $0 --app-name my-api --repo-name devopscoop --repo-url oci://registry.gitlab.com/devopscoop/charts --chart-name app --chart-version 0.9.0

  # Using HelmRepository
  $0 --app-name my-harbor --repo-name harbor --repo-url https://helm.goharbor.io --chart-name harbor --chart-version 1.17.2

  # First-party app with image automation
  $0 --app-name my-api --repo-name devopscoop --repo-url oci://registry.gitlab.com/devopscoop/charts --chart-name app --chart-version 0.9.0 --image-automation

TOC
  exit 1
}

app_name=""
repo_name=""
repo_url=""
chart_name=""
chart_version=""
deploy=false
image_automation=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app-name)         [[ $# -ge 2 ]] || usage; app_name=$2; shift 2 ;;
    --repo-name)        [[ $# -ge 2 ]] || usage; repo_name=$2; shift 2 ;;
    --repo-url)         [[ $# -ge 2 ]] || usage; repo_url=$2; shift 2 ;;
    --chart-name)       [[ $# -ge 2 ]] || usage; chart_name=$2; shift 2 ;;
    --chart-version)    [[ $# -ge 2 ]] || usage; chart_version=$2; shift 2 ;;
    --deploy)           deploy=true; shift ;;
    --image-automation) image_automation=true; shift ;;
    *)                  usage ;;
  esac
done

if [[ -z "${app_name}" || -z "${repo_name}" || -z "${repo_url}" || -z "${chart_name}" || -z "${chart_version}" ]]; then
  usage
fi

# Removing trailing slash to normalize input
repo_url=${repo_url%%/}

export app_name repo_name repo_url chart_name chart_version

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
    .spec.chart.spec.sourceRef.kind = \"HelmRepository\" |
    .spec.chart.spec.sourceRef.name = \"${repo_name}\"
  " "${SCRIPT_DIR}/apps/${app_name}/release.yaml"

fi

cp "${SCRIPT_DIR}/flux/flux-system/app-template.yaml" "${SCRIPT_DIR}/flux/flux-system/${app_name}.yaml"

# Replace app-template with your chart name, and uncomment the file.
sed -i.bak "s/app-template/${app_name}/g;s/^# //;" "${SCRIPT_DIR}/flux/flux-system/${app_name}.yaml"
rm "${SCRIPT_DIR}/flux/flux-system/${app_name}.yaml.bak"

# Add new app kustomization to flux-system kustomization
if [[ "${deploy}" == "true" ]]; then
  yq -i ".resources = (.resources + [\"${app_name}.yaml\"] | unique)" "${SCRIPT_DIR}/flux/flux-system/kustomization.yaml"
fi

if [[ "${image_automation}" == "true" ]]; then

  # Add ImageRepository
  if ! grep -q "name: ${app_name}$" "${SCRIPT_DIR}/flux/flux-system/imagerepositories.yaml"; then
    cat << EOF >> "${SCRIPT_DIR}/flux/flux-system/imagerepositories.yaml"
---
apiVersion: image.toolkit.fluxcd.io/v1
kind: ImageRepository
metadata:
  name: ${app_name}
  namespace: flux-system
spec:
  image: ghcr.io/devopscoop/${app_name}
  interval: 1m0s
  secretRef:
    name: sa-github-api
EOF
  fi

  # Add ImagePolicy
  if ! grep -q "name: ${app_name}$" "${SCRIPT_DIR}/flux/flux-system/imagepolicies.yaml"; then
    cat << EOF >> "${SCRIPT_DIR}/flux/flux-system/imagepolicies.yaml"
---
apiVersion: image.toolkit.fluxcd.io/v1
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

fi

# Encrypt *.yaml.decrypted files
"${SCRIPT_DIR}/encrypt_secrets.sh"
