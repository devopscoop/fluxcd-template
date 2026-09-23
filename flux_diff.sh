#!/usr/bin/env bash
#
# flux_diff.sh - show what Flux would apply differently.
#
# Renders the cluster twice with flate (https://github.com/home-operations/flate),
# entirely offline: once from this working tree (committed or not) and once from
# the merge-base of HEAD and BASE_REV, then prints the diff of the rendered
# objects. HelmReleases are templated, so a chart bump or a values edit shows up
# as the resulting Deployment change. The flux-diff GitHub workflow runs this on
# every pull request; run it yourself before pushing.
#
# Usage: ./flux_diff.sh [-o STYLE] [BASE_REV]
#   BASE_REV  revision to compare against; its merge-base with HEAD is rendered
#             (default: origin/main)
#   -o STYLE  flate output style: human (default on a terminal), github (default
#             otherwise), brief, diff, html, gitlab, gitea
#
# Output: the diff on stdout, flate's log and progress on stderr.
# Exit codes: 0 rendered (with or without differences); 1 this tree fails to
# render; 2 only the base fails to render (main is already broken); 64 usage or
# environment error.
#
# What gets rendered - only the apps enabled in the `resources` list of
# flux/flux-system/kustomization.yaml, exactly as in the cluster. flate loads
# every YAML file in the directory it is pointed at and ignores kustomize
# `resources` lists, so this hands it a generated root Kustomization whose
# spec.path is that directory: the same object the FluxInstance's sync creates
# in the cluster, and flate kustomize-builds the directory from there.
#
# Template mode - fluxcd-template itself ships `resources: []` (deploy.sh fills
# it in at bootstrap), so nothing would render. When the list is empty, every
# Kustomization whose spec.path exists is enabled instead, the tracked
# *.decrypted boilerplate is copied to the encrypted filenames the
# kustomizations reference, and flate runs with --skip-schema-validation,
# because placeholders such as falcon-platform's CHANGEME-CID fail chart
# values schemas. Bootstrapped repos keep the schema check.
#
# Both trees are rendered from copies under a temporary directory; the working
# tree is never modified. Secrets never reach the output: flate excludes Secret
# objects by default and cannot decrypt SOPS, so an encrypted helm_secrets.yaml
# still renders its HelmRelease (with placeholder values) and neither plaintext
# nor ciphertext appears in the diff.

set -euo pipefail

usage() {
  sed -n '/^# Usage:/,/^#$/{ /^#$/d; s/^# //; p; }' "$0"
}

style=""
while getopts ":o:h" opt; do
  case "${opt}" in
    o) style=${OPTARG} ;;
    h) usage; exit 0 ;;
    *) usage >&2; exit 64 ;;
  esac
