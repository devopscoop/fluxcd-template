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
# Interactive or batch. With a terminal on stdin and no -c/-f you get the
# psql prompt and read the device-flow URL and code off it as usual.
# Otherwise — `-c`/`-f` after `--`, SQL piped in, or an agent such as Claude
# Code running the script — psql runs the statements and exits, and the
# script opens dex's verification page (code prefilled) in the local browser
# the moment psql prints the device-flow prompt: approve there and the
# results come back, whether or not anyone is reading the terminal. Every run is
# one connection and therefore one approval — libpq has no way to hand psql
# a token obtained earlier (only the PQsetAuthDataHook C API) — so batch
# statements into a single invocation rather than one per query:
#
#   ./psql-oauth.sh APP -- -c 'select count(*) from users'
#   ./psql-oauth.sh APP -- -At -c 'select id from users order by 1'
#   ./psql-oauth.sh APP <<'SQL'
#   \dt
#   select ...;
#   SQL
#
# The APP argument follows this repo's conventions (namespace = APP,
# Cluster = APP-db, database = APP); -n/-c/-d override any of them for
# clusters named differently. Everything after `--` goes to psql verbatim
# (with --docker, feed files through stdin rather than -f: the container
# sees none of the host filesystem).
#
# The local psql must be 18+ with libpq's OAuth module: Debian/Ubuntu PGDG
# ship it as the libpq-oauth package, Arch includes it in postgresql-libs,
# and on macOS Homebrew's postgresql@18 formula builds it (--with-libcurl;
# the libpq formula does not). postgresql@18 is keg-only, so the script also
# looks for its versioned `psql-18` link. --docker runs a PGDG psql in a
# debian container against the port-forward for machines with none of these.
#
# Usage: ./psql-oauth.sh [-U ROLE] [-p PORT] [-i CLIENT_ID] [--docker] [--print] APP [-- PSQL_ARGS...]
#        ./psql-oauth.sh [-U ROLE] [-p PORT] [-i CLIENT_ID] [--docker] [--print] -n NAMESPACE -c CLUSTER -d DBNAME [-- PSQL_ARGS...]
#
# ROLE defaults to $PGUSER, else the local part of `git config user.email`,
# else $USER: the pg-oauth convention names roles after email local parts,
# so the git identity is usually right — pass -U (or export PGUSER) when it
# isn't. --print shows the equivalent manual commands and exits without
# connecting.

# https://vaneyckt.io/posts/safer_bash_scripts_with_set_euxo_pipefail/
set -Eeuo pipefail

usage() {
  sed -n 's/^# Usage: /Usage: /p; s/^#        /       /p' "$0" >&2
  exit "${1:-1}"
}

role="${PGUSER:-}"
port=15432
client_id="psql"
docker=false
print_only=false
ns=""
cluster=""
db=""
app=""
psql_args=()

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
    --) shift; psql_args=("$@"); break ;;
    -*) usage ;;
    *) app="$1"; shift ;;
  esac
done

[[ -n "$app" || -n "$ns" ]] || usage
ns="${ns:-$app}"
cluster="${cluster:-${app:-$ns}-db}"
db="${db:-${app:-$ns}}"
if [[ -z "$role" ]]; then
  role="$(git config user.email 2>/dev/null | cut -d@ -f1 || true)"
fi
role="${role:-$USER}"

# Batch mode is everything but an interactive psql session: stdin isn't a
# terminal (an agent's shell tool, a pipe, a heredoc), or the psql arguments
# make it run and exit (-c/-f/-l and their long forms, alone or inside a
# short-option cluster like -Atc). Batch runs get the device-flow prompt
# opened in the browser (below); only a developer at the psql prompt doesn't.
psql_interactive=true
for arg in ${psql_args[@]+"${psql_args[@]}"}; do
  case "$arg" in
    --command|--command=*|--file|--file=*|--list) psql_interactive=false ;;
    --*) ;;
    -*[cfl]*) psql_interactive=false ;;
  esac
done
batch=true
if [[ -t 0 ]] && $psql_interactive; then batch=false; fi

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
# password that doesn't exist — a confusing dead end, and exactly what a
# default ROLE that differs from your email local part produces. Catch it
# here: pg-oauth login roles are declared in the Cluster's managed.roles.
login_roles="$(kubectl -n "$ns" get clusters.postgresql.cnpg.io "$cluster" \
  -o jsonpath='{range .spec.managed.roles[?(@.login==true)]}{.name}{"\n"}{end}')"
