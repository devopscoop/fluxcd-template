#!/usr/bin/env bash

# Rewrites this template's placeholders to the cluster's values in every
# tracked file, most specific form first:
#
#   project1-dev.devops.coop -> $cluster_domain  (hostnames)
#   devopscoop-project1-dev  -> $org_name-$cluster_name  (S3 bucket names,
#                               matching aws-eks-template's naming)
#   project1-dev             -> $cluster_name
#   us-east-2                -> $region
#   arn:aws:iam::ACCOUNT_ID: -> arn:aws:iam::$aws_account_id:  (IRSA role
#                               ARNs; only the ARN form, so prose that tells
#                               you about ACCOUNT_ID stays readable)
#
# The values come from the environment: variables.sh exports them, and
# deploy.sh sources it before calling this. cluster_domain and org_name are
# optional, defaulting to what the plain project1-dev rewrite would produce
# ($cluster_name.devops.coop and devopscoop), so a variables.sh from before
# they existed behaves as it always did. aws_account_id is optional too:
# unset or empty (non-EKS platforms) leaves ACCOUNT_ID in place. To run it by
# hand without the rest of variables.sh (which decrypts keys):
#
#   cluster_name=dev region=us-east-2 org_name=acme cluster_domain=dev.acme.com aws_account_id=123456789012 ./replace_placeholders.sh
#
# Each changed file is printed to stdout, one per line; like toggle_blocks.sh
# this does no git staging or committing (deploy.sh stages exactly the files
# printed). It's idempotent, and deploy.sh runs it on every invocation, so
# apps pulled in from the template after bootstrap get their placeholders
# rewritten too.
#
# Skipped: this file, deploy.sh, and AGENTS.md (they mention the placeholders
# in prose), and SOPS-encrypted files -- editing even their plaintext fields
# breaks the SOPS MAC, so those are reported on stderr for a manual
# `sops <file>` edit instead.

# https://vaneyckt.io/posts/safer_bash_scripts_with_set_euxo_pipefail/
set -Eeuo pipefail

# https://stackoverflow.com/questions/59895/how-do-i-get-the-directory-where-a-bash-script-is-located-from-within-the-script
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

# git grep scopes its search to the current directory, which keeps this
# template's tree the search root even when it's nested inside a larger repo
# as a subtree.
cd "${SCRIPT_DIR}"

: "${cluster_name:?must be set (see variables.sh)}"
: "${region:?must be set (see variables.sh)}"
cluster_domain=${cluster_domain:-${cluster_name}.devops.coop}
org_name=${org_name:-devopscoop}

# The values land on the replacement side of a sed s///, so refuse anything
# that sed would interpret (/, &, \) -- none of them belong in a hostname,
# bucket prefix, or region anyway.
for v in cluster_name region cluster_domain org_name; do
  if [[ ! "${!v}" =~ ^[A-Za-z0-9.-]+$ ]]; then
    echo "ERROR: ${v}='${!v}' may only contain letters, digits, dots and hyphens." >&2
    exit 1
  fi
done
aws_account_id=${aws_account_id:-}
if [[ -n "${aws_account_id}" && ! "${aws_account_id}" =~ ^[0-9]{12}$ ]]; then
  echo "ERROR: aws_account_id='${aws_account_id}' must be a 12-digit AWS account ID (or empty)." >&2
  exit 1
fi

placeholders=(
  "project1-dev.devops.coop"
  "devopscoop-project1-dev"
  "project1-dev"
  "us-east-2"
  "arn:aws:iam::ACCOUNT_ID:"
)
# An empty aws_account_id maps the ARN placeholder to itself, which the loop
# below skips.
values=(
  "${cluster_domain}"
  "${org_name}-${cluster_name}"
  "${cluster_name}"
  "${region}"
  "arn:aws:iam::${aws_account_id:-ACCOUNT_ID}:"
)

changed=()
for i in "${!placeholders[@]}"; do
  placeholder=${placeholders[$i]}
  value=${values[$i]}
  # Nothing to do when the value is the placeholder itself (e.g. region left
  # at us-east-2), and rewriting would only churn the file list.
  [[ "${value}" == "${placeholder}" ]] && continue
  pattern=${placeholder//./\\.}
  while read -r f; do
    if grep -q 'ENC\[AES256_GCM,' "${f}"; then
      echo "WARNING: ${f} is SOPS-encrypted and contains ${placeholder}; edit it with sops." >&2
      continue
    fi
    # Have to use -i.bak because Mac sed is garbage.
    sed -i.bak "s/${pattern}/${value}/g" "${f}"
    rm "${f}.bak"
    changed+=("${f}")
  done < <(git grep -IlF -e "${placeholder}" -- ':!replace_placeholders.sh' ':!deploy.sh' ':!AGENTS.md')
done

if [[ ${#changed[@]} -gt 0 ]]; then
  printf '%s\n' "${changed[@]}" | sort -u
fi
