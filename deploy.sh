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

# Replace project1-dev with cluster_name in all files except this script.
# Have to use -i.bak because Mac sed is garbage.
while read -r f; do
  sed -i.bak "s/project1-dev/${cluster_name}/g" "${f}"
  rm "${f}.bak"
  git add "${f}"
done < <(grep -rIl project1-dev --exclude-dir .git --exclude deploy.sh .)

# Replace us-east-2 with region in all files except this script.
# Have to use -i.bak because Mac sed is garbage.
while read -r f; do
  sed -i.bak "s/us-east-2/${region}/g" "${f}"
  rm "${f}.bak"
  git add "${f}"
done < <(grep -rIl us-east-2 --exclude-dir .git --exclude deploy.sh .)

# This if statement is needed for idempotency. Don't commit and push if there are no changes.
if ! git diff HEAD --quiet; then

  # Using -n so that SOME PEOPLE'S pre-commit hooks don't freak out and break things. Talking about myself here. I have a large collection of hooks.
  git commit -nm "Replacing project1-dev with ${cluster_name}"

  git push
fi

# On EKS, uncomment the IRSA serviceAccount blocks that are commented out by
# default in the app values.yaml files. Each block is delimited by
# `# >>> eks-irsa` / `# <<< eks-irsa` marker comments; we strip the leading
# comment from the lines between the markers (leaving the markers in place, so
# this stays idempotent and self-documenting). On non-EKS platforms IRSA
# doesn't exist, so the blocks stay commented.
if [[ "$k8s_platform" == "eks" ]]; then
  while read -r f; do
    # awk (not sed) for identical behavior on GNU and BSD/Mac. sub() is a no-op
    # on already-uncommented lines, so re-running this is safe.
    awk '
      /# >>> eks-irsa/ { print; inblk=1; next }
      /# <<< eks-irsa/ { print; inblk=0; next }
      inblk { sub(/^# ?/, ""); print; next }
      { print }
    ' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    git add "$f"
  done < <(grep -rIl '# >>> eks-irsa' --exclude-dir .git --exclude deploy.sh .)
  if ! git diff HEAD --quiet; then
    git commit -nm "Enabling EKS IRSA serviceAccount annotations"
    git push
  fi
fi

flux-operator install -f "${SCRIPT_DIR}/flux/flux-system/flux-instance.yaml"

flux-operator create secret githubapp flux-system \
  --namespace=flux-system \
  --app-id="$GITHUB_APP_ID" \
  --app-installation-id="$GITHUB_APP_INSTALLATION_ID" \
  --app-private-key-file="$GITHUB_APP_PRIVATE_KEY_FILE"

git pull

# Encrypt all the `*.decrypted` files with your new sops age key:
while read -r f; do
  sops --filename-override "${f//.decrypted}" -e "${f}" > "${f//.decrypted}"
  git add "${f//.decrypted}"
  git rm "${f}"
done < <(find . -name '*.decrypted')
if ! git diff HEAD --quiet; then
  git commit -nm "Encrypting secrets"
  git push
fi

# Create the flux-system/sops-age secret, so flux has the keys to decrypt secrets.
flux-operator create secret sops sops-age \
  --namespace=flux-system \
  --age-key-file "${new_key}"

# Add sync section so flux knows where to find its code.
yq -i "
  .spec.sync.kind = \"GitRepository\" |
  .spec.sync.url = \"https://github.com/${git_owner}/${git_repo}\" |
  .spec.sync.ref = \"refs/heads/main\" |
  .spec.sync.path = \"${flux_path}/flux\" |
  .spec.sync.pullSecret = \"flux-system\" |
  .spec.sync.provider = \"github\"
  " "${SCRIPT_DIR}/flux/flux-system/flux-instance.yaml"

# Add decryption block, so that the flux-system Kustomization can decrypt SOPS-encrypted files.
yq -i '.spec.kustomize.patches[0].patch = "- op: add\n  path: /spec/decryption\n  value:\n    provider: sops\n    secretRef:\n      name: sops-age\n" | .spec.kustomize.patches[0].target.kind = "Kustomization"' "${SCRIPT_DIR}/flux/flux-system/flux-instance.yaml"

# Prefix all Flux Kustomization spec.path values with ${flux_path}/ so they resolve from the repo root.
while read -r f; do
  yq -i 'select(.kind == "Kustomization").spec.path |= (split("'"${flux_path}"'/")[-1] | "'"${flux_path}"'/" + .)' "${f}"
  git add "${f}"
done < <(find flux/flux-system -name "*.yaml" -not -name "kustomization.yaml")
yq -i '.spec.update.path |= (split("'"${flux_path}"'/")[-1] | "'"${flux_path}"'/" + .)' flux/flux-system/imageupdateautomation.yaml
git add flux/flux-system/imageupdateautomation.yaml

if ! git diff HEAD --quiet; then
  git commit -nm "Adding sync and decryption."
  git push
  # flux reconcile source git flux-system
  # flux reconcile kustomization flux-system
fi

flux-operator install -f "${SCRIPT_DIR}/flux/flux-system/flux-instance.yaml"

# Open the Flux floodgates! Enable everything!
core_app_list="cert-manager-custom-resources.yaml cert-manager.yaml external-dns.yaml imagepolicies.yaml imagerepositories.yaml imageupdateautomation.yaml sops-age.secrets.yaml"
case "$k8s_platform" in
  eks)
    app_list="metrics-server.yaml aws-load-balancer-controller.yaml eks-storage-classes.yaml"
    ;;
  k0s)
    app_list="metallb.yaml metallb-custom-resources.yaml rook-ceph.yaml rook-ceph-cluster.yaml"
    ;;
  talos)
    app_list="metallb.yaml metallb-custom-resources.yaml"
    ;;
  *)
    echo "ERROR: k8s_platform invalid" >&2
    exit 1
    ;;
esac
for app in $core_app_list $app_list; do
  yq -i ".resources = (.resources + [\"${app}\"] | unique)" flux/flux-system/kustomization.yaml
done
git add flux/flux-system/kustomization.yaml
if ! git diff HEAD --quiet; then
  git commit -nm "Enabling Flux Kustomizations"
  git push
  # flux reconcile source git flux-system
  # flux reconcile kustomization flux-system
fi
