# Coraza WAF

[OWASP Coraza](https://coraza.io/) (Apache-2.0) running the [OWASP Core Rule Set](https://coreruleset.org/) v4, deployed as a [proxy-wasm filter](https://github.com/corazawaf/coraza-proxy-wasm) on the `eg` Gateway via an Envoy Gateway `EnvoyExtensionPolicy`. It inspects every request flowing through every HTTPRoute on the gateway and blocks common web attacks (SQL injection, XSS, RCE, protocol abuse, scanners, ...) with a 403.

Why this one:

- It runs **inside the existing Envoy data plane** — no sidecars, no second ingress stack, no extra network hop, nothing new to scale or make highly available.
- Coraza is the actively-maintained OWASP successor to ModSecurity (which is in maintenance mode), speaks the same SecLang rule language, and embeds the industry-standard CRS in the wasm image.
- Everything is free and open source: Apache-2.0 engine, Apache-2.0 CRS.

## Enabling

Requires `eg` and `eg-custom-resources` (the flux Kustomization has a `dependsOn` on the latter). Enable it the same way as any other app:

```bash
yq -i '.resources = (.resources + ["coraza.yaml"] | unique)' flux/flux-system/kustomization.yaml
```

Verify it attached (`Accepted: True`):

```bash
kubectl -n envoy-gateway-system get envoyextensionpolicy coraza -o yaml
```

Then confirm it blocks. With something routable through the gateway:

```bash
curl -i "http://your-host/anything?q=%3Cscript%3Ealert(1)%3C%2Fscript%3E"   # expect HTTP 403
```

## Tuning false positives

CRS at the default paranoia level 1 is deliberately conservative, but apps that PUT/POST unusual payloads (Grafana dashboards, Nexus uploads, ...) can still trip it. When something breaks behind the WAF:

1. Switch `SecRuleEngine On` to `SecRuleEngine DetectionOnly` in `envoyextensionpolicy.yaml` (log-only, nothing blocked).
2. Reproduce, and find the rule IDs that fired in the Envoy proxy pod logs:

   ```bash
   kubectl -n envoy-gateway-system logs deploy/$(kubectl -n envoy-gateway-system get deploy -l gateway.envoyproxy.io/owning-gateway-name=eg -o name | cut -d/ -f2) | grep -o 'id "[0-9]*"' | sort | uniq -c
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

- The wasm image pins CRS: coraza-proxy-wasm 0.6.0 ships Coraza v3.3.3 + CRS v4.14.0. Upgrading the WAF or the rules = bumping the image tag.
- `failOpen: false` (the default) means a broken/unfetchable wasm module fails closed (500s) rather than silently disabling the WAF.
- This filters north-south traffic at the gateway only. In-cluster (east-west) traffic and any Service exposed via LoadBalancer/NodePort outside the gateway are not covered.
