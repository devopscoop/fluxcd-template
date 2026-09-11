#!/usr/bin/env bash

# One-command OAuth developer SSO psql session on a CNPG database whose
# Cluster has the pg-oauth marker block enabled — the scripted version of
# runbooks/connect-cnpg-database.md option 4, which documents the manual
# steps, the prerequisites, and the privilege model.
#
# What it does:
#   1. reads the oauth rule from the Cluster's .spec.postgresql.pg_hba and
#      takes the issuer from it, so there is no issuer flag to drift out of
#      sync with the manifest;
#   2. port-forwards the cluster's read-write Service to a local port;
#   3. runs psql's OAuth device flow — psql prints a URL and a code, you
#      approve in the browser via the upstream IdP, and the prompt opens in
#      your per-developer role;
#   4. kills the port-forward when psql exits.
#
# The APP argument follows this repo's conventions (namespace = APP,
# Cluster = APP-db, database = APP); -n/-c/-d override any of them for
# clusters named differently.
#
# The local psql must be 18+ with libpq's OAuth module (Debian/Ubuntu PGDG
# ship it as the libpq-oauth package; Homebrew's builds lack it). --docker
# sidesteps that by running a PGDG psql in a debian container against the
# port-forward — the path of least resistance on macOS.
#
# Usage: ./psql-oauth.sh [-U ROLE] [-p PORT] [-i CLIENT_ID] [--docker] [--print] APP
#        ./psql-oauth.sh [-U ROLE] [-p PORT] [-i CLIENT_ID] [--docker] [--print] -n NAMESPACE -c CLUSTER -d DBNAME
#
# ROLE defaults to $USER; the pg-oauth convention names roles after email
# local parts, so pass -U when your shell user differs. --print shows the
# equivalent manual commands and exits without connecting.

# https://vaneyckt.io/posts/safer_bash_scripts_with_set_euxo_pipefail/
set -Eeuo pipefail

usage() {
  sed -n 's/^# Usage: /Usage: /p; s/^#        /       /p' "$0" >&2
  exit "${1:-1}"
}

role="${USER}"
port=15432
client_id="psql"
docker=false
print_only=false
ns=""
cluster=""
db=""
app=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n) ns="$2"; shift 2 ;;
    -c) cluster="$2"; shift 2 ;;
    -d) db="$2"; shift 2 ;;
    -U) role="$2"; shift 2 ;;
    -p) port="$2"; shift 2 ;;
    -i) client_id="$2"; shift 2 ;;
    --docker) docker=true; shift ;;
    --print) print_only=true; shift ;;
    -h|--help) usage 0 ;;
    -*) usage ;;
    *) app="$1"; shift ;;
  esac
done

[[ -n "$app" || -n "$ns" ]] || usage
ns="${ns:-$app}"
cluster="${cluster:-${app:-$ns}-db}"
db="${db:-${app:-$ns}}"

# The issuer lives in the Cluster's oauth pg_hba rule — the manifest is the
# single source of truth, and it must match dex's config.issuer byte-for-byte
# anyway (see the pg-oauth block's comments).
hba="$(kubectl -n "$ns" get clusters.postgresql.cnpg.io "$cluster" \
  -o jsonpath='{range .spec.postgresql.pg_hba[*]}{@}{"\n"}{end}')"
