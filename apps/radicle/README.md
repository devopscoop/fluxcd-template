# radicle

A [Radicle](https://radicle.dev) seed node: `radicle-node` from the Heartwood stack, replicating repos over the Radicle peer-to-peer protocol on TCP 8776. A seed node is what makes a repo reachable when the people who work on it have their laptops closed.

Radicle publishes no Helm chart and no container image — upstream ships Debian packages and systemd units. So this app is the generic `devopscoop/charts/app` chart pointed at a community image (`dirk1980/radicle-seed-node`), which unpacks the signed upstream `radicle-x86_64-unknown-linux-musl` release tarball onto Fedora. The binaries are the ones the Radicle team built and signed; the packaging around them is not. The image is `linux/amd64` only and is only ever tagged `latest`, so values.yaml pins it by digest.

## Before you deploy

The node will not start until you have done step 1. Steps 2 and 3 decide whether it is a *public* seed or just a private mirror.

### 1. Generate the node identity

The Node ID peers dial (`z6Mk…`) is derived from an Ed25519 keypair. It is the node's address on the network — regenerating it moves the node somewhere else, and everyone who had seeded from you has to be told the new ID. Generate it once and treat `node-key.secrets.yaml` as the backup of record.

Run `rad auth` in a throwaway pod built from the same image, so the key comes out of the exact version you are deploying:

```shell
kubectl run radicle-keygen --rm --attach --quiet --restart=Never \
  --image=docker.io/dirk1980/radicle-seed-node@sha256:78ccee526ad4b4f4d7c79c2323b032a7209858a48e1dc9c077272ff1660050e2 \
  --env=RAD_HOME=/tmp/rad --env=RAD_PASSPHRASE= \
  --command -- sh -c 'rad auth --alias radicle.project1-dev.devops.coop >/dev/null 2>&1; cat /tmp/rad/keys/radicle /tmp/rad/keys/radicle.pub'
```

That prints two things back to back: the OpenSSH private key block, then the one-line `ssh-ed25519 …` public key. Paste each into the matching field in `node-key.secrets.yaml.decrypted`, then encrypt it:

```shell
../../encrypt_secrets.sh
```

`RAD_PASSPHRASE=` (empty) produces an unencrypted key, which is what an unattended node needs — otherwise nothing can unlock it at startup. The secret is mounted over `$RAD_HOME/keys`, so it never lands on the PVC.

Both files have to be in the Secret. `radicle-node` only reads the private key, but the `rad` CLI refuses to run without `radicle.pub` next to it, and `rad` is how you administer the node.

### 2. Give it an address peers can reach

The node has no LoadBalancer of its own. Its Service is a ClusterIP, and peers reach it through the shared **eg-public** Gateway, which forwards TCP 8776 to it — a `TCPRoute` (`tcproute.yaml`) attached to a listener of the same name in `apps/eg-custom-resources/gateway-public.yaml`.

Three things have to be true before that path works.

**The Gateway has to actually be public.** `eg-public` ships attached to the *private* EnvoyProxy — the name says what it is for, not where it is. Until you attach the `eg-public` EnvoyProxy stub via `spec.infrastructure.parametersRef` (the snippet is in `envoyproxy-public.yaml`), this node is reachable only from inside the network, and a seed nobody can dial is not seeding anything.

**Something outside the cluster has to route 8776 to the Gateway.** On a cloud cluster the EnvoyProxy's load balancer publishes every listener port, so attaching the public stub is the whole job. On bare metal it is not: MetalLB hands the Gateway a LAN address, and only the ports the site's router forwards to it reach the internet. That forwarding usually exists for 80 and 443 because the first app needed it, and 8776 is a port nobody has opened before — so the Radicle listener is the one that silently stays private.

Nothing in this repo controls that hop, which makes it the failure the Kubernetes objects cannot warn you about: the listener is present, the TCPRoute reports `Accepted`, the Service publishes 8776, the Gateway is `PROGRAMMED=True`, and the node is still undialable. Confirm it from *off* the network rather than from a workstation on the same LAN — the LAN address answers either way:

```shell
# The address to forward TO:
kubectl -n envoy-gateway-system get gateway eg-public

# Run this from somewhere else, against the address forwarded FROM:
timeout 5 bash -c 'exec 3<>/dev/tcp/<public-address>/8776' && echo open || echo blocked
```

**Two files have to agree on one hostname:**

- `config.json` → `node.externalAddresses` — what the node advertises over gossip.
- `tcproute.yaml` → the `external-dns.alpha.kubernetes.io/hostname` annotation — what gets a record pointing at the Gateway's load balancer.

Both ship as `radicle.project1-dev.devops.coop`, and deploy.sh rewrites `project1-dev` to your cluster name. If they disagree, peers get an address that does not resolve to this node and inbound replication silently never happens.

A TCPRoute has no `hostnames` field — a TCP stream carries no hostname to route on — so the record comes from that annotation and the listener is dedicated to this one app. That is also why the listener is named `radicle` rather than something generic: a second TCP service needs its own port and its own listener.

What you hand out to people who want to seed from you is the pair — `rad node status` in the pod prints the Node ID:

```text
<node-id>@radicle.project1-dev.devops.coop:8776
```

One consequence of proxying: `radicle-node` sees connections coming from the Envoy pod, not from the peer. Nothing breaks — Radicle authenticates peers cryptographically by Node ID, not by address — but peer IPs in the node's logs are Envoy's, and per-IP reasoning about traffic has to happen at the Gateway instead.

### 3. List the repos to seed

`config.json` sets `seedingPolicy.default` to `block`, so the node carries nothing it is not told to. Put the repos you want in `seeded-repos.txt`, one Radicle ID per line — that file is the whole list. The 10Gi PVC in `radicle-home-pvc.yaml` is sized for that, not for the network; revisit it as the list grows.

Get an ID with `rad .` inside a working copy, or `rad inspect --rid`.

The alternative is a fully-replicating seed: `{"default": "allow", "scope": "all"}` in `config.json`, which carries every repo announced to the node and grows with the network rather than with your list.

## Bootstrapping onto the network

`config.json` here is a complete file mounted over `$RAD_HOME/config.json`, not a patch on top of what `rad auth` would have written — so anything it omits falls back to the binary's defaults, and `preferredSeeds` does **not** default to the public seeds. It has to be spelled out, and it is:

```json
"preferredSeeds": [
  "z6MkrLMMsiPWUcNPHcRajuMi9mDfYckSoJyPwwnknocNYPm7@iris.radicle.network:8776",
  "z6Mkmqogy2qEM2ummccUthFEaaHvyYmYBYh3dbe9W4ebScxo@rosa.radicle.network:8776"
]
```

Without it the node has no way onto the network. `node.peers` defaults to `dynamic`, which picks peers out of an address book that is itself filled by gossip from peers already connected — so on a fresh volume the node binds its port, dials nobody, and sits there with an empty `rad node routing` forever. `preferredSeeds` (dialed at startup) and `node.connect` (held open permanently) are the only two ways in; a node with both empty can only ever be found, never find.

These are the Radicle core team's permissive seeds, renamed from `seed`/`ash.radicle.garden` in the [2026 move to radicle.network](https://radicle.dev/2026/04/23/domain-move). The Node ID in front of the `@` is checked during the handshake, so a stale pairing fails closed and shows up in the node's log rather than connecting to the wrong peer.

## Checking on it

```shell
kubectl -n radicle exec -it deploy/radicle -- rad node status
kubectl -n radicle exec -it deploy/radicle -- rad self
kubectl -n radicle exec -it deploy/radicle -- rad node routing
```

Peers connect from the outside, so confirm the route was accepted and that the Gateway it hangs off has an address:

```shell
kubectl -n radicle get tcproute radicle -o yaml   # parents[].conditions: Accepted / ResolvedRefs
kubectl -n envoy-gateway-system get gateway eg-public
```

A route that is not `Accepted` usually means the `radicle` listener is missing from the Gateway, or `sectionName` does not match it.

The link-direction column in `rad node status` is what tells you whether step 2 above really landed. Sessions marked `↗` are ones this node opened; `↘` are peers that dialed *it*. A node with healthy outbound sessions and no inbound ones is working as a client of the network but is not yet reachable as a seed — which is exactly what a missing port forward looks like, since outbound replication is unaffected by it.

Inbound sessions only appear after a completed handshake, so a plain `nc` probe proves the port is open without ever showing up there. To prove the rest of the path — that Envoy is really carrying the stream to the pod rather than just accepting and dropping it — read the Gateway's access log while you probe:

```shell
kubectl -n envoy-gateway-system logs -l gateway.envoyproxy.io/owning-gateway-name=eg-public --since=3m | grep 8776
```

Look for `upstream_host` equal to the radicle pod's IP with a null `upstream_transport_failure_reason`. `bytes_received` staying 0 is expected for a probe that never speaks the protocol.

Do not wait on an inbound session as the sign it worked, though. Peers dial you when they want a repo you carry, so your external address has to propagate through gossip first, and a node seeding a short list may go a long time without anyone having a reason to connect. Quiet is not the same as broken.

## Changing which repos are seeded

Edit `seeded-repos.txt`, let Flux sync, then restart:

```shell
kubectl -n radicle rollout restart deployment radicle
```

Which repos a node carries is a per-repo policy in `node/policies.db` on the PVC — `config.json` can only set the default. So the `seed-policies` initContainer reconciles that database against `seeded-repos.txt` on every start: it seeds what is listed and unseeds what is not. That keeps the list reviewable in git and rebuildable after a lost volume, which a database on a volume is not.

Removing a line stops replication; it does not delete what is already on the PVC. Repos are seeded with scope `all`, so every remote is followed and contributors' patches and forks replicate too, not just the delegates' branches.

Changing policies by hand with `rad seed` / `rad unseed` in the pod works, but the next restart reverts it to whatever `seeded-repos.txt` says. To inspect the live state:

```shell
kubectl -n radicle exec -it deploy/radicle -- rad seed
```

## Changing config.json

Same as above: `config.json` shares the ConfigMap with `seeded-repos.txt` and is read once at startup, so an edit reconciles into the cluster without reaching the running node until you restart it.

## Upgrading

The image tracks upstream and is rebuilt whenever Radicle releases, but the digest in values.yaml is what actually pins it, so upgrades are deliberate. It appears **twice** — `image.tag` and the `seed-policies` initContainer, which runs the same image but gets no help from the chart's templating. Bump both. Get the current digest:

```shell
tok=$(curl -s "https://auth.docker.io/token?service=registry.docker.io&scope=repository:dirk1980/radicle-seed-node:pull" | sed 's/.*"token":"\([^"]*\)".*/\1/')
curl -sI -H "Authorization: Bearer $tok" -H "Accept: application/vnd.oci.image.index.v1+json" \
  https://registry-1.docker.io/v2/dirk1980/radicle-seed-node/manifests/latest | grep -i docker-content-digest
```

Check what moved in the [Radicle changelog](https://github.com/radicle-dev/heartwood/blob/master/CHANGELOG.md) before bumping — the node's on-disk databases get migrated in place on first start, and that is not reversible.

## What this does not include

`radicle-httpd`, the HTTP API that the Radicle web explorer talks to, is a separate binary and is not in this image. This app seeds over the p2p protocol only. Browsing your repos in a web UI needs a second app with an image that carries `radicle-httpd`, exposed through an HTTPRoute on one of the Gateways in `apps/eg-custom-resources`.

## If it crashloops

values.yaml runs the node as UID 10000 with `readOnlyRootFilesystem: true`, which the upstream binaries do not need root or a writable root for — everything they write is a mounted volume. If a future version breaks that assumption, `readOnlyRootFilesystem` is the first thing to relax.
