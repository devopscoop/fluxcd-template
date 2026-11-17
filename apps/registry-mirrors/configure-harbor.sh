#!/bin/sh
# Runs as the harbor-proxy-cache Job: for every upstream in registries.txt,
# creates (or updates) a Harbor registry endpoint and creates a proxy-cache
# project pointing at it. Then it creates (or updates) robot$registry-mirrors,
# the system robot account every node pulls through those projects as
# (write-hosts.sh), with pull on each of them and the password from
# node-robot-harbor.secrets.yaml. Idempotent — Flux recreates the Job
# whenever this script or registries.txt changes, and a rerun converges
# without touching what's already right.
#
# The projects are public, except the account's private ECR (type aws-ecr),
# which only the robot can pull from: nodes, and nothing else that can
# reach eg-private.
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

# Checked up front, since Harbor's own error would end up in /dev/null below.
# Harbor wants 8 to 128 characters with a lower-case letter, an upper-case
# letter, and a digit (IsValidSec); letters and digits only is this script's
# rule, because the password goes into JSON unescaped.
if [ "${ROBOT_PASSWORD:-CHANGEME}" = CHANGEME ]; then
  echo "no node robot password in node-robot-harbor.secrets.yaml: see README.md → First run" >&2
  exit 1
fi
for re in '^[A-Za-z0-9]{8,128}$' '[a-z]' '[A-Z]' '[0-9]'; do
  if ! printf '%s\n' "$ROBOT_PASSWORD" | grep -qE "$re"; then
    echo "the node robot password needs 8 to 128 letters and digits, with a lower-case letter, an upper-case letter, and a digit" >&2
    exit 1
  fi
done

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
      elif [ "$type" = aws-ecr ]; then
        # No keys: Harbor's aws-ecr adapter then uses the AWS SDK's default
        # credential chain, which finds harbor-core's IRSA role (apps/harbor's
        # ecr-proxy block). The empty credential must still be sent: on
        # create, Harbor hands the endpoint straight to that adapter, which
        # reads the credential without a nil check.
        cred=",\"credential\":{\"type\":\"basic\",\"access_key\":\"\",\"access_secret\":\"\"}"
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

    # Public: everything on a public upstream is public anyway, and anything
    # that reaches eg-private can pull it without a robot (apps/harbor/
    # README.md → "Pushing and pulling"). The account's private ECR is the
    # exception: private, so only the node robot pulls from it. That one is
    # also enforced on existing projects, which earlier versions of this
    # script created public.
    public=true
    if [ "$type" = aws-ecr ]; then
      public=false
    fi

    status=$(curl -s -o /dev/null -w '%{http_code}' -I -u "admin:${HARBOR_ADMIN_PASSWORD}" \
      "$api/projects?project_name=$project")
    if [ "$status" != 200 ]; then
      # Harbor attaches a retention policy to every new proxy-cache project
      # that deletes images not pulled for 7 days.
      h -X POST "$api/projects" \
        -d "{\"project_name\":\"$project\",\"registry_id\":$id,\"metadata\":{\"public\":\"$public\"},\"storage_limit\":-1}" >/dev/null
      echo "created proxy-cache project $project (public: $public) -> registry endpoint $id"
    elif [ "$public" = false ]; then
      h -X PUT -H 'X-Is-Resource-Name: true' "$api/projects/$project" \
        -d '{"metadata":{"public":"false"}}' >/dev/null
      echo "project $project exists, private"
    else
      echo "project $project exists"
    fi
  done

# The node robot: a system-level robot with pull on every proxy-cache
# project, never expiring. Harbor stores the name bare and shows it with its
# robot name prefix (robot_name_prefix, default robot$): a create takes the
# bare name, an update the prefixed one, and write-hosts.sh sends
# robot$registry-mirrors, so a changed prefix stops the Job below.
perms=$(grep -vE '^[[:space:]]*(#|$)' /config/registries.txt |
  while read -r _host _server project _type _url; do
    printf '{"kind":"project","namespace":"%s","access":[{"resource":"repository","action":"pull"}]},' "$project"
  done)
# robot NAME: the request body. An update replaces the description, the
# disable flag, and the permissions, so it always sends all three.
robot() {
  printf '{"name":"%s","description":"Node pulls through the proxy-cache projects (apps/registry-mirrors)","level":"system","duration":-1,"disable":false,"permissions":[%s]}' \
    "$1" "${perms%,}"
}

rid=$(h "$api/robots?q=name%3Dregistry-mirrors" | grep -o '"id":[0-9]*' | head -n 1 | cut -d: -f2)
if [ -z "$rid" ]; then
  created=$(h -X POST "$api/robots" -d "$(robot registry-mirrors)")
  rid=$(echo "$created" | grep -o '"id":[0-9]*' | head -n 1 | cut -d: -f2)
  echo "created robot registry-mirrors (id $rid)"
fi
name=$(h "$api/robots/$rid" | grep -o '"name":"[^"]*"' | head -n 1 | cut -d'"' -f4)
if [ "$name" != 'robot$registry-mirrors' ]; then
  echo "robot $rid is named '$name', but write-hosts.sh sends robot\$registry-mirrors: was Harbor's robot name prefix changed?" >&2
  exit 1
fi
# Both re-applied on every run: the permissions follow registries.txt, and
# the password replaces the random one Harbor generates on create with the
# copy the nodes have.
h -X PUT "$api/robots/$rid" -d "$(robot "$name")" >/dev/null
h -X PATCH "$api/robots/$rid" -d "{\"secret\":\"$ROBOT_PASSWORD\"}" >/dev/null
echo "set $name's permissions and password (robot id $rid)"
