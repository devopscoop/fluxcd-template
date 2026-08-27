# Coraza WAF

[OWASP Coraza](https://coraza.io/) (Apache-2.0) running the [OWASP Core Rule Set](https://coreruleset.org/) v4, deployed as a [proxy-wasm filter](https://github.com/corazawaf/coraza-proxy-wasm) inside the Envoy data plane via Envoy Gateway `EnvoyExtensionPolicy` resources. It inspects every request flowing through the attached Gateways for common web attacks (SQL injection, XSS, RCE, protocol abuse, scanners, ...).

Why this one:

- It runs **inside the existing Envoy data plane** — no sidecars, no second ingress stack, no extra network hop, nothing new to scale or make highly available.
- Coraza is the actively-maintained OWASP successor to ModSecurity (which is in maintenance mode), speaks the same SecLang rule language, and embeds the industry-standard CRS in the wasm image.
- Everything is free and open source: Apache-2.0 engine, Apache-2.0 CRS.

## Coverage

A single `coraza` `EnvoyExtensionPolicy` (`envoyextensionpolicy.yaml`) attaches to **both** Gateways — `eg-public` and `eg-private` — via a two-entry `targetRefs`, with identical config on each: `SecRuleEngine On` (matches get a **403**) and `failOpen: false` (fail closed — a wasm-filter failure returns 5xx rather than serving unfiltered traffic).

`eg-private` fronts internal, VPN-only ops services (grafana, prometheus, ...) — the most false-positive-prone surface (dashboard JSON, query strings). Since it now fails closed like `eg-public`, a wasm-filter failure will 5xx those ops UIs too, so watch the logs after enabling and add per-rule/per-host exclusions as needed. To instead keep the ops UIs up on a WAF failure, split `eg-private` into its own policy with `failOpen: true`.

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
- **Request** body inspection is broken in coraza-proxy-wasm 0.6.0 for bodies larger than one Envoy read chunk (~16KiB): the filter buffers the body for inspection but forwards it truncated, so the backend sees the body cut off mid-stream and returns its own 4xx (ENG-1613 — Grafana answered 400 "unexpected EOF" on every dashboard query, which the UI renders as empty panels). Bodies over `SecRequestBodyLimit` (131072, from `@recommended-conf`) get a clean 413 instead — and over HTTP/2 the 413 already fires from ~64KiB, the stream flow-control window. Both Gateways carry a `ClientTrafficPolicy` with `connection.bufferLimit: 256Ki` (`apps/eg-custom-resources/clienttrafficpolicy-{public,private}.yaml`), a prerequisite for buffering bodies up to the CRS limit that turned some silent truncations into clean 413s — but it does NOT stop the ~16KiB truncation; that's the wasm plugin, not the buffer. Until an upstream release fixes multi-chunk body handling, any host that must accept >16KiB request bodies needs a `per_authority_directives` entry pointing at the `no-request-body` directive set (grafana.devops.coop has one; POSTs over ~16KiB to any host without one are still exposed to truncation). When bumping the wasm image, re-test with three POSTs through a gateway host — ~15KiB (expect 200), ~32KiB (200 once fixed; 400 while broken), ~200KiB (413) — before removing the exemptions.
- CRS rule `920350` ("Host header is a numeric IP address") is dropped for the `/healthz` path via a `ctl:ruleRemoveById` exclusion. Load balancers health-check the Envoy fleets by IP, so every probe carries a numeric-IP Host header and would otherwise log a 920350 warning on each check — high volume, no signal. The exclusion is scoped to `/healthz`, so the rule still fires on real traffic. It is placed before the `@owasp_crs` include because 920350 is a phase-1 rule and `ctl:ruleRemoveById` only affects rules evaluated later in the same phase.
- The `attack-sqli`, `attack-xss` and `attack-rce` rule families are removed for the `ARGS_POST:json.query` field on `/api/graphql` paths via `ctl:ruleRemoveTargetByTag` exclusions (ENG-1613). GraphQL query text reads as code to the CRS regexes for SQL, JavaScript and shell commands alike, and each match is critical (score 5 = the paranoia-level-1 anomaly threshold by itself): `942190` (SQLi) matched `user(` in GoAlert's user-detail-page queries; `941390` ("Javascript method detected") matched `alert(` in `AlertDetailsPageQuery`'s `alert(id: $id)` — the query behind every `/alerts/<n>` page view, so alert details were unviewable; `932235` (Unix command injection) matched a pretty-printed query line starting with the field name `service`. The latter two were measured at 475 blocked requests in one dev day. The WAF 403s with an empty body, which GoAlert's UI surfaces as "[Network] JSON.parse: unexpected end of data". The families go rather than an ID list because field names that read as JS calls or coreutils are GraphQL's ordinary vocabulary and the query text is parsed by GoAlert's GraphQL engine and nothing else — `932260` below already demonstrated the whack-a-mole. Only the query-text field is excluded: `json.variables.*` (where user-typed input actually lands), all other rule families, and all other routes are still inspected. GoAlert is the only app serving `/api/graphql` through the gateways today. To re-test after a GoAlert or CRS bump, POST the alert-details query unauthenticated: `403` is the WAF, `401` means it reached GoAlert.
- The same rule `10005` also drops `932260` ("Direct Unix Command Execution") on `/api/graphql`, for a second variant of the same symptom (ENG-1613). GoAlert names every destination type `builtin-*` — `builtin-twilio-sms`, `builtin-smtp-email`, `builtin-slack-dm`, `builtin-webhook`, and seven more — and `builtin` is a Unix shell builtin, so `932260` matches the enum value itself. It is critical (score 5 = the PL1 anomaly threshold alone), so it 403'd, with an empty body, every mutation that names a destination: adding or editing a contact method, notification rule, escalation-policy step, or schedule on-call notification. All eleven values were confirmed blocked in dev. The by-ID removal must stay even though `attack-rce` is now also gone from `ARGS_POST:json.query` (see above): these values arrive in `json.variables`, which keeps the full rule set. Excluded by rule ID rather than by target because the value arrives under many field paths that move between GoAlert releases (`json.variables.input.destType`, `…input.dest.type`, `…input.actions.0.dest.type`; the v0.34 schema has both a `dest: DestinationInput` and a legacy `destType:` shape spread across ~15 mutations), so a target-scoped exclusion would silently regress on the next bump. Re-check after a GoAlert or CRS upgrade with a POST per destination type — the WAF answers before authentication, so an unauthenticated `curl` distinguishes them cleanly: `403` is the WAF, `401` means the request reached GoAlert.
- Six CRS rules are dropped on Grafana's query routes by rule `10006` (ENG-1711): `942100` (SQLi), `933120` (PHP configuration directive), and `932125`, `932235`, `932260`, `932370` (command injection). Panel content is PromQL and LogsQL, which the datasource never interprets as SQL, PHP or a shell command, but CRS reads ordinary parts of both as attacks: metric names embed directive names like `engine` and `memory_limit`, PromQL device selectors put a pipe before `md`, and LogsQL pipes are named after coreutils, so `| sort` and `| uniq` read as piped commands. Each rule is critical, so any one alone meets the PL1 anomaly threshold and 403s the panel. Scoped by `REQUEST_URI` to `/api/ds/query`, `/api/datasources/proxy/*/api/v1/query[_range]` and `/api/datasources/proxy/*/select/logsql/*`, matching on path and not `Host`. Every other route, field and rule family still applies. Re-measure after a CRS or dashboard-chart bump, since both can introduce another rule. Two known gaps, both deliberate: `label_set(..., "tier","select")` in the VictoriaMetrics *cluster* dashboard still 403s on `942190`, which is not excluded because it is the deciding rule for `sp_executesql` payloads and that dashboard is unused on single-node deployments. And a Grafana SQL-datasource query on `/api/ds/query` loses these rules too, which is intended, since that content is operator-authored SQL.
- The `attack-sqli` rule family is removed for the `query`, `extra_filters` and `extra_stream_filters` params on `/select/logsql/` paths by rule `10007`. The VictoriaLogs vmui (vlogs.devops.coop, apps/victoria-logs) sends LogsQL in those params, and LogsQL reads as SQL to the CRS regexes: grouping logs by a stream field sends `extra_stream_filters={... not_in ("")}`, whose `not_in (` matched `942151` "SQL function name detected" (critical, score 5 = the PL1 anomaly threshold by itself), so the WAF 403'd it and vmui showed "failed to load stream fields". Only those three params lose the SQLi family; every other param, route and rule family still applies.
- Rule `10007` also removes `attack-rce` for the same three params — the follow-on this bullet used to predict. LogsQL pipes are named after coreutils, so `| sort`, `| uniq`, `| head`, `| join` and `| replace` each read as a piped shell command and 403'd the query with an empty body (vmui shows nothing at all). Those five pipes were measured in dev against the live gateway and tripped **three different** RCE rules — `932235` five times, plus `932260` and `932370` — which is why the family goes rather than a list of IDs: every newly-used coreutils-named pipe would otherwise need its own exclusion. The scope is unchanged (`query`, `extra_filters`, `extra_stream_filters` on `/select/logsql/`), and those params carry only LogsQL, which VictoriaLogs never hands to a shell, so the RCE rules have nothing to protect there. The same pipes reach Grafana's VictoriaLogs panels by a different route (`/api/datasources/proxy/*/select/logsql/*`), which is rule `10006`'s scope; it already drops all three of those IDs, so dashboard panels are covered today — but because `10006` is an ID list rather than a family, a *different* RCE rule from some future pipe would still 403 there while `10007` absorbs it. Consider converting `10006` to the family form if that happens. To re-test after a CRS bump, `curl` the gateway with `query=* | sort by (_time)` — `403` is the WAF, `200` means it reached VictoriaLogs.
- The wasm image pins CRS: coraza-proxy-wasm 0.6.0 ships Coraza v3.3.3 + CRS v4.14.0. Upgrading the WAF or the rules = bumping the image tag.
- `failOpen: false` (the default): a broken/unfetchable wasm module fails closed (5xx) rather than serve unfiltered traffic. This applies on both Gateways, including the internal (VPN-only) `eg-private` ops UIs — so a WAF failure takes those down too. To troubleshoot (or just reach a service) while the WAF is failing closed, bypass the gateway with `kubectl port-forward` straight to the Service — e.g. `kubectl -n <ns> port-forward svc/<grafana> 3000:80`, then open <http://localhost:3000>. That path never touches Envoy or the WAF, so fail-closed can't lock you out during an incident. If you'd rather `eg-private` stay up on a wasm failure automatically, give it its own policy with `failOpen: true`.
- This filters north-south traffic at the gateway only. In-cluster (east-west) traffic and any Service exposed via LoadBalancer/NodePort outside the gateway are not covered.
