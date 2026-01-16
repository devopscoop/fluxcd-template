#!/usr/bin/env bash

# https://vaneyckt.io/posts/safer_bash_scripts_with_set_euxo_pipefail/
set -Eeuo pipefail

# https://stackoverflow.com/questions/59895/how-do-i-get-the-directory-where-a-bash-script-is-located-from-within-the-script
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

while read -r f; do
  # shellcheck disable=SC2094
  sops --filename-override "${f%%.decrypted}" -e "${f}" > "${f%%.decrypted}"
  rm "${f}"
done < <(find "${SCRIPT_DIR}" -name '*.yaml.decrypted')
