#!/bin/sh
# Runs as the harbor-proxy-cache Job: for every upstream in registries.txt,
# creates (or updates) a Harbor registry endpoint and creates a public
# proxy-cache project pointing at it. Idempotent — Flux recreates the Job
# whenever this script or registries.txt changes, and a rerun converges
# without touching what's already right.
#
# Talks to harbor-core's in-cluster Service as Harbor's built-in admin,
# whose password comes from the chart's harbor-core Secret. That Secret holds
# the INITIAL password (harborAdminPassword in apps/harbor's
# helm_secrets.yaml), so after rotating admin's password in the UI, update
# it there too or this Job fails with 401.
#
# Existing endpoints and projects are otherwise left as they are: changing
# an endpoint's URL, or removing a registry from the list, is a manual step
# in the UI (Administration → Registries, Projects).
set -eu

api=http://harbor-core.harbor.svc.cluster.local/api/v2.0

h() {
  curl -sS --fail-with-body -u "admin:${HARBOR_ADMIN_PASSWORD}" \
    -H 'Content-Type: application/json' "$@"
}

# The flux Kustomization dependsOn harbor, but harbor-core can still be
# restarting (an upgrade, a node replacement). Give it ten minutes.
i=0
until curl -sf -o /dev/null "$api/ping"; do
  i=$((i + 1))
  if [ "$i" -gt 60 ]; then
    echo "harbor-core did not answer $api/ping within 10m" >&2
    exit 1
  fi
  sleep 10
done

grep -vE '^[[:space:]]*(#|$)' /config/registries.txt |
  while read -r _host _server project type url; do
    # Docker Hub rate-limits anonymous pulls per source IP, and every pull
    # Harbor makes comes from the cluster's egress addresses — authenticate
    # when the optional credentials Secret has them. The token goes into
    # JSON unescaped: Docker Hub tokens are letters, digits, '-', and '_'.
    user="" token=""
    if [ "$type" = docker-hub ]; then
      user=${DOCKERHUB_USERNAME:-}
      token=${DOCKERHUB_TOKEN:-}
    fi

    id=$(h "$api/registries?q=name%3D$project" | grep -o '"id":[0-9]*' | head -n 1 | cut -d: -f2)
    if [ -z "$id" ]; then
      if [ -n "$user" ]; then
        cred=",\"credential\":{\"type\":\"basic\",\"access_key\":\"$user\",\"access_secret\":\"$token\"}"
      else
        cred=""
      fi
      h -X POST "$api/registries" \
        -d "{\"name\":\"$project\",\"type\":\"$type\",\"url\":\"$url\",\"insecure\":false$cred}" >/dev/null
      id=$(h "$api/registries?q=name%3D$project" | grep -o '"id":[0-9]*' | head -n 1 | cut -d: -f2)
      echo "created registry endpoint $project ($type $url) as id $id"
    elif [ -n "$user" ]; then
      # Re-apply the credentials on every run. A token rotated in the Secret
      # alone doesn't change the Job's spec, so Flux won't rerun it: delete
      # the Job (kubectl -n harbor delete job harbor-proxy-cache) and Flux
      # recreates it on its next reconcile.
      h -X PUT "$api/registries/$id" \
        -d "{\"credential_type\":\"basic\",\"access_key\":\"$user\",\"access_secret\":\"$token\"}" >/dev/null
      echo "updated credentials on registry endpoint $project (id $id)"
    else
      echo "registry endpoint $project exists (id $id)"
    fi

    status=$(curl -s -o /dev/null -w '%{http_code}' -I -u "admin:${HARBOR_ADMIN_PASSWORD}" \
      "$api/projects?project_name=$project")
    if [ "$status" = 200 ]; then
      echo "project $project exists"
    else
      # Public: nodes pull anonymously (apps/harbor/README.md → "Pushing and
      # pulling"), and everything here is public upstream anyway. Harbor
      # attaches a retention policy to every new proxy-cache project that
      # deletes images not pulled for 7 days.
      h -X POST "$api/projects" \
        -d "{\"project_name\":\"$project\",\"registry_id\":$id,\"metadata\":{\"public\":\"true\"},\"storage_limit\":-1}" >/dev/null
      echo "created proxy-cache project $project -> registry endpoint $id"
    fi
  done
