#!/usr/bin/env bash

# Toggles the optional config blocks for the given marker(s). Some manifests
# ship optional blocks that are commented out by default, each delimited by
# `>>> <marker>` / `<<< <marker>` comment delimiters (with a leading hash on
# the real markers). --enable strips the leading comment from the lines
# between a marker's delimiters in every tracked file containing the marker;
# --disable puts it back. The delimiters stay in place, so both directions are
# idempotent and self-documenting. Each processed file is printed to stdout,
# one per line; this script does no git staging or committing, so callers own
# the bookkeeping (deploy.sh stages exactly the files printed) and running it
# by hand never touches your index.
#
# deploy.sh runs the --enable side on every invocation (the eks/slack markers,
# gated on variables.sh) and never disables, so normally there is no need to
# run this directly. It exists as its own script so a block can also be
# toggled without a full deploy -- no variables.sh, cluster access, or AWS
# credentials needed -- e.g. enabling Slack alerts on an already-deployed
# cluster (see apps/victoria-metrics/README.md), or turning them back off.
#
# WARNING: never write the literal opening marker anywhere except the real
# markers (in prose, drop the leading hash) -- any tracked file containing it
# gets fed through awk here. (Two exceptions are excluded from the grep below:
# this file, and apps/templates/, whose boilerplate must keep shipping with
# its blocks commented out.)
#
# Usage: ./toggle_blocks.sh --enable|--disable MARKER[,MARKER...] ...
#
# A mode flag applies to the markers after it, so modes can be mixed:
# ./toggle_blocks.sh --enable eks --disable slack

# https://vaneyckt.io/posts/safer_bash_scripts_with_set_euxo_pipefail/
set -Eeuo pipefail

# https://stackoverflow.com/questions/59895/how-do-i-get-the-directory-where-a-bash-script-is-located-from-within-the-script
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

# git grep scopes its search to the current directory, which keeps this
# template's tree the search root even when it's nested inside a larger repo
# as a subtree.
cd "${SCRIPT_DIR}"

usage() {
  echo "Usage: $0 --enable|--disable MARKER[,MARKER...] ..." >&2
  exit 1
}

# Parse everything before transforming anything, so a typo late in the
# argument list can't leave the tree half-toggled.
mode=""
ops=()
for arg in "$@"; do
  case "$arg" in
    --enable) mode="enable" ;;
    --disable) mode="disable" ;;
    -*) usage ;;
    *)
      [[ -n "$mode" ]] || usage
      IFS=',' read -ra markers <<< "$arg"
      for marker in "${markers[@]}"; do
        [[ -n "$marker" ]] && ops+=("${mode}:${marker}")
      done
      ;;
  esac
done
[[ ${#ops[@]} -gt 0 ]] || usage

for op in "${ops[@]}"; do
  mode=${op%%:*}
  marker=${op#*:}
  while read -r f; do
    # awk (not sed) for identical behavior on GNU and BSD/Mac. Enabling: the
    # mandatory space in /^# / keeps re-runs from eating hashes one at a time,
    # and lets genuine comments inside a block survive: write those with a
    # doubled hash (## like this) and they're left alone. Disabling: any line
    # already starting with a hash (those doubled-hash comments included) is
    # left alone, so it's idempotent too; blank lines become a lone hash, the
    # exact inverse of enabling.
    awk -v marker="$marker" -v mode="$mode" '
      index($0, "# >>> " marker) { print; inblk=1; next }
      index($0, "# <<< " marker) { print; inblk=0; next }
      !inblk           { print; next }
      mode == "enable" { sub(/^# /, ""); sub(/^#$/, ""); print; next }
      /^#/             { print; next }
      /^[[:space:]]*$/ { print "#"; next }
      { print "# " $0 }
    ' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    printf '%s\n' "$f"
  done < <(git grep -Il "# >>> ${marker}" -- ':!toggle_blocks.sh' ':!apps/templates')
done