done
shift $((OPTIND - 1))
[[ $# -le 1 ]] || { usage >&2; exit 64; }
base_rev=${1:-origin/main}
if [[ -z "${style}" ]]; then
  if [[ -t 1 ]]; then style=human; else style=github; fi
fi

for tool in flate yq git; do
  command -v "${tool}" > /dev/null || {
    echo "flux_diff.sh: ${tool} not found. See README.md -> \"Install required packages\"." >&2
    exit 64
  }
done

repo_root=$(git rev-parse --show-toplevel)
cd "${repo_root}"
base_sha=$(git merge-base "${base_rev}" HEAD) || {
  echo "flux_diff.sh: no merge-base between HEAD and ${base_rev}" >&2
  exit 64
}

# Where the Flux Kustomizations live: flux/flux-system in a fork of the
# template, <prefix>/flux/flux-system after a `git subtree add`.
ks_dir=$(git ls-files 'flux/flux-system/kustomization.yaml' '*/flux/flux-system/kustomization.yaml' | head -1)
[[ -n "${ks_dir}" ]] || {
  echo "flux_diff.sh: no flux/flux-system/kustomization.yaml in this repo" >&2
  exit 64
}
ks_dir=$(dirname "${ks_dir}")

tmp=$(mktemp -d "${TMPDIR:-/tmp}/flux_diff.XXXXXX")
trap 'rm -rf "${tmp}"' EXIT

# Copies of both trees. flate resolves each Kustomization's spec.path against
# the git top level of the tree it renders, hence the `git init`.
mkdir -p "${tmp}/head" "${tmp}/base"
tar -C "${repo_root}" --exclude=.git -cf - . | tar -C "${tmp}/head" -xf -
git archive "${base_sha}" | tar -C "${tmp}/base" -xf -
git -C "${tmp}/head" init -q
git -C "${tmp}/base" init -q

warn() { # $1 = repo-relative file, $2 = message
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    echo "::warning file=$1::$2"
  else
    echo "flux_diff.sh: warning: $1: $2" >&2
  fi
}

template_mode=0
prepare() { # $1 = tree root, $2 = head|base
  local root=$1 side=$2 entry=$1/flux-diff-entry ks=$1/${ks_dir}/kustomization.yaml f p
  mkdir -p "${entry}"
  cat > "${entry}/flux-system.yaml" <<EOF
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: flux-system
  namespace: flux-system
spec:
  interval: 10m
  path: ./${ks_dir}
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
EOF

  if [[ "$(yq '.resources | length' "${ks}")" == 0 ]]; then
    echo "flux_diff.sh: ${side}: resources is empty (template repo), rendering every Kustomization" >&2
    [[ "${side}" == base ]] || template_mode=1
    for f in "${root}/${ks_dir}"/*.yaml; do
      [[ "$(basename "${f}")" != app-template.yaml ]] || continue  # the scaffold deploy_new_app.sh copies
      [[ "$(yq '.apiVersion' "${f}")" == kustomize.toolkit.fluxcd.io/* ]] || continue  # not kustomization.yaml
      p=$(yq '.spec.path' "${f}")
      if [[ -d "${root}/${p}" ]]; then
        yq -i ".resources += [\"$(basename "${f}")\"]" "${ks}"
      elif [[ "${side}" == head ]]; then
        warn "${ks_dir}/$(basename "${f}")" "spec.path ${p} does not exist; skipped"
      fi
    done
  fi

  # Stand the tracked plaintext boilerplate in for the encrypted files the
  # kustomizations reference. A bootstrapped repo has none of these.
  while IFS= read -r f; do
    [[ -e "${f%.decrypted}" ]] || cp "${f}" "${f%.decrypted}"
  done < <(find "${root}" -name '*.decrypted' -not -path '*/templates/*')
}
prepare "${tmp}/head" head
prepare "${tmp}/base" base

flags=()
[[ "${template_mode}" == 0 ]] || flags+=(--skip-schema-validation)
# The flate GitHub action exports FLATE_BASE, which flate reads as --base and
# rejects together with --path-orig.
unset FLATE_BASE
export FLATE_NO_PROGRESS=1

# flate exits non-zero only when something fails to render; a diff by itself is
# exit 0. Anonymous chart pulls from shared CI runner IPs get rate-limited
# (public.ecr.aws answers 429 for the karpenter charts), and flate fails fast on
# that rather than retrying, so wait it out and rerun: everything that rendered
# is cached on disk, and a rerun only fetches what failed.
rc=0
for attempt in 1 2 3 4; do
  rc=0
  flate diff all \
    --path "${tmp}/head/flux-diff-entry" \
    --path-orig "${tmp}/base/flux-diff-entry" \
    --output "${style}" ${flags[@]+"${flags[@]}"} \
    > "${tmp}/diff.txt" 2> "${tmp}/flate.log" || rc=$?
  if [[ "${rc}" != 0 && "${attempt}" -lt 4 ]] && grep -q 'status code 429' "${tmp}/flate.log"; then
    echo "flux_diff.sh: registry rate limit (429) on attempt ${attempt}; retrying in $((attempt * 30))s" >&2
    sleep $((attempt * 30))
    continue
  fi
  break
done

cat "${tmp}/flate.log" >&2
cat "${tmp}/diff.txt"
[[ "${rc}" != 0 ]] || exit 0

# A failure only on the base side means main is already broken and this tree
# may be the fix: report it, but distinguish it from a failure of this tree.
if grep -q '^flate error: orig snapshot:' "${tmp}/flate.log" && ! grep -q 'current snapshot' "${tmp}/flate.log"; then
  echo "flux_diff.sh: the base (${base_sha}) fails to render; this tree renders clean" >&2
  exit 2
fi
echo "flux_diff.sh: this tree fails to render (flate exit ${rc})" >&2
exit 1