if ! grep -qxF "$role" <<<"$login_roles"; then
  echo "Role '${role}' is not a login role in ${cluster}'s managed.roles, so the" >&2
  echo "oauth rule (+developers) won't match it — the server would ask for a" >&2
  echo "password instead of starting the device flow. pg-oauth roles are named" >&2
  echo "after email local parts; pass -U ROLE or export PGUSER. Login roles on" >&2
  echo "this cluster:" >&2
  echo "  $(tr '\n' ' ' <<<"$login_roles")" >&2
  exit 1
fi

# sslmode=require, deliberately not verify-full: the oauth hba rule is
# hostssl so TLS is mandatory, but the server certificate names the
# in-cluster Services, not localhost (runbook option 3 has the same caveat).
#
# oauth_scope must ask for email: dex only embeds the email claim — the
# validator's authn_field, i.e. what maps the token to a role — when the
# client requests the email scope. The hba rule's scope="" merely disables
# the validator's scope check; it requests nothing on the client's behalf.
conninfo() {
  echo "host=$1 port=${port} dbname=${db} user=${role} sslmode=require oauth_issuer=${issuer} oauth_client_id=${client_id} oauth_scope='openid email'"
}

if $print_only; then
  echo "kubectl -n ${ns} port-forward svc/${cluster}-rw ${port}:5432"
  cmd="psql \"$(conninfo 127.0.0.1)\""
  for arg in ${psql_args[@]+"${psql_args[@]}"}; do
    cmd+=" $(printf '%q' "$arg")"
  done
  echo "$cmd"
  exit 0
fi

# psql lookup: PATH's psql first, then psql-18 — the versioned link Homebrew's
# keg-only postgresql@18 puts on PATH (the only Homebrew psql with the OAuth
# module; the libpq formula's lacks it and would fail later with "no OAuth
# flows are available").
psql_bin=""
if ! $docker; then
  found=""
  for candidate in psql psql-18; do
    command -v "$candidate" >/dev/null || continue
    major="$("$candidate" -V | grep -oE '[0-9]+' | head -1 || true)"
    [[ "$major" =~ ^[0-9]+$ ]] || continue
    found="${found:+${found}, }${candidate} ${major}"
    if ((major >= 18)); then psql_bin="$candidate"; break; fi
  done
  if [[ -z "$psql_bin" ]]; then
    echo "No psql 18+ found${found:+ (on PATH: ${found})}. The OAuth device flow needs psql 18" >&2
    echo "with libpq's OAuth module: PGDG postgresql-client-18 + libpq-oauth, Arch's" >&2
    echo "postgresql-libs, or Homebrew's postgresql@18 — or use --docker." >&2
    exit 1
  fi
fi

