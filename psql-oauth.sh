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
# results come back, whether or not anyone is reading the terminal. Every
# connection is one approval — libpq has no way to hand psql a token
# obtained earlier (only the PQsetAuthDataHook C API) — so batch statements
# into a single invocation rather than one per query:
#
#   ./psql-oauth.sh APP -- -c 'select count(*) from users'
#   ./psql-oauth.sh APP -- -At -c 'select id from users order by 1'
#   ./psql-oauth.sh APP <<'SQL'
#   \dt
#   select ...;
#   SQL
#
# Sessions, for many queries on one approval. `--session start APP` leaves
# the port-forward and a connected psql running in the background; from then
# on every batch run against the same database (same namespace, Cluster,
# database and role) is handed to that psql over a FIFO and returns without
# a browser, until `--session stop APP`. Session requests take SQL through
# -c (repeatable), -f FILE or stdin, plus the output flags -A -t -x -F SEP
# --csv and -v NAME=VALUE; any other psql flag needs a fresh connection, so
# stop the session first. Statements run one at a time with the output
# settings reset per request, as with psql -f, and the exit status is 1 when
# the server reported an error. An interactive run (terminal, no -c/-f)
# always connects afresh. `--session status` (with or without APP) shows
# what is running. A session keeps a database connection and a port-forward
# open until stopped — and the forward pins one pod, so a CNPG switchover
# ends it; the next request notices, says so, and connects afresh.
#
# The APP argument follows this repo's conventions (namespace = APP,
# Cluster = APP-db, database = APP); -n/-c/-d override any of them for
# clusters named differently. Everything after `--` goes to psql verbatim.
#
# The local psql must be 18+ with libpq's OAuth module: Debian/Ubuntu PGDG
# ship it as the libpq-oauth package, Arch includes it in postgresql-libs,
# and on macOS Homebrew's postgresql@18 formula builds it (--with-libcurl;
# the libpq formula does not). postgresql@18 is keg-only, so the script also
# looks for its versioned `psql-18` link.
#
# Usage: ./psql-oauth.sh [-U ROLE] [-p PORT] [-i CLIENT_ID] [--print] APP [-- PSQL_ARGS...]
#        ./psql-oauth.sh [-U ROLE] [-p PORT] [-i CLIENT_ID] [--print] -n NAMESPACE -c CLUSTER -d DBNAME [-- PSQL_ARGS...]
#        ./psql-oauth.sh [-U ROLE] [-p PORT] [-i CLIENT_ID] --session start|stop|status APP
#        ./psql-oauth.sh --session status
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
print_only=false
session=""
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
    --print) print_only=true; shift ;;
    --session)
      case "${2:-}" in start|stop|status) session="$2" ;; *) usage ;; esac
      shift 2 ;;
    -h|--help) usage 0 ;;
    --) shift; psql_args=("$@"); break ;;
    -*) usage ;;
    *) app="$1"; shift ;;
  esac
done

# Session state lives in a per-user runtime directory: one subdirectory per
# database+role holding the FIFO psql reads, its stdout/stderr logs and pids.
session_root="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/psql-oauth-$(id -u)"