issuer="$(grep -om1 'issuer="[^"]*"' <<<"$hba" | cut -d'"' -f2 || true)"
if [[ -z "$issuer" ]]; then
  echo "No oauth issuer in ${cluster}'s pg_hba — is the pg-oauth block enabled on" >&2
  echo "this Cluster? (./toggle_blocks.sh --enable pg-oauth; prerequisites in the" >&2
  echo "block's comments and apps/dex/README.md.)" >&2
  exit 1
fi

# The oauth hba rule only matches members of the developers group, so a role
# outside it falls through to CNPG's scram catch-all and psql prompts for a
# password that doesn't exist — a confusing dead end, and exactly what the
# default ROLE=$USER produces when your shell user differs from your email
# local part. Catch it here: pg-oauth login roles are declared in the
# Cluster's managed.roles.
login_roles="$(kubectl -n "$ns" get clusters.postgresql.cnpg.io "$cluster" \
  -o jsonpath='{range .spec.managed.roles[?(@.login==true)]}{.name}{"\n"}{end}')"
if ! grep -qxF "$role" <<<"$login_roles"; then
  echo "Role '${role}' is not a login role in ${cluster}'s managed.roles, so the" >&2
  echo "oauth rule (+developers) won't match it — the server would ask for a" >&2
  echo "password instead of starting the device flow. pg-oauth roles are named" >&2
  echo "after email local parts; pass -U ROLE. Login roles on this cluster:" >&2
  echo "  $(tr '\n' ' ' <<<"$login_roles")" >&2
  exit 1
fi

# sslmode=require, deliberately not verify-full: the oauth hba rule is
# hostssl so TLS is mandatory, but the server certificate names the
# in-cluster Services, not localhost (runbook option 3 has the same caveat).
conninfo() {
  echo "host=$1 port=${port} dbname=${db} user=${role} sslmode=require oauth_issuer=${issuer} oauth_client_id=${client_id}"
}

if $print_only; then
  echo "kubectl -n ${ns} port-forward svc/${cluster}-rw ${port}:5432"
  echo "psql \"$(conninfo 127.0.0.1)\""
  exit 0
fi

if ! $docker; then
  if ! command -v psql >/dev/null; then
    echo "psql not found. Install PGDG postgresql-client-18 + libpq-oauth, or use --docker." >&2
    exit 1
  fi
  pg_major="$(psql -V | grep -oE '[0-9]+' | head -1)"
  if ((pg_major < 18)); then
    echo "psql ${pg_major} found, but the OAuth device flow needs psql 18+ with the" >&2
    echo "libpq-oauth module — use --docker, or install PGDG postgresql-client-18 +" >&2
    echo "libpq-oauth (Homebrew's builds lack the module regardless of version)." >&2
    exit 1
  fi
fi

kubectl -n "$ns" port-forward "svc/${cluster}-rw" "${port}:5432" >/dev/null &
pf_pid=$!
trap 'kill "$pf_pid" 2>/dev/null || true' EXIT

# Wait for the forward to listen (bash's /dev/tcp; the subshell closes the
# probe socket). If kubectl dies first — bad Service name, no kubeconfig —
# surface that instead of spinning.
up=false
for _ in {1..50}; do
  if (exec 3<>"/dev/tcp/127.0.0.1/${port}") 2>/dev/null; then up=true; break; fi
  if ! kill -0 "$pf_pid" 2>/dev/null; then
    echo "port-forward exited — does svc/${cluster}-rw exist in namespace ${ns}?" >&2
    exit 1
  fi
  sleep 0.2
done
$up || { echo "port-forward never came up on 127.0.0.1:${port}" >&2; exit 1; }

if $docker; then
  # Docker Desktop (macOS) reaches the host's loopback via
  # host.docker.internal; on Linux the bridge can't see a 127.0.0.1-bound
  # forward, so join the host network and dial loopback directly.
  docker_args=(run --rm -it)
  if [[ "$(uname -s)" == "Darwin" ]]; then
    pg_host="host.docker.internal"
  else
    docker_args+=(--network host)
    pg_host="127.0.0.1"
  fi
  # No exec: the EXIT trap must still fire afterward to kill the port-forward.
  docker "${docker_args[@]}" debian:trixie-slim bash -c "
    apt-get update -q >/dev/null &&
    apt-get install -yq postgresql-common ca-certificates >/dev/null 2>&1 &&
    /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh -y >/dev/null &&
    apt-get install -yq postgresql-client-18 libpq-oauth >/dev/null 2>&1 &&
    exec psql '$(conninfo "$pg_host")'"
else
  psql "$(conninfo 127.0.0.1)" || {
    rc=$?
    echo "psql failed (exit ${rc}). If it reported that no OAuth flow is supported," >&2
    echo "your libpq lacks the libpq-oauth module — retry with --docker." >&2
    exit "$rc"
  }
fi
