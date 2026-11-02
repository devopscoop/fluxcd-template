#!/bin/sh
# Runs as the DaemonSet's init container on every node: writes one containerd
# hosts.toml per registry in registries.txt, plus one for Harbor's own
# hostname, under /etc/containerd/certs.d (mounted at /host/certs.d). EKS's
# AL2023 containerd config sets registry.config_path to that directory and
# re-reads it on every pull, so nothing restarts.
#
# Each upstream's file lists three places to try, in order — containerd
# moves on to the next when one refuses, errors, or answers 404:
#
#   1. this node's dfdaemon (apps/dragonfly), with the Harbor proxy-cache
#      project as the path and Harbor as the X-Dragonfly-Registry header;
#      dfdaemon forwards to header + path, so layers come peer-to-peer
#   2. Harbor's proxy-cache project directly, for when dfdaemon is down or
#      not deployed
#   3. the upstream registry itself (`server`), for when Harbor is down —
#      including while Harbor's own pods are being pulled
#
# override_path is what lets the host carry the project: containerd then
# uses the host's path as the API root instead of appending /v2. dfinit,
# Dragonfly's own writer, can't express it, which is why this app owns
# certs.d and apps/dragonfly runs with dfinit disabled.
set -eu

certs=/host/certs.d
harbor="https://${HARBOR_HOST}"
dfdaemon=http://127.0.0.1:4001
marker="# Managed by apps/registry-mirrors (its DaemonSet rewrites this on every node) - edit registries.txt there, not this file."
written=/tmp/written
: >"$written"

# write HOST CONTENT — atomically, since containerd may read it mid-pull.
write() {
  mkdir -p "$certs/$1"
  printf '%s\n%s\n' "$marker" "$2" >"$certs/$1/hosts.toml.tmp"
  mv "$certs/$1/hosts.toml.tmp" "$certs/$1/hosts.toml"
  echo "$1" >>"$written"
  echo "wrote $certs/$1/hosts.toml"
}

# Harbor's own images: through dfdaemon, falling back to Harbor itself. No
# path override — these are Harbor's real projects.
write "$HARBOR_HOST" "server = \"$harbor\"

[host.\"$dfdaemon\"]
  capabilities = [\"pull\", \"resolve\"]
  [host.\"$dfdaemon\".header]
    X-Dragonfly-Registry = \"$harbor\""

grep -vE '^[[:space:]]*(#|$)' /config/registries.txt |
  while read -r host server project _type _url; do
    write "$host" "server = \"$server\"

[host.\"$dfdaemon/v2/$project\"]
  capabilities = [\"pull\", \"resolve\"]
  override_path = true
  [host.\"$dfdaemon/v2/$project\".header]
    X-Dragonfly-Registry = \"$harbor\"

[host.\"$harbor/v2/$project\"]
  capabilities = [\"pull\", \"resolve\"]
  override_path = true"
  done

# Drop files this app wrote for registries no longer listed. Files without
# the marker on their first line belong to someone else and are left alone.
for f in "$certs"/*/hosts.toml; do
  [ -f "$f" ] || continue
  [ "$(head -n 1 "$f")" = "$marker" ] || continue
  host=$(basename "$(dirname "$f")")
  if ! grep -qxF "$host" "$written"; then
    rm -f "$f"
    rmdir "$(dirname "$f")" 2>/dev/null || true
    echo "removed $f"
  fi
done
