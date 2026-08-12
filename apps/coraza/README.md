# Coraza WAF

[OWASP Coraza](https://coraza.io/) (Apache-2.0) running the [OWASP Core Rule Set](https://coreruleset.org/) v4, deployed as a [proxy-wasm filter](https://github.com/corazawaf/coraza-proxy-wasm) inside the Envoy data plane via Envoy Gateway `EnvoyExtensionPolicy` resources. It inspects every request flowing through the attached Gateways for common web attacks (SQL injection, XSS, RCE, protocol abuse, scanners, ...).

Why this one:

- It runs **inside the existing Envoy data plane** — no sidecars, no second ingress stack, no extra network hop, nothing new to scale or make highly available.
- Coraza is the actively-maintained OWASP successor to ModSecurity (which is in maintenance mode), speaks the same SecLang rule language, and embeds the industry-standard CRS in the wasm image.
- Everything is free and open source: Apache-2.0 engine, Apache-2.0 CRS.

## Coverage

Two policies, so the public Gateway can enforce while the private one stays in observation:

| Policy | File | Gateway | Mode | `failOpen` |
|---|---|---|---|---|
| `coraza-public` | `envoyextensionpolicy-public.yaml` | `eg-public` | `SecRuleEngine On` — matches get a **403** | `false` (fail closed) |
| `coraza-private` | `envoyextensionpolicy-private.yaml` | `eg-private` | `SecRuleEngine DetectionOnly` — matches are **logged only** | `true` (fail open) |

`eg-private` fronts the supporting/ops services (grafana, prometheus, ...), which never ride an internet-facing LB, so its policy is defense-in-depth and starts in DetectionOnly — those apps are the most false-positive-prone. Validate against the logs, tune, then promote to enforcing per host if desired.

## Enabling

Requires `eg` and `eg-custom-resources` (the flux Kustomization has a `dependsOn` on the latter). Enable it the same way as any other app:

```bash
yq -i '.resources = (.resources + ["coraza.yaml"] | unique)' flux/flux-system/kustomization.yaml
```

Verify it attached (`Accepted: True`):

```bash
kubectl -n envoy-gateway-system get envoyextensionpolicy coraza-public -o yaml
```

Then confirm it blocks. With something routable through the gateway:

```bash
curl -i "http://your-host/anything?q=%3Cscript%3Ealert(1)%3C%2Fscript%3E"   # expect HTTP 403
```

## Tuning false positives

CRS at the default paranoia level 1 is deliberately conservative, but apps that PUT/POST unusual payloads (Grafana dashboards, Nexus uploads, ...) can still trip it. When something breaks behind the WAF:

1. Switch `SecRuleEngine On` to `SecRuleEngine DetectionOnly` in `envoyextensionpolicy-public.yaml` (log-only, nothing blocked).
2. Reproduce, and find the rule IDs that fired in the Envoy proxy pod logs:

   ```bash
   kubectl -n envoy-gateway-system logs deploy/$(kubectl -n envoy-gateway-system get deploy -l gateway.envoyproxy.io/owning-gateway-name=eg-public -o name | cut -d/ -f2) | grep -o 'id "[0-9]*"' | sort | uniq -c
   ```

3. Add targeted exclusions to the `default` directives list, after the CRS include, e.g.:

   ```yaml
   - SecRuleRemoveById 942100
   ```

4. Switch back to `SecRuleEngine On`.

## Per-host rule sets

To give a host its own directives (e.g. log-only for one troublesome app while everything else blocks), add a second entry to `directives_map` and map the `:authority` to it:

```yaml
config:
  directives_map:
    default: [...]
    log-only:
      - Include @recommended-conf
      - Include @crs-setup-conf
      - Include @owasp_crs/*.conf
  default_directives: default
  per_authority_directives:
    grafana.example.com: log-only
```

## Notes

- Response body inspection is off (`SecResponseBodyAccess Off`). Inspecting responses makes the filter buffer every text/html body whole, and Envoy resets any stream whose body exceeds the listener's per-connection buffer limit (32KiB by default) — after the response headers have already been sent, so browsers report a dropped or insecure connection instead of an error page (this silently broke Grafana's authenticated pages). Only the CRS response-leakage rules (RESPONSE-95x) depend on it; request inspection is unaffected. To re-enable it, raise the buffer with a `ClientTrafficPolicy` `connection.bufferLimit` ≥ `SecResponseBodyLimit` first.
- CRS rule `920350` ("Host header is a numeric IP address") is dropped for the `/healthz` path via a `ctl:ruleRemoveById` exclusion. Load balancers health-check the Envoy fleets by IP, so every probe carries a numeric-IP Host header and would otherwise log a 920350 warning on each check — high volume, no signal. The exclusion is scoped to `/healthz`, so the rule still fires on real traffic. It is placed before the `@owasp_crs` include because 920350 is a phase-1 rule and `ctl:ruleRemoveById` only affects rules evaluated later in the same phase.
- The wasm image pins CRS: coraza-proxy-wasm 0.6.0 ships Coraza v3.3.3 + CRS v4.14.0. Upgrading the WAF or the rules = bumping the image tag.
- `failOpen` differs by policy on purpose. The enforcing public policy uses `failOpen: false` (the default): a broken/unfetchable wasm module fails closed (500s) rather than serve unfiltered traffic. The DetectionOnly private policy uses `failOpen: true`: since it never blocks anyway, a wasm failure must not take down the ops UIs — it fails open and passes traffic.
- This filters north-south traffic at the gateway only. In-cluster (east-west) traffic and any Service exposed via LoadBalancer/NodePort outside the gateway are not covered.
