#!/usr/bin/env bash

# https://vaneyckt.io/posts/safer_bash_scripts_with_set_euxo_pipefail/
set -Eeuo pipefail

# https://stackoverflow.com/questions/59895/how-do-i-get-the-directory-where-a-bash-script-is-located-from-within-the-script
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

while read -r f; do
  echo "Decrypting \"${f}\"..."

  # Don't leave a partial .decrypted file behind on failure — encrypt_secrets.sh
  # would encrypt it over the real ciphertext on its next run.
  if sops -d "${f}" > "${f}.decrypted"; then
    rm "${f}"
  else  
    rm -f "${f}.decrypted"
  fi
done < <(find "${SCRIPT_DIR}" -not -path "*/templates/*" \
  \( -name 'secrets.yaml' -o -name '*.secrets.yaml' -o -name 'helm_secrets.yaml' -o -name '*.helm_secrets.yaml' \))
