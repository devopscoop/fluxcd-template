#!/usr/bin/env bash

# Applies OpenBao's configuration from this directory, so it is reviewed and
# versioned in git like the rest of the cluster: the kv v2 secrets engine at
# secret/, the Kubernetes auth method, every ACL policy in policies/
# (policies/<name>.hcl becomes policy <name>), and the Kubernetes auth roles
# at the bottom of this file. Idempotent; re-run it after changing any of
# them. It never deletes: remove a dropped policy or role by hand
# (bao policy delete <name>, bao delete auth/kubernetes/role/<name>).
#
# Why a script and not OpenBao's declarative self-initialization (the
# initialize config stanza): with Raft retry_join, a node that starts on an
# empty volume can self-initialize a second, separate cluster instead of
# joining the existing one (openbao/openbao#3652, open as of 2.7.0). Seen on
# first install, too. Self-init also runs only once, so it could never apply
# a later policy change anyway.
#
# Talks to the active node through a kubectl port-forward and trusts the CA
# in the server's cert-manager secret, so it needs kubectl pointed at the
# cluster and the bao CLI (the openbao package in Brewfile/pkglist.txt).
#
# Authentication: if BAO_TOKEN is set, it is used. The first run, right after
# `bao operator init`, needs that root token, because the admin role doesn't
# exist yet. Otherwise the script logs in through the admin role with a
# short-lived token for the openbao-admin ServiceAccount (README.md ->
# "Administering OpenBao") and revokes it on exit.
#
# Usage: ./configure.sh    (from any directory)
#        OPENBAO_LOCAL_PORT=18200 ./configure.sh    (if 8200 is taken)

# https://vaneyckt.io/posts/safer_bash_scripts_with_set_euxo_pipefail/
set -Eeuo pipefail

# https://stackoverflow.com/questions/59895/how-do-i-get-the-directory-where-a-bash-script-is-located-from-within-the-script
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

ns=openbao
port="${OPENBAO_LOCAL_PORT:-8200}"

tmp="$(mktemp -d)"
login_token=""
cleanup() {
  if [[ -n "$login_token" ]]; then
    BAO_TOKEN="$login_token" bao token revoke -self >/dev/null || true
  fi
  [[ -n "${pf_pid:-}" ]] && kill "$pf_pid" 2>/dev/null
  rm -rf "$tmp"
}
trap cleanup EXIT

kubectl -n "$ns" get secret openbao-server-tls -o jsonpath='{.data.ca\.crt}' | base64 -d > "${tmp}/ca.crt"
export BAO_ADDR="https://127.0.0.1:${port}" BAO_CACERT="${tmp}/ca.crt"

kubectl -n "$ns" port-forward svc/openbao-active "${port}:8200" >/dev/null 2>"${tmp}/port-forward.err" &
pf_pid=$!
# bao status exits 0 (unsealed), 2 (sealed) or 1 (error, e.g. the
# port-forward isn't listening yet).
for _ in {1..50}; do
  rc=0
  bao status >/dev/null 2>&1 || rc=$?
  [[ "$rc" -ne 1 ]] && break
  if ! kill -0 "$pf_pid" 2>/dev/null; then
    echo "ERROR: kubectl port-forward to svc/openbao-active failed:" >&2
    cat "${tmp}/port-forward.err" >&2
    exit 1
  fi
  sleep 0.2
done
if [[ "$rc" -ne 0 ]]; then
  echo "ERROR: OpenBao is not reachable and unsealed (bao status exited ${rc}); has it been initialized? See README.md -> \"First start\"." >&2
  exit 1
fi

if [[ -z "${BAO_TOKEN:-}" ]]; then
  # --duration 10m is the API server's minimum; the token is only exchanged
  # once, right here.
  kubectl -n "$ns" create token openbao-admin --audience openbao --duration 10m \
    | bao write -field=token auth/kubernetes/login role=admin jwt=- > "${tmp}/token"
  login_token="$(cat "${tmp}/token")"
  export BAO_TOKEN="$login_token"
fi

echo "==> kv v2 secrets engine at secret/"
if ! bao read sys/mounts/secret >/dev/null 2>&1; then
  bao secrets enable -path=secret -version=2 kv
fi

echo "==> Kubernetes auth method at kubernetes/"
if ! bao read sys/auth/kubernetes >/dev/null 2>&1; then
  bao auth enable kubernetes
fi
# Only the host: OpenBao falls back to its own pod's CA bundle and
# ServiceAccount token for the TokenReview calls (the chart binds
# system:auth-delegator to that ServiceAccount).
bao write auth/kubernetes/config kubernetes_host=https://kubernetes.default.svc

echo "==> ACL policies"
for f in "${SCRIPT_DIR}"/policies/*.hcl; do
  bao policy write "$(basename "$f" .hcl)" "$f"
done

# Every role only accepts ServiceAccount tokens minted for the "openbao"
# audience, so a token meant for the Kubernetes API (like a pod's default
# mounted one) can't be replayed here.
echo "==> Kubernetes auth roles"

# Humans: whoever may create tokens for the openbao-admin ServiceAccount
# (admin-serviceaccount.yaml) is an OpenBao admin.
bao write auth/kubernetes/role/admin \
  bound_service_account_names=openbao-admin \
  bound_service_account_namespaces=openbao \
  audience=openbao \
  token_policies=admin \
  token_ttl=1h \
  token_max_ttl=8h

# The external-secrets controller, via the ClusterSecretStore in
# apps/external-secrets-custom-resources.
bao write auth/kubernetes/role/external-secrets \
  bound_service_account_names=external-secrets \
  bound_service_account_namespaces=external-secrets \
  audience=openbao \
  token_policies=external-secrets \
  token_ttl=15m \
  token_max_ttl=1h

echo "==> Done"
