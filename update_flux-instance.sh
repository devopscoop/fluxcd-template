#!/usr/bin/env bash

# Updates flux/flux-system/flux-instance.yaml to the latest Flux release:
#   - spec.distribution.version, from the latest fluxcd/flux2 GitHub release.
#   - The digest-pinned controller images in spec.kustomize.patches, using the
#     controller versions that ship with that release (per the flux2 manifests)
#     and their multi-arch image index digests from ghcr.io.
#
# Requires: curl, yq. Set GITHUB_TOKEN to avoid anonymous GitHub API rate limits.
#
# Usage: ./update_flux-instance.sh [FILE]
#   FILE defaults to flux/flux-system/flux-instance.yaml next to this script.

# https://vaneyckt.io/posts/safer_bash_scripts_with_set_euxo_pipefail/
set -Eeuo pipefail

# https://stackoverflow.com/questions/59895/how-do-i-get-the-directory-where-a-bash-script-is-located-from-within-the-script
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

file="${1:-${SCRIPT_DIR}/flux/flux-system/flux-instance.yaml}"

github_curl=(curl -fsSL)
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  github_curl+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
fi

flux_tag=$("${github_curl[@]}" https://api.github.com/repos/fluxcd/flux2/releases/latest | yq -r '.tag_name' || true)
if [[ ! "${flux_tag}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "ERROR: could not determine the latest Flux release (got '${flux_tag}')." >&2
  exit 1
fi

old_version=$(yq -r '.spec.distribution.version' "${file}")
if [[ "${old_version}" == "${flux_tag#v}" ]]; then
  echo "distribution.version: ${old_version} (unchanged)"
else
  sed -i.bak -E "s|^([[:space:]]+version: )\"[0-9.]+\"|\\1\"${flux_tag#v}\"|" "${file}"
  echo "distribution.version: ${old_version} -> ${flux_tag#v}"
fi

# The controllers to update are whatever images are currently pinned in the file.
controllers=$(grep -oE 'ghcr\.io/fluxcd/[a-z-]+:' "${file}" | sed 's|ghcr.io/fluxcd/||;s|:$||' | sort -u)

for name in ${controllers}; do

  # Controller version shipped with this Flux release, taken from the
  # release-artifact URLs in the flux2 manifests.
  tag=$(curl -fsSL "https://raw.githubusercontent.com/fluxcd/flux2/${flux_tag}/manifests/bases/${name}/kustomization.yaml" \
    | grep -oEm1 '/releases/download/v[0-9]+\.[0-9]+\.[0-9]+/' | cut -d/ -f4 || true)
  if [[ -z "${tag}" ]]; then
    echo "ERROR: could not determine the ${name} version shipped with Flux ${flux_tag}." >&2
    exit 1
  fi

  # Multi-arch image index digest for that tag, from the ghcr.io registry API.
  token=$(curl -fsSL "https://ghcr.io/token?service=ghcr.io&scope=repository:fluxcd/${name}:pull" | yq -r '.token' || true)
  digest=$(curl -fsSI \
    -H "Authorization: Bearer ${token}" \
    -H "Accept: application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json" \
    "https://ghcr.io/v2/fluxcd/${name}/manifests/${tag}" \
    | tr -d '\r' | awk 'tolower($1) == "docker-content-digest:" {print $2}' || true)
  if [[ ! "${digest}" =~ ^sha256:[a-f0-9]{64}$ ]]; then
    echo "ERROR: could not resolve the digest of ghcr.io/fluxcd/${name}:${tag} (got '${digest}')." >&2
    exit 1
  fi

  old=$(grep -oEm1 "ghcr\.io/fluxcd/${name}:[^\"]+" "${file}")
  new="ghcr.io/fluxcd/${name}:${tag}@${digest}"
  if [[ "${old}" == "${new}" ]]; then
    echo "${name}: ${tag} (unchanged)"
  else
    sed -i.bak "s|ghcr.io/fluxcd/${name}:[^\"]*|${new}|" "${file}"
    echo "${name}: ${old#*:} -> ${tag}@${digest}"
  fi

done

rm -f "${file}.bak"
