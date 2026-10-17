# acme-dns

Self-hosted, provider-agnostic DNS-01 for cert-manager. It serves one delegated
subdomain and nothing else: the `_acme-challenge` TXT records Let's Encrypt reads
during validation.

**Opt-in.** Enable it only if you pick the `dns01.acmeDNS` solver in
`apps/cert-manager-custom-resources/clusterissuer.yaml`. It is not in
`deploy.sh`'s `core_app_list` — add `acme-dns.yaml` to
`flux/flux-system/kustomization.yaml` by hand.

## When to reach for this

This repo's Gateways request wildcard certificates
(`apps/eg-custom-resources/gateway-private.yaml`, `gateway-public.yaml`), and
**wildcards can only be issued over DNS-01** — HTTP-01 cannot do them at all. So
some DNS-01 solver is mandatory, not optional.

Prefer Cloudflare or Route53 if your zone is already there; they are fewer moving
parts. Reach for acme-dns when:

- the zone lives somewhere with no cert-manager solver, or
- handing cert-manager zone-wide DNS API credentials is unacceptable. An acme-dns
  credential can only write one delegated label, so a leak costs you one
  challenge record rather than your zone, or
- some hostnames resolve to addresses Let's Encrypt cannot reach (anything behind
  a private LoadBalancer), which rules out HTTP-01 regardless of wildcards.

## The one real cost: inbound UDP/53

acme-dns is a nameserver. Let's Encrypt's resolvers query it **directly**, so it
needs inbound UDP/53 (and TCP/53, for truncated responses) from the public
internet. On a cloud load balancer that is routine. Behind a NAT it needs a
forward, and some ISPs filter inbound 53.

**Measure it before committing.** Do not assume either way — it has been
confirmed working through a residential NAT, and it has also been the thing that
made this solver a non-starter elsewhere. Test with a throwaway delegation, which
exercises the same path Let's Encrypt uses:

1. Run any DNS server on the address you intend to expose, answering for a
   throwaway name.
2. Publish two records in the parent zone:

   ```dns
   test-ns.example.com.    A    <your public address>
   dnstest.example.com.    NS   test-ns.example.com.
   ```

3. Ask a public resolver — it cannot answer from cache, so it must query you:

   ```shell
   curl -s 'https://dns.google/resolve?name=canary.dnstest.example.com&type=TXT' | jq .
   ```

4. Check your server's log for the **source IP**. A resolver's address (Google,
   Cloudflare) means inbound 53 works. `SERVFAIL` with nothing in the log means
   it is being dropped upstream and no configuration will fix it.

Two traps that make this test lie:

- **Querying your own public address from inside the LAN.** The router hairpins
  and the source IP shows as the router's LAN address; the packet never touches
  your ISV path. Meaningless as a test.
- **A VPN on the test machine.** Many block outbound port 53 as DNS-leak
  protection, so the query fails locally and never leaves. Use a public resolver
  over HTTPS instead, as above.

## Delegation shape

Two records in the parent zone:

```dns
acme-ns.project1-dev.devops.coop.   A    198.51.100.1
auth.project1-dev.devops.coop.      NS   acme-ns.project1-dev.devops.coop.
```

Replace `198.51.100.1` with the public address that reaches `service-dns.yaml`.

The NS target deliberately sits **outside** the delegated zone, so it resolves
from the parent normally and needs no glue record. Upstream's example uses an
in-bailiwick `ns1.auth.example.org`, which does.

Then one CNAME per validated domain:

```dns
_acme-challenge.project1-dev.devops.coop.  CNAME  <subdomain>.auth.project1-dev.devops.coop.
```

A wildcard is validated at its **base** domain, so `*.project1-dev.devops.coop`
uses `_acme-challenge.project1-dev.devops.coop` — not
`_acme-challenge.*.project1-dev.devops.coop`.

## Setup

Gated steps. Do not proceed past a failing gate; everything downstream depends on
it.

### 1. Publish the delegation

The two records above. Independent of the cluster, so do it first and let it
propagate.

```shell
curl -s 'https://dns.google/resolve?name=auth.project1-dev.devops.coop&type=NS' | jq '.Answer'
```

### 2. Deploy

Add `acme-dns.yaml` to `flux/flux-system/kustomization.yaml`, and set the
LoadBalancer address in `service-dns.yaml` (see its TODO — on MetalLB this needs
a third address in `apps/metallb-custom-resources/ipaddresspools.yaml`, since the
two there are consumed by the Envoy fleets).

Confirm it answers **from outside**, not merely that the pod runs:

```shell
kubectl -n acme-dns get pod,svc
curl -s 'https://dns.google/resolve?name=auth.project1-dev.devops.coop&type=SOA' | jq '.Status, .Comment'
```

The `Comment` should name your public address. That is the whole delegation path
proving itself.

### 3. Register

The API is ClusterIP-only, so port-forward to it:

```shell
kubectl -n acme-dns port-forward svc/acme-dns-api 8080:8080
curl -s -X POST http://localhost:8080/register | jq .
```