# kubectl's stderr goes to a temp file, not the terminal: on every exit the
# torn-down client connection makes port-forward print "connection reset by
# peer ... lost connection to pod", which is pure teardown noise — but the
# same stream carries the real reason when the forward fails to start, so
# the failure branch below replays it.
tmp="$(mktemp -d "${TMPDIR:-/tmp}/psql-oauth.XXXXXX")"
pf_err="$tmp/port-forward.err"
kubectl -n "$ns" port-forward "svc/${cluster}-rw" "${port}:5432" >/dev/null 2>"$pf_err" &
pf_pid=$!
cleanup() {
  kill "$pf_pid" 2>/dev/null || true
  rm -rf "$tmp"
  if [[ -n "${container:-}" ]]; then
    docker kill "$container" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

# Wait for the forward to listen (bash's /dev/tcp; the subshell closes the
# probe socket). If kubectl dies first — bad Service name, no kubeconfig —
# surface that instead of spinning.
up=false
for _ in {1..50}; do
  if (exec 3<>"/dev/tcp/127.0.0.1/${port}") 2>/dev/null; then up=true; break; fi
  if ! kill -0 "$pf_pid" 2>/dev/null; then
    echo "port-forward exited — does svc/${cluster}-rw exist in namespace ${ns}?" >&2
    cat "$pf_err" >&2
    exit 1
  fi
  sleep 0.2
done
$up || { echo "port-forward never came up on 127.0.0.1:${port}" >&2; exit 1; }

# Batch mode: the device-flow prompt libpq prints to stderr — "Visit URL and
# enter the code: CODE" — is either unseen (no terminal: it would sit there
# until the code expires, 5 minutes by dex's default) or a copy-paste chore.
# Route the client's stderr through a watcher that replays every line and,
# on that prompt, opens dex's verification page with the code prefilled in
# the local browser: dex's verification_uri_complete is
# verification_uri?user_code=CODE, which libpq receives but never prints.
# Interactive sessions keep stderr on the terminal — through a pipe, psql's
# error messages could land after the next prompt's redraw. The match is
# libpq's English message; under another LC_MESSAGES the line is still
# replayed, just not opened.
open_url() {
  case "$(uname -s)" in
    Darwin) open "$1" ;;
    *) xdg-open "$1" ;;
  esac >/dev/null 2>&1
}
watch_client_stderr() {  # stdin: the client's stderr; fd 8: the real stderr
  local line url opened=false
  while IFS= read -r line || [[ -n "$line" ]]; do
    printf '%s\n' "$line" >&8
    if ! $opened && [[ "$line" =~ ^Visit\ (https://[^[:space:]]+)\ and\ enter\ the\ code:\ ([^[:space:]]+) ]]; then
      opened=true
      url="${BASH_REMATCH[1]}?user_code=${BASH_REMATCH[2]}"
      if open_url "$url"; then
        echo "Opened ${url} in your browser — approve the login there." >&8
      else
        echo "No browser opener found — visit ${url} to approve the login." >&8
      fi
    fi
  done
}
watcher_pid=""
if $batch; then
  exec 8>&2
  err_fifo="$tmp/client.err"
  mkfifo "$err_fifo"
  watch_client_stderr <"$err_fifo" &
  watcher_pid=$!
fi
run_client() {  # backgrounded below: in batch mode hand stderr to the watcher, then become the client
  if $batch; then exec 2>"$err_fifo"; fi
  exec "$@"
}

# The client runs in the background and the script waits on it, so Ctrl-C
# works: psql ignores SIGINT until a session is up (its handler only cancels
# queries, so during the device flow's /token polling the signal is
# swallowed), and bash delivers a signal trap only after the foreground
# child exits — the combination made Ctrl-C appear dead. `wait` IS
# interruptible, and the trap kills the client directly (for --docker, the
# named container — the docker CLI only proxies signals to the process that
# ignores them).
#
# Backgrounding a command in a non-interactive shell also rewires its stdin
# to /dev/null, which breaks both clients — docker -i refuses ("cannot
# attach stdin to a TTY-enabled container") and psql reads EOF — so
# duplicate the script's original stdin (the terminal, or the piped SQL)
# and hand it to the client explicitly.
exec 9<&0
interrupted=false
if $docker; then
  # Docker Desktop (macOS) reaches the host's loopback via
  # host.docker.internal; on Linux the bridge can't see a 127.0.0.1-bound
  # forward, so join the host network and dial loopback directly.
  container="psql-oauth-$$"
  docker_args=(run --rm -i --name "$container")
  # A pty only when there is a terminal to attach it to: docker -t refuses
  # a non-tty stdin, and interactive psql wants one.
  $batch || docker_args+=(-t)
  if [[ "$(uname -s)" == "Darwin" ]]; then
    pg_host="host.docker.internal"
  else
    docker_args+=(--network host)
    pg_host="127.0.0.1"
  fi
  trap 'interrupted=true; docker kill "$container" >/dev/null 2>&1 || true' INT TERM
  # The conninfo and psql's arguments travel as positional parameters of the
  # inner bash ("$@"), not spliced into its script, so their quoting survives.
  run_client docker "${docker_args[@]}" debian:trixie-slim bash -c '
    apt-get update -q >/dev/null &&
    apt-get install -yq postgresql-common ca-certificates >/dev/null 2>&1 &&
    /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh -y >/dev/null &&
    apt-get install -yq postgresql-client-18 libpq-oauth >/dev/null 2>&1 &&
    exec psql "$@"' psql "$(conninfo "$pg_host")" ${psql_args[@]+"${psql_args[@]}"} <&9 &
  client_pid=$!
else
  trap 'interrupted=true; kill "$client_pid" 2>/dev/null || true' INT TERM
  run_client "$psql_bin" "$(conninfo 127.0.0.1)" ${psql_args[@]+"${psql_args[@]}"} <&9 &
  client_pid=$!
fi
rc=0
wait "$client_pid" || rc=$?
# The watcher ends on EOF once the client's stderr closes; wait so its last
# lines land before the script exits.
[[ -z "$watcher_pid" ]] || wait "$watcher_pid" || true
$interrupted && exit 130
if ((rc != 0)) && ! $docker; then
  echo "psql failed (exit ${rc}). If it reported that no OAuth flow is available," >&2
  echo "this psql's libpq lacks the OAuth module — see the header for what ships" >&2
  echo "it, or retry with --docker." >&2
fi
exit "$rc"
