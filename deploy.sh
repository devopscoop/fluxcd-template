#!/usr/bin/env bash

# This script is idempotent, fails fast, and should be safe to run against a running cluster. It requires the variables.sh file.
#
# On a fresh template clone it performs the full bootstrap: placeholder
# substitution, enabling optional blocks, encrypting secrets, wiring Flux
# sync/decryption, and enabling the apps -- committing and pushing as it goes.
# On an already-bootstrapped repo (detected below via the Flux sync URL) it
# skips every repo-rewriting step and only re-asserts cluster-side state
# (flux-operator install + secrets), so re-running it never rewrites the repo.

# https://vaneyckt.io/posts/safer_bash_scripts_with_set_euxo_pipefail/
set -Eeuo pipefail

# https://stackoverflow.com/questions/59895/how-do-i-get-the-directory-where-a-bash-script-is-located-from-within-the-script
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

# Need to cd to this dir, because there are a lot of git commands in this script that expect to be run from this directory.
cd "${SCRIPT_DIR}"

# Telling shellcheck to stop whining...
# shellcheck source=/dev/null
source variables.sh

# This script stages and commits files as it goes, so pre-existing changes
# would either get swept into its commits or leave `git commit` with an empty
# stage. Bail early instead.
if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "ERROR: working tree not clean. Commit or stash your changes first." >&2
  exit 1
fi

# Start from the latest main so the pushes below don't get rejected mid-run.
git pull

# The last repo-rewiring step below points spec.sync.url at this repo's own
# remote; a fresh template clone still points at the upstream template
# placeholder repo. Use that to detect an already-bootstrapped repo.
# NOTE: if a bootstrap run dies between wiring the sync URL and enabling the
# apps, this reports bootstrapped=true -- finish the remaining steps manually
# (or revert the sync commit and re-run).
bootstrapped=false
if [[ "$(yq '.spec.sync.url' flux/flux-system/flux-instance.yaml)" == "https://github.com/${git_owner}/${git_repo}" ]]; then
  bootstrapped=true
  echo "INFO: repo already bootstrapped; skipping repo rewrites, re-asserting cluster state only."
fi

# Commit and push whatever this script has staged. Gating on the stage (not
# the working tree) is what keeps re-runs from committing nothing or aborting.
commit_and_push() {
  if ! git diff --cached --quiet; then
    # Using -n so that SOME PEOPLE'S pre-commit hooks don't freak out and break things. Talking about myself here. I have a large collection of hooks.
    git commit -nm "$1"
    git push
  fi
}

if [[ "$bootstrapped" == "false" ]]; then
  # Replace project1-dev with cluster_name in all tracked files except this
  # script and AGENTS.md (which mentions the placeholder in prose).
  # Have to use -i.bak because Mac sed is garbage.
  while read -r f; do
    sed -i.bak "s/project1-dev/${cluster_name}/g" "${f}"
    rm "${f}.bak"
    git add "${f}"
  done < <(git grep -Il project1-dev -- ':!deploy.sh' ':!AGENTS.md')

  # Replace us-east-2 with region in all tracked files except this script and
  # AGENTS.md. Have to use -i.bak because Mac sed is garbage.
  while read -r f; do
    sed -i.bak "s/us-east-2/${region}/g" "${f}"
    rm "${f}.bak"
    git add "${f}"
  done < <(git grep -Il us-east-2 -- ':!deploy.sh' ':!AGENTS.md')

  commit_and_push "Replacing project1-dev with ${cluster_name}"
fi

