#!/usr/bin/env bash

# This script is idempotent, fails fast, and should be safe to run against a running cluster. It requires the variables.sh file.

# TODO: Remove x to disable debug output after someone with a Mac tests this script.
# https://vaneyckt.io/posts/safer_bash_scripts_with_set_euxo_pipefail/
set -Eexuo pipefail

# https://stackoverflow.com/questions/59895/how-do-i-get-the-directory-where-a-bash-script-is-located-from-within-the-script
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

# Need to cd to this dir, because there are a lot of git commands in this script that expect to be run from this directory.
cd "${SCRIPT_DIR}"

# Telling shellcheck to stop whining...
# shellcheck source=/dev/null
source variables.sh

# Set the path for the binaries for the environment running this
OS="$(uname -o | tr '[:upper:]' '[:lower:]' | sed -e 's%^gnu/%%')"
ARCH="$(uname -m | sed -e 's/x86_64/amd64/g')"
BIN_DIR="${SCRIPT_DIR}/bin/${OS}-${ARCH}"
mkdir -p "${BIN_DIR}"
export PATH="${BIN_DIR}:${PATH}"

# Check for "kubectl" runtime or install it
if [[ "$(kubectl version --client=true -o yaml | yq .clientVersion.gitVersion)" != "v${kubectl_version}" ]]; then
  # install packaged binaries for this arch
  curl -sLo "${BIN_DIR}/kubectl" "https://dl.k8s.io/release/v${kubernetes_version}/bin/${OS}/${ARCH}/kubectl"
  curl -sLo "${BIN_DIR}/kubectl.sha256" "https://dl.k8s.io/release/v${kubernetes_version}/bin/${OS}/${ARCH}/kubectl.sha256"
  cd "${BIN_DIR}"
  echo "$(cat kubectl.sha256) kubectl" | sha256sum --check
  rm -f kubectl.sha256
  chmod ugo+rx kubectl
  cd -
fi

# Check for "sops" runtime or install it
# https://github.com/getsops/sops/releases/
if [[ "$(sops --version | grep -e '^sops' | awk '{print $2}')" != "${sops_version}" ]] ; then
  curl -sLo "${BIN_DIR}/sops-v${sops_version}.checksums.txt" "https://github.com/getsops/sops/releases/download/v${sops_version}/sops-v${sops_version}.checksums.txt"
  curl -sLo "${BIN_DIR}/sops-v${sops_version}.${OS}.${ARCH}" "https://github.com/getsops/sops/releases/download/v${sops_version}/sops-v${sops_version}.${OS}.${ARCH}"
  cd "${BIN_DIR}"
  FILENAME="sops-v${sops_version}.${OS}.${ARCH}"
  sha256sum -c <(grep "${FILENAME}" "sops-v${sops_version}.checksums.txt")
  rm -f "sops-v${sops_version}.checksums.txt"
  mv "${FILENAME}" sops
  chmod ugo+rx "${FILENAME}"
  cd -
fi

# Check for "flux" runtime or install it
# https://github.com/fluxcd/flux2/releases/
if [[ "$(flux --version | cut -d' ' -f3)" != "${flux_version}" ]] ; then
  curl -sLo "${BIN_DIR}/flux_${flux_version}_checksums.txt" "https://github.com/fluxcd/flux2/releases/download/v${flux_version}/flux_${flux_version}_checksums.txt"
  curl -sLo "${BIN_DIR}/flux_${flux_version}_${OS}_${ARCH}.tar.gz" "https://github.com/fluxcd/flux2/releases/download/v${flux_version}/flux_${flux_version}_${OS}_${ARCH}.tar.gz"
  cd "${BIN_DIR}"
  FILENAME="flux_${flux_version}_${OS}_${ARCH}.tar.gz"
  sha256sum -c <(grep "${FILENAME}" "flux_${flux_version}_checksums.txt")
  tar xvzf "${FILENAME}"
  rm -f "${FILENAME}" "flux_${flux_version}_checksums.txt"
  cd -
fi

# Check for "yq" runtime or install it
# https://github.com/mikefarah/yq/releases
if [[ "$(yq --version | awk '{ print $4 }')" != "v${yq_version}" ]] ; then
  cd "${BIN_DIR}"
  wget --no-verbose "https://github.com/mikefarah/yq/releases/download/v${yq_version}/yq_${OS}_${ARCH}.tar.gz" -O - | tar xz
  wget --no-verbose "https://github.com/mikefarah/yq/releases/download/v${yq_version}/checksums"
  wget --no-verbose "https://github.com/mikefarah/yq/releases/download/v${yq_version}/checksums_hashes_order"
  wget --no-verbose "https://github.com/mikefarah/yq/releases/download/v${yq_version}/extract-checksum.sh"
  chmod +x extract-checksum.sh
  ./extract-checksum.sh SHA-256 "yq_${OS}_${ARCH}" | rhash -c -
  mv "yq_${OS}_${ARCH}" yq
  rm -v checksums checksums_hashes_order extract-checksum.sh
  cd -
fi

# Replace project1-dev with cluster_name in all files except this script.
# Have to use -i.bak because Mac sed is garbage.
while read -r f; do
  sed -i.bak "s/project1-dev/${cluster_name}/g" "${f}"
  rm "${f}.bak"
  git add "${f}"
done < <(grep -rIl project1-dev --exclude-dir .git --exclude deploy.sh .)

# This if statement is needed for idempotency. Don't commit and push if there are no changes.
if ! git diff HEAD --quiet; then

  # Using -n so that SOME PEOPLE'S pre-commit hooks don't freak out and break things. Talking about myself here. I have a large collection of hooks.
  git commit -nm "Replacing project1-dev with ${cluster_name}"

  git push
fi

# For whatever reason, `if [[ ! -s filename ]]` doesn't appear to work correctly, so we're using stat instead.
if [[ -z "$(cat flux/flux-system/gotk-sync.yaml)" ]]; then
  flux bootstrap github \
    --branch=main \
    --components-extra image-reflector-controller,image-automation-controller \
    --owner="${flux_github_owner}" \
    --path="${flux_path}" \
    --read-write-key \
    --repository="${cluster_name}"
fi

git pull

# Add SOPS AGE secret to the cluster
sops -d flux/flux-system/sops-age.secrets.yaml | kubectl apply -f -

# Add decryption block to gotk-sync.yaml, so that the flux-system Kustomization can decrypt SOPS-encrypted files.
yq -i '(select(.kind == "Kustomization") | .spec.decryption) = {"provider": "sops", "secretRef": {"name": "sops-age"}}' flux/flux-system/gotk-sync.yaml

git add flux/flux-system/gotk-sync.yaml
if ! git diff HEAD --quiet; then
  git commit -nm "Adding decryption to gotk-sync.yaml"
  git push
  flux reconcile source git flux-system
  flux reconcile kustomization flux-system
fi

# Open the Flux floodgates! Enable everything!
while read -r f; do
  yq -i ".resources = (.resources + [\"${f}\"] | unique)" flux/flux-system/kustomization.yaml
done < <(cd flux/flux-system; find . -type f ! -name app-template.yaml ! -name kustomization.yaml | sed 's#^\./##')
git add flux/flux-system/kustomization.yaml
if ! git diff HEAD --quiet; then
  git commit -nm "Enabling all Flux Kustomizations"
  git push
  flux reconcile source git flux-system
  flux reconcile kustomization flux-system
fi

# TODO: Automatically get the kubernetes-dashboard readonly-user bearer token and push it to 1password or something?
# kubectl get secret readonly-user -n kubernetes-dashboard -o jsonpath="{.data.token}" | base64 -d