Keep the JSON: `username`, `password`, `fulldomain`, `subdomain`.

### 4. Publish the CNAME

Only possible now — it needs `subdomain` from step 3.

### 5. Install the account secret and enable the solver

Create `apps/cert-manager-custom-resources/acme-dns-account.secrets.yaml`, keyed
by the domain being **validated**:

```json
{
  "project1-dev.devops.coop": {
    "username": "...",
    "password": "...",
    "fulldomain": "....auth.project1-dev.devops.coop",
    "subdomain": "...",
    "allowfrom": []
  }
}
```

Stage it as `acme-dns-account.secrets.yaml.decrypted`, run
`./encrypt_secrets.sh`, then add it to that directory's `kustomization.yaml` and
uncomment the `dns01.acmeDNS` solver in `clusterissuer.yaml`.

**Commit the secret and its `resources` entry together** — see the deadlock
below.

```shell
kubectl get clusterissuer letsencrypt \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}{"\n"}'
kubectl get certificate -A
```

## Adding a certificate later

Every validated domain needs its own account entry and its own CNAME. **Prefer
the wildcard the Gateways already request** — point a listener's
`certificateRefs` at the existing wildcard Secret and no new registration is
needed.

Register separately only when the wildcard genuinely cannot cover the name; it
matches exactly one label, so neither the apex nor `a.b.project1-dev.devops.coop`
is included. When you must, register afresh rather than copying an existing
credential: acme-dns stores at most 2 TXT values per credential, so three or more
certificates renewing concurrently through one credential clobber each other's
challenges.

## Troubleshooting

### The two-commit deadlock

Adding the account secret in one commit and uncommenting it in
`kustomization.yaml` in a **later** commit can wedge
`cert-manager-custom-resources` permanently.

The ClusterIssuer references a secret the earlier revision does not create, so it
reports `Ready=False InvalidSolver: failed to get secret`. With `wait: true`,
Flux burns its full health-check timeout, the reconcile never completes, and it
therefore never advances to the commit that would create the secret. The fix sits
in a revision Flux cannot reach.

Symptom — `lastAttemptedRevision` stuck behind the GitRepository:

```shell
kubectl get kustomization -n flux-system cert-manager-custom-resources \
  -o jsonpath='{.status.lastAttemptedRevision}{"\n"}{.status.lastAppliedRevision}{"\n"}'
kubectl get gitrepository -n flux-system flux-system -o jsonpath='{.status.artifact.revision}{"\n"}'
```

Fix:

```shell
flux reconcile kustomization cert-manager-custom-resources -n flux-system --with-source
```

### encrypt_secrets.sh reaches into worktrees

`encrypt_secrets.sh` runs `find` from the repo root, and git worktrees under
`.claude/worktrees/` are inside that tree. A stale `*.yaml.decrypted` left in a
worktree gets encrypted by a run launched from the main checkout, producing a
second `*.secrets.yaml` that looks legitimate but may hold placeholder values.
Delete stale `.decrypted` files in worktrees first, and check `git status`
afterwards.

### Challenge stuck pending

Verify the chain from outside, in order — the first failing link is the problem:

```shell
curl -s 'https://dns.google/resolve?name=auth.project1-dev.devops.coop&type=NS' | jq '.Answer'
curl -s 'https://dns.google/resolve?name=_acme-challenge.project1-dev.devops.coop&type=TXT' | jq '.Answer, .Comment'
kubectl describe challenge -A
kubectl logs -n acme-dns -l app=acme-dns --tail=50
```

A correct TXT answer returns two records — the CNAME, then the TXT from
`<subdomain>.auth...` — with a `Comment` naming your public address.

## Operational notes

- **Pin the LoadBalancer address.** A router forward or firewall rule points at
  it; letting MetalLB reassign silently breaks every renewal.
- **Single replica, `Recreate` strategy.** SQLite on a ReadWriteOnce volume; two
  pods cannot hold it at once, so a rolling update would deadlock.
- **Do not lose the PVC.** Each row ties a credential to the subdomain a CNAME
  points at. Losing it means re-registering and re-pointing every CNAME. The
  namespace carries `kustomize.toolkit.fluxcd.io/prune: disabled` for this
  reason.
- **The NS A record is the fragile part.** If that address is dynamic and
  changes, renewals fail silently until expiry. `CertManagerCertNotReady` in
  `apps/victoria-metrics-custom-resources/cert-manager-vmrule.yaml` is the
  backstop; pair it with a dynamic-DNS updater if the address is not static.
- **Config format.** acme-dns v2 uses `engine = "sqlite"` (not `sqlite3`) and
  `port` under `[api]` is a *string*. The v1 examples still in circulation are
  wrong on both.
- **Exposure.** It answers only its own small zone and does no recursion, so it
  is a poor amplification target — but it is a public DNS server. Consider rate
  limiting if that matters in your environment.
- **Platform bits** live in `service-dns.yaml` marker blocks: the `eks` block
  carries the NLB annotations, and the MetalLB address pin is a plain TODO
  because it is inherently cluster-specific.