# Some manifests ship optional blocks that are commented out by default, each
# delimited by `# >>> <marker>` / `# <<< <marker>` marker comments. This strips
# the leading comment from the lines between the given marker's delimiters
# (leaving the markers in place, so this stays idempotent and self-documenting).
# WARNING: never write the literal opening marker anywhere except the real
# markers (in prose, drop the leading hash) -- any tracked file containing it
# gets fed through awk here.
uncomment_blocks() {
  local marker=$1
  while read -r f; do
    # awk (not sed) for identical behavior on GNU and BSD/Mac. The mandatory
    # space in /^# / keeps re-runs from eating hashes one at a time, and lets
    # genuine comments inside a block survive uncommenting: write those with a
    # doubled hash (## like this) and they're left alone.
    awk -v marker="$marker" '
      index($0, "# >>> " marker) { print; inblk=1; next }
      index($0, "# <<< " marker) { print; inblk=0; next }
      inblk { sub(/^# /, ""); sub(/^#$/, ""); print; next }
      { print }
    ' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    git add "$f"
  done < <(git grep -Il "# >>> ${marker}" -- ':!deploy.sh')
}

# On EKS, uncomment the EKS-specific blocks in the app manifests (IRSA
# serviceAccount annotations, AWS NLB annotations, ...). On non-EKS platforms
# these AWS features don't exist, so the blocks stay commented.
if [[ "$bootstrapped" == "false" && "$k8s_platform" == "eks" ]]; then
  uncomment_blocks eks
  commit_and_push "Enabling EKS-specific annotation blocks"
fi

# Uncomment the Alertmanager -> Slack config in apps/kube-prometheus-stack and
# apps/victoria-metrics (the grep below finds every slack block repo-wide). The
# channel is set in each app's values.yaml; the webhook URL (the secret half)
# comes from its helm_secrets.yaml.decrypted, which gets SOPS-encrypted further
# down.
# ${var:-} so set -u doesn't kill the script on a variables.sh from before this
# variable existed.
if [[ "$bootstrapped" == "false" && "${slack_alerts:-false}" == "true" ]]; then
  uncomment_blocks slack
  commit_and_push "Enabling Alertmanager Slack notifications"
fi

flux-operator install -f "${SCRIPT_DIR}/flux/flux-system/flux-instance.yaml"

flux-operator create secret githubapp flux-system \
  --namespace=flux-system \
  --app-id="$GITHUB_APP_ID" \
  --app-installation-id="$GITHUB_APP_INSTALLATION_ID" \
  --app-private-key-file="$GITHUB_APP_PRIVATE_KEY_FILE"

if [[ "$bootstrapped" == "false" ]]; then
  # Encrypt all the `*.decrypted` files with your new sops age key. Skip
  # apps/templates/ -- that boilerplate is scaffolding for deploy_new_app.sh,
  # not a real secret (encrypt_secrets.sh skips it for the same reason).
  while read -r f; do
    enc="${f%.decrypted}"
    # sops encryption is nondeterministic (fresh data key every time), so
    # unconditionally re-encrypting would churn out a new ciphertext -- and a
    # commit -- on every run. Only encrypt when the plaintext actually changed.
    if ! { [[ -f "${enc}" ]] && sops -d "${enc}" 2>/dev/null | cmp -s - "${f}"; }; then
      sops --filename-override "${enc}" -e "${f}" > "${enc}"
      git add "${enc}"
    fi
    # The template tracks its .decrypted boilerplate, but .gitignore keeps
    # later ones untracked, where a plain `git rm` is a fatal error -- hence
    # --ignore-unmatch plus the rm fallback to still clear them off disk.
    git rm --ignore-unmatch -qf -- "${f}"
    rm -f -- "${f}"
  done < <(find . -not -path '*/templates/*' -name '*.decrypted')
  commit_and_push "Encrypting secrets"
fi

# Create the flux-system/sops-age secret, so flux has the keys to decrypt secrets.
# --age-key-file wants a *plaintext* age identity file. $SOPS_AGE_KEY already
# holds the decrypted identity (variables.sh), so feed it via process
# substitution rather than pointing at the encrypted keys.txt on disk.
# printf '%s\n' (not echo) writes the key verbatim, regardless of shell/content.
flux-operator create secret sops sops-age \
  --namespace=flux-system \
  --age-key-file <(printf '%s\n' "$SOPS_AGE_KEY")

if [[ "$bootstrapped" == "false" ]]; then
  # Add decryption block, so that the flux-system Kustomization can decrypt
  # SOPS-encrypted files. Match by content rather than position: patches[0]
  # isn't necessarily the decryption patch once update_flux-instance.sh has
  # added its image-pin and resource patches.
  if ! yq '.spec.kustomize.patches[].patch' "${SCRIPT_DIR}/flux/flux-system/flux-instance.yaml" | grep -q '/spec/decryption'; then
    yq -i '.spec.kustomize.patches += [{"patch": "- op: add\n  path: /spec/decryption\n  value:\n    provider: sops\n    secretRef:\n      name: sops-age\n", "target": {"kind": "Kustomization"}}]' "${SCRIPT_DIR}/flux/flux-system/flux-instance.yaml"
  fi

  # Prefix all Flux Kustomization spec.path values with ${flux_path}/ so they
  # resolve from the repo root. Strip-then-prepend (rather than split) so
  # re-runs converge and paths containing ${flux_path}/ twice don't get mangled.
  while read -r f; do
    yq -i 'select(.kind == "Kustomization").spec.path |= ("'"${flux_path}"'/" + sub("^'"${flux_path}"'/", ""))' "${f}"
    git add "${f}"
  done < <(find flux/flux-system -name "*.yaml" -not -name "kustomization.yaml")
  yq -i '.spec.update.path |= ("'"${flux_path}"'/" + sub("^'"${flux_path}"'/", ""))' flux/flux-system/imageupdateautomation.yaml
  git add flux/flux-system/imageupdateautomation.yaml

  # Add sync section so flux knows where to find its code. This is the LAST
  # yq edit before the commit because its url doubles as the bootstrapped
  # sentinel above.
  yq -i "
    .spec.sync.kind = \"GitRepository\" |
    .spec.sync.url = \"https://github.com/${git_owner}/${git_repo}\" |
    .spec.sync.ref = \"refs/heads/main\" |
    .spec.sync.path = \"${flux_path}/flux\" |
    .spec.sync.pullSecret = \"flux-system\" |
    .spec.sync.provider = \"github\"
    " "${SCRIPT_DIR}/flux/flux-system/flux-instance.yaml"
  git add "${SCRIPT_DIR}/flux/flux-system/flux-instance.yaml"

  commit_and_push "Adding sync and decryption."
  # flux reconcile source git flux-system
  # flux reconcile kustomization flux-system

  flux-operator install -f "${SCRIPT_DIR}/flux/flux-system/flux-instance.yaml"

  # Open the Flux floodgates! Enable everything!
  # Observability is the VictoriaMetrics stack (victoria-metrics, victoria-logs,
  # tempo, otel-collector, goalert; cnpg is here because goalert's database
  # depends on it). The kube-prometheus-stack + alloy + loki alternative stays in
  # the repo but disabled -- the two stacks are either/or (see
  # apps/victoria-metrics/README.md), so to switch back, swap the two groups.
  core_app_list="cert-manager-custom-resources.yaml cert-manager.yaml external-dns.yaml imagepolicies.yaml imagerepositories.yaml imageupdateautomation.yaml sops-age.secrets.yaml cnpg.yaml victoria-metrics.yaml victoria-logs.yaml tempo.yaml otel-collector.yaml goalert.yaml eg.yaml eg-custom-resources.yaml"
  case "$k8s_platform" in
    eks)
      app_list="metrics-server.yaml aws-load-balancer-controller.yaml eks-storage-classes.yaml cluster-viewers.yaml karpenter-crd.yaml karpenter.yaml karpenter-custom-resources.yaml"
      ;;
    k0s)
      app_list="metallb.yaml metallb-custom-resources.yaml"
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
    # A resources entry pointing at a missing file breaks the whole
    # flux-system kustomize build once pushed, so refuse to add one.
    # (sops-age.secrets.yaml is created by hand pre-deploy -- see README.md.)
    if [[ ! -f "flux/flux-system/${app}" ]]; then
      echo "ERROR: flux/flux-system/${app} does not exist; refusing to enable it." >&2
      exit 1
    fi
    yq -i ".resources = (.resources + [\"${app}\"] | unique)" flux/flux-system/kustomization.yaml
  done
  git add flux/flux-system/kustomization.yaml
  commit_and_push "Enabling Flux Kustomizations"
  # flux reconcile source git flux-system
  # flux reconcile kustomization flux-system
fi
