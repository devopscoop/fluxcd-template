#!/usr/bin/env bash

# Uncomments the optional config blocks for the given marker(s). Some
# manifests ship optional blocks that are commented out by default, each
# delimited by `>>> <marker>` / `<<< <marker>` comment delimiters (with a
# leading hash on the real markers). For each marker given, this strips the
# leading comment from the lines between its delimiters in every tracked file
# containing the marker, leaving the delimiters in place, so it stays
# idempotent and self-documenting. Each processed file is printed to stdout,
# one per line; this script does no git staging or committing, so callers own
# the bookkeeping (deploy.sh stages exactly the files printed) and running it
# by hand never touches your index.
#
# deploy.sh runs this on every invocation (the eks/slack markers, gated on
# variables.sh), so normally there is no need to run it directly. It exists as
# its own script so a block can also be opened without a full deploy -- no
# variables.sh, cluster access, or AWS credentials needed -- e.g. enabling
# Slack alerts on an already-deployed cluster (see
# apps/victoria-metrics/README.md).
#
# WARNING: never write the literal opening marker anywhere except the real
# markers (in prose, drop the leading hash) -- any tracked file containing it
# gets fed through awk here. (This file is the one exception: it's excluded
# from the grep below.)
#
# Usage: ./uncomment_blocks.sh MARKER [MARKER...]

# https://vaneyckt.io/posts/safer_bash_scripts_with_set_euxo_pipefail/
set -Eeuo pipefail

# https://stackoverflow.com/questions/59895/how-do-i-get-the-directory-where-a-bash-script-is-located-from-within-the-script
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

# git grep scopes its search to the current directory, which keeps this
# template's tree the search root even when it's nested inside a larger repo
# as a subtree.
cd "${SCRIPT_DIR}"

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 MARKER [MARKER...]" >&2
  exit 1
fi

for marker in "$@"; do
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
    printf '%s\n' "$f"
  done < <(git grep -Il "# >>> ${marker}" -- ':!uncomment_blocks.sh')
done
