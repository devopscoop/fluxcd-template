#!/usr/bin/env bash

# Pins the Falcon images in values.yaml to the digest of the latest tag each
# component publishes, recording that tag as a line comment:
#
#   digest: sha256:abc... # 8.10.0-19402-1
#
# Digests are immutable, so a re-pushed tag cannot move the deployed image; the
# charts' own READMEs recommend digest over tag. The helpers accept either, but
# the values schemas require the sha256: prefix.
#
# Downloads CrowdStrike's falcon-container-sensor-pull.sh from the latest
# falcon-scripts release, verifies it against that release's checksum.txt, and
# prompts for a Falcon API client (needs both Sensor Download [read] and Falcon
# Images Download [read]).
#
# Run from this directory. The pull script talks to the us-1 cloud by default;
# for any other region export FALCON_CLOUD first, e.g.
#   FALCON_CLOUD=us-2 ./update.sh
#
# The image analyzer is falcon-imageanalyzer to the registry but
# falcon-image-analyzer in the chart, and falcon-sensor nests its image under
# node - hence the explicit paths.

# https://vaneyckt.io/posts/safer_bash_scripts_with_set_euxo_pipefail/
set -Eeuo pipefail

pull_script=falcon-container-sensor-pull.sh
registry=registry.crowdstrike.com

# /releases/latest/download/ redirects to the newest release's assets, so this
# needs no GitHub API call. checksum.txt covers every asset in the release, so
# grep narrows it to ours before sha256sum checks it.
release=https://github.com/CrowdStrike/falcon-scripts/releases/latest/download
curl -fsSL -o "${pull_script}" "${release}/${pull_script}"
curl -fsSL "${release}/checksum.txt" | grep "  ${pull_script}$" | sha256sum -c -
chmod +x "${pull_script}"

read -r -p 'Falcon API OAUTH Client ID: ' client_id
read -r -s -p 'Falcon API OAUTH Client Secret: ' client_secret
echo

falcon() { "./${pull_script}" -u "${client_id}" -s "${client_secret}" "$@"; }

# All three components live behind the same container-security registry account,
# so one credential pair covers them. The pull script prints a settings preamble
# alongside the credentials, hence matching on the labels rather than by line.
creds=$(falcon --dump-credentials -t falcon-sensor)
reg_user=$(awk -F': ' '/^CS Registry Username:/ {print $2}' <<< "${creds}")
reg_pass=$(awk -F': ' '/^CS Registry Password:/ {print $2}' <<< "${creds}")

update() {
  local type=$1 path=$2 repo="$1/release/$1" tag token digest

  tag=$(falcon --list-tags -t "${type}" | jq -r '.tags | last')

  # Registry bearer token, then the image index digest for that tag - the same
  # flow update_flux-instance.sh uses against ghcr.io. Accepting the index types
  # first keeps the pin multi-arch rather than resolving to one platform.
  token=$(curl -fsSL -u "${reg_user}:${reg_pass}" \
    "https://${registry}/v2/token?account=${reg_user}&scope=repository:${repo}:pull&service=${registry}" \
    | jq -r '.token')
  digest=$(curl -fsSI -H "Authorization: Bearer ${token}" \
    -H 'Accept: application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.docker.distribution.manifest.v2+json' \
    "https://${registry}/v2/${repo}/manifests/${tag}" \
    | tr -d '\r' | awk 'tolower($1) == "docker-content-digest:" {print $2}')

  # An empty digest would silently fall back to the tag we are about to delete.
  [[ "${digest}" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "ERROR: no digest for ${repo}:${tag} (got '${digest}')." >&2; exit 1; }

  yq -i "${path}.digest = \"${digest}\" | ${path}.digest line_comment = \"${tag}\" | del(${path}.tag)" values.yaml
  echo "${type}: ${digest} # ${tag}"
}

update falcon-sensor        '.["falcon-sensor"].node.image'
update falcon-kac           '.["falcon-kac"].image'
update falcon-imageanalyzer '.["falcon-image-analyzer"].image'