session_state() {  # $1: session dir → alive | starting | dead
  local pid
  if pid="$(cat "$1/client.pid" 2>/dev/null)" && [[ -n "$pid" ]]; then
    if kill -0 "$pid" 2>/dev/null; then echo alive; else echo dead; fi
  elif pid="$(cat "$1/starting" 2>/dev/null)" && [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    echo starting
  else
    echo dead
  fi
}
session_describe() {  # $1: session dir → one status line
  echo "$(session_state "$1")  $(cat "$1/info" 2>/dev/null || basename "$1")"
}
session_kill() {  # $1: session dir — stop everything it started and remove it
  local f
  for f in client.pid watcher.pid pf.pid starting; do
    if [[ -s "$1/$f" ]]; then kill "$(cat "$1/$f")" 2>/dev/null || true; fi
  done
  rm -rf "$1"
}

if [[ "$session" == status && -z "$app" && -z "$ns" ]]; then
  shopt -s nullglob
  for d in "$session_root"/*/; do session_describe "${d%/}"; done
  exit 0
fi

[[ -n "$app" || -n "$ns" ]] || usage
ns="${ns:-$app}"
cluster="${cluster:-${app:-$ns}-db}"
db="${db:-${app:-$ns}}"
if [[ -z "$role" ]]; then
  role="$(git config user.email 2>/dev/null | cut -d@ -f1 || true)"
fi
role="${role:-$USER}"
sdir="${session_root}/${ns}_${cluster}_${db}_${role}"

case "$session" in
  status)
    if [[ -d "$sdir" ]]; then session_describe "$sdir"; else echo "no session for ${role}@${cluster}/${db} in ${ns}"; fi
    exit 0 ;;
  stop)
    if [[ -d "$sdir" ]]; then session_kill "$sdir"; echo "session for ${role}@${cluster}/${db} in ${ns} stopped"
    else echo "no session for ${role}@${cluster}/${db} in ${ns}"; fi
    exit 0 ;;
esac

# Batch mode is everything but an interactive psql session: stdin isn't a
# terminal (an agent's shell tool, a pipe, a heredoc), or the psql arguments
# make it run and exit (-c/-f/-l and their long forms, alone or inside a
# short-option cluster like -Atc). Batch runs get the device-flow prompt
# opened in the browser (below), or are answered by a running session; only
# a developer at the psql prompt gets neither.
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
[[ "$session" != start ]] || batch=true

# ---- Session requests -------------------------------------------------------
# The session's psql reads its FIFO forever (it holds the FIFO open
# read-write itself, so writers coming and going never give it an EOF) and
# appends to two logs. A request translates the psql flags it supports into
# per-request \pset state, brackets the SQL with marker lines on stdout
# (\echo) and stderr (\warn), writes the lot to the FIFO under a lock, and
# waits for its end markers; the output between them is this request's.
# \r before the end markers clears a statement left without its semicolon,
# so it can't leak into the next request.
session_unsupported() {
  echo "psql option '$1' isn't available through a session (supported: -c -f -A -t -x -F -v --csv)." >&2
  echo "Stop the session (--session stop) to run psql directly." >&2
  exit 2
}
session_stmt() {  # one -c argument → statement text, terminated as psql -c would
  local s="$1"
  if [[ "$s" == \\* || "$s" =~ \;[[:space:]]*$ ]]; then printf '%s\n' "$s"; else printf '%s\n;\n' "$s"; fi
}
session_abspath() { if [[ "$1" == /* ]]; then printf '%s' "$1"; else printf '%s/%s' "$PWD" "$1"; fi; }
session_lock() {
  local owner waited=0
  until mkdir "$sdir/lock" 2>/dev/null; do
    owner="$(cat "$sdir/lock/pid" 2>/dev/null || true)"
    if [[ -n "$owner" ]] && ! kill -0 "$owner" 2>/dev/null; then rm -rf "$sdir/lock"; continue; fi
    sleep 0.2
    waited=$((waited + 1))
    if ((waited % 150 == 0)); then echo "waiting for another request on this session to finish..." >&2; fi
  done
  echo $$ >"$sdir/lock/pid"
}
session_unlock() { rm -rf "$sdir/lock"; }
session_request() {
  local pre body a opt val id start end out_pos err_pos slice_out slice_err req_out req_err rc
  pre=$'\\set QUIET on\n\\pset format aligned\n\\pset tuples_only off\n\\pset expanded off\n\\pset fieldsep \'|\'\n'
  body=""
  set -- ${psql_args[@]+"${psql_args[@]}"}
  while [[ $# -gt 0 ]]; do
    a="$1"; shift
    case "$a" in
      --csv) pre+=$'\\pset format csv\n' ;;
      --command=*) body+="$(session_stmt "${a#--command=}")"$'\n' ;;
      --command) body+="$(session_stmt "$1")"$'\n'; shift ;;
      --file=*) body+="\\i $(session_abspath "${a#--file=}")"$'\n' ;;
      --file) body+="\\i $(session_abspath "$1")"$'\n'; shift ;;
      --*) session_unsupported "$a" ;;
      -?*)
        opt="${a#-}"
        while [[ -n "$opt" ]]; do
          case "${opt:0:1}" in
            A) pre+=$'\\pset format unaligned\n' ;;
            t) pre+=$'\\pset tuples_only on\n' ;;
            x) pre+=$'\\pset expanded on\n' ;;
            q) ;;
            c|f|F|v)
              val="${opt:1}"
              if [[ -z "$val" ]]; then val="${1:-}"; shift || true; fi
              case "${opt:0:1}" in
                c) body+="$(session_stmt "$val")"$'\n' ;;
                f) if [[ "$val" == "-" ]]; then body+="$(cat)"$'\n'; else body+="\\i $(session_abspath "$val")"$'\n'; fi ;;
                F) pre+="\\pset fieldsep '${val}'"$'\n' ;;
                v) pre+="\\set ${val%%=*} '${val#*=}'"$'\n' ;;
              esac
              opt="" ;;
            *) session_unsupported "-${opt:0:1}" ;;
          esac
          opt="${opt:1}"
        done ;;
      *) session_unsupported "$a" ;;
    esac
  done
  if [[ -z "$body" ]]; then body="$(cat)"$'\n'; fi

  id="$$.${RANDOM}"
  start="__psql_oauth_start_${id}__"
  end="__psql_oauth_end_${id}__"
  session_lock
  trap session_unlock EXIT
  out_pos=$(wc -c <"$sdir/out" | tr -d ' ')
  err_pos=$(wc -c <"$sdir/err" | tr -d ' ')
  # Open the FIFO read-write like psql does: the open never blocks, and a
  # psql that died meanwhile shows up in the loop below rather than as SIGPIPE.
  {
    printf '%s' "$pre"
    printf '\\set QUIET off\n\\echo %s\n\\warn %s\n' "$start" "$start"
    printf '%s' "$body"
    printf '\n\\set QUIET on\n\\r\n\\set QUIET off\n\\echo %s\n\\warn %s\n' "$end" "$end"
  } 1<>"$sdir/in"
  # Ctrl-C cancels the running statement, the way psql's own handler does;
  # the request then completes with the server's cancellation error.
  trap 'kill -INT "$(cat "$sdir/client.pid")" 2>/dev/null || true' INT
  while :; do
    slice_out="$(tail -c +$((out_pos + 1)) "$sdir/out")"
    slice_err="$(tail -c +$((err_pos + 1)) "$sdir/err")"
    if grep -qxF "$end" <<<"$slice_out" && grep -qxF "$end" <<<"$slice_err"; then break; fi
    if [[ "$(session_state "$sdir")" != alive ]]; then
      echo "The session's psql exited mid-request; its last output:" >&2
      tail -n 5 "$sdir/err" >&2
      session_kill "$sdir"
      exit 2
    fi
    sleep 0.1
  done
  req_out="$(awk -v s="$start" -v e="$end" '$0 == e { exit } p { print } $0 == s { p = 1 }' <<<"$slice_out")"
  req_err="$(awk -v s="$start" -v e="$end" '$0 == e { exit } p { print } $0 == s { p = 1 }' <<<"$slice_err")"
  [[ -z "$req_out" ]] || printf '%s\n' "$req_out"
  [[ -z "$req_err" ]] || printf '%s\n' "$req_err" >&2
  rc=0
  if grep -qE '^(psql:.*:[0-9]+: )?(ERROR|FATAL|PANIC):|: No such file or directory$' <<<"$req_err"; then rc=1; fi
  exit "$rc"
}

if [[ -z "$session" ]] && ! $print_only && $batch && [[ -d "$sdir" ]]; then
  case "$(session_state "$sdir")" in
    alive) session_request ;;
    starting) echo "A session for ${role}@${cluster}/${db} is still starting (approve its login, or wait); retry shortly." >&2; exit 2 ;;
    dead)
      echo "The session for ${role}@${cluster}/${db} in ${ns} has ended; its last output:" >&2
      tail -n 3 "$sdir/err" 2>/dev/null >&2 || true
      echo "Cleaning it up and connecting afresh." >&2
      session_kill "$sdir" ;;
  esac
fi

# ---- Fresh connection -------------------------------------------------------

# The issuer lives in the Cluster's oauth pg_hba rule — the manifest is the
# single source of truth, and it must match dex's config.issuer byte-for-byte
# anyway (see the pg-oauth block's comments).
hba="$(kubectl -n "$ns" get clusters.postgresql.cnpg.io "$cluster" \
  -o jsonpath='{range .spec.postgresql.pg_hba[*]}{@}{"\n"}{end}')"
issuer="$(grep -om1 'issuer="[^"]*"' <<<"$hba" | cut -d'"' -f2 || true)"

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

# Prefer the versioned psql-18 that Homebrew's keg-only postgresql@18 puts on
# PATH over a possibly-older plain psql; either must be 18+ with libpq's OAuth
# module (see the header), and psql says so itself if it isn't.
psql_bin=psql-18
command -v psql-18 >/dev/null || psql_bin=psql

# Scratch space: a throwaway directory for a plain run, the session
# directory for --session start (whose contents must outlive this process).
# A starting session ignores SIGHUP — everything it spawns inherits that, so
# the port-forward, psql and the stderr watcher survive the terminal closing.
if [[ "$session" == start ]]; then
  if [[ -d "$sdir" ]]; then
    case "$(session_state "$sdir")" in
      alive) echo "already running: $(session_describe "$sdir")"; exit 0 ;;
      starting) echo "already starting: $(session_describe "$sdir")" >&2; exit 2 ;;
      dead) session_kill "$sdir" ;;
    esac
  fi
  mkdir -p "$session_root" && chmod 700 "$session_root"
  mkdir -m 700 "$sdir"
  echo $$ >"$sdir/starting"
  trap '' HUP
  tmp="$sdir"
else
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/psql-oauth.XXXXXX")"
fi

# kubectl's stderr goes to a temp file, not the terminal: on every exit the
# torn-down client connection makes port-forward print "connection reset by
# peer ... lost connection to pod", which is pure teardown noise — but the
# same stream carries the real reason when the forward fails to start, so
# the failure branch below replays it.
pf_err="$tmp/port-forward.err"
kubectl -n "$ns" port-forward "svc/${cluster}-rw" "${port}:5432" </dev/null >/dev/null 2>"$pf_err" &
pf_pid=$!
persist=false
cleanup() {
  $persist && return 0
  kill "$pf_pid" 2>/dev/null || true
  if [[ -n "${client_pid:-}" ]]; then kill "$client_pid" 2>/dev/null || true; fi
  rm -rf "$tmp"
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
# replayed, just not opened. The watcher replays to fd 8: the real stderr
# for a plain run, the session's stderr log for --session start.
open_url() {
  case "$(uname -s)" in
    Darwin) open "$1" ;;
    *) xdg-open "$1" ;;
  esac >/dev/null 2>&1
}
watch_client_stderr() {  # stdin: the client's stderr; fd 8: where it is replayed
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
  err_fifo="$tmp/client.err"
  mkfifo "$err_fifo"
  if [[ "$session" == start ]]; then
    : >"$sdir/out" >"$sdir/err"
    exec 8>>"$sdir/err"
    watch_client_stderr <"$err_fifo" >/dev/null 2>>"$sdir/err" &
  else
    exec 8>&2
    watch_client_stderr <"$err_fifo" >/dev/null &
  fi
  watcher_pid=$!
fi
run_client() {  # backgrounded below: wire this client's stdio, then become it
  if [[ "$session" == start ]]; then
    # Read-write on the FIFO: psql's own descriptor keeps a writer around, so
    # requests opening and closing the other end never deliver an EOF.
    exec 0<>"$sdir/in" >>"$sdir/out" 9<&-
  else
    exec <&9
  fi
  if $batch; then exec 2>"$err_fifo"; fi
  exec "$@"
}

# The client runs in the background and the script waits on it, so Ctrl-C
# works: psql ignores SIGINT until a session is up (its handler only cancels
# queries, so during the device flow's /token polling the signal is
# swallowed), and bash delivers a signal trap only after the foreground
# child exits — the combination made Ctrl-C appear dead. `wait` IS
# interruptible, and the trap kills the client directly.
#
# Backgrounding a command in a non-interactive shell also rewires its stdin
# to /dev/null, which makes psql read EOF — so duplicate the script's
# original stdin (the terminal, or the piped SQL) and hand it to the client
# explicitly.
exec 9<&0
[[ "$session" != start ]] || mkfifo "$sdir/in"
interrupted=false
trap 'interrupted=true; kill "$client_pid" 2>/dev/null || true' INT TERM
run_client "$psql_bin" "$(conninfo 127.0.0.1)" ${psql_args[@]+"${psql_args[@]}"} &
client_pid=$!

if [[ "$session" == start ]]; then
  echo "$pf_pid" >"$sdir/pf.pid"
  echo "$watcher_pid" >"$sdir/watcher.pid"
  echo "$client_pid" >"$sdir/client.pid"
  printf 'ns=%s cluster=%s db=%s role=%s port=%s started=%s\n' \
    "$ns" "$cluster" "$db" "$role" "$port" "$(date '+%Y-%m-%d %H:%M:%S')" >"$sdir/info"
  # The first line psql prints proves the connection — and the device flow
  # behind it — is up. Meanwhile relay the session's stderr, where the device
  # prompt and the browser notice land, to ours (the watcher writes whole
  # lines, so what has arrived is printable as is).
  printf '\\echo __psql_oauth_ready__\n' 1<>"$sdir/in"
  # Stream new bytes of the session's stderr log to ours. Measure the size
  # first and then read exactly that many bytes: a naive "read new, then
  # re-measure to advance" drops whatever the watcher appends between the two
  # steps (it gets counted but never printed) — which silently swallowed
  # psql's connection error on a fast failure.
  shown=0
  relay_err() {
    local size
    size=$(wc -c <"$sdir/err" | tr -d ' ')
    if ((size > shown)); then
      tail -c +$((shown + 1)) "$sdir/err" | head -c $((size - shown)) >&2
      shown=$size
    fi
  }
  deadline=$((SECONDS + 600))
  until grep -qxF '__psql_oauth_ready__' "$sdir/out"; do
    relay_err
    if ! kill -0 "$client_pid" 2>/dev/null; then
      wait "$watcher_pid" || true
      relay_err
      echo "psql exited before the session was up." >&2
      exit 1
    fi
    if ((SECONDS > deadline)); then echo "Gave up waiting for the login." >&2; exit 1; fi
    sleep 0.2
  done
  relay_err
  rm -f "$sdir/starting"
  persist=true
  stop_hint="$0 --session stop -U ${role}"
  if [[ -n "$app" ]]; then stop_hint+=" ${app}"; else stop_hint+=" -n ${ns} -c ${cluster} -d ${db}"; fi
  echo "Session up: ${role}@${cluster}/${db} in ${ns} (port-forward on 127.0.0.1:${port})."
  echo "Batch runs against it now skip the browser; stop it with:"
  echo "  ${stop_hint}"
  exit 0
fi

rc=0
wait "$client_pid" || rc=$?
# The watcher ends on EOF once the client's stderr closes; wait so its last
# lines land before the script exits.
[[ -z "$watcher_pid" ]] || wait "$watcher_pid" || true
$interrupted && exit 130
exit "$rc"
