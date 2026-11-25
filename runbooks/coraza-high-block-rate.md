# Coraza high block rate

`CorazaHighBlockRate` (`apps/coraza/vm.yaml`) fires when the WAF has blocked over 25% of a gateway's transactions, and more than one per second, for 15 minutes. It has two causes, and this runbook tells them apart:

- **A scanner or bot** is probing the gateway. The WAF is working and nothing needs fixing.
- **A false positive**: a CRS bump or an app change made a rule match real traffic, and users are getting 403s.

Coraza is a wasm filter inside the Envoy proxy pods in `envoy-gateway-system`, so everything below reads the `envoy` container's logs. Those logs hold two kinds of line:

- **Access log** lines are JSON, one per request. A WAF block has `response_code` 403 and an empty `response_code_details`. A 403 from the app has `via_upstream` there instead.
- **Coraza rule log** lines are plain text and contain `wasm log coraza`. Each one names the client IP, the rule ID, the rule's message and the data that matched.

## 1. Collect the logs

Set `GW` to the alert's `gateway` label (`eg-public` or `eg-private`):

```shell
GW=eg-public
for p in $(kubectl -n envoy-gateway-system get pods -l gateway.envoyproxy.io/owning-gateway-name=$GW -o name); do
  kubectl -n envoy-gateway-system logs $p -c envoy --since=60m
done > all.log

# Access-log lines of the requests the WAF blocked
grep '^{' all.log | jq -c 'select(.response_code==403 and (.response_code_details//"")=="")' > blocked.json

# Coraza rule-log lines
grep 'wasm log coraza' all.log > coraza.log
```

## 2. See what the blocked traffic looks like

```shell
top() { sort | uniq -c | sort -rn | head -${1:-10}; }

# When it started and how fast it is
jq -r '.start_time[11:16]' blocked.json | sort | uniq -c

# Who: client IPs, and how many distinct ones
jq -r '."x-forwarded-for"' blocked.json | top
jq -r '."x-forwarded-for"' blocked.json | sort -u | wc -l

# What: hostnames, routes, paths and user agents
jq -r '.[":authority"]' blocked.json | top
jq -r '.route_name' blocked.json | top
jq -r '.method + " " + ((."x-envoy-origin-path"//"") | split("?")[0])' blocked.json | top 20
jq -r '."user-agent"' blocked.json | top

# Why: the rules that fired
grep -oE '\[id "[0-9]+"\] .*\[msg "[^"]*"\]' coraza.log | sed -E 's/\[id "([0-9]+)"\].*\[msg "([^"]*)"\]/\1 \2/' | top 20
```

CRS blocks by anomaly score. The rule that returns the 403 is `949111` ("Inbound Anomaly Score Exceeded"), and the rules listed beside it are the ones that added up to that score. The rule log has no request ID, so match its lines to access-log lines by client IP and time.

The same per-rule split, without the logs, is the "Blocks by rule_id" panel of the Coraza WAF dashboard in Grafana, or this query:

```promql
sum by (rule_id) (increase(waf_filter_tx_interruptions[1h]))
```

## 3. Decide which cause it is

| | Scanner or bot | False positive |
| --- | --- | --- |
| Client IPs | One, or a few | Many, and they look like your users |
| Hostname | The load balancer's IP address, or a name you don't serve | A hostname you serve |
| Route | The HTTP-to-HTTPS redirect or another catch-all | An app's HTTPRoute |
| Paths | Hundreds of different ones: `/.env`, `/wp-config.php.bak`, `/.git/config` | One endpoint, or a few |
| Rules | A mix: `920350` (numeric IP Host header), `920440`, `930130`, `933150`, `920500` | One rule ID dominates |

Also check what was not blocked. If the hostnames you serve still answer 200 at their usual rate, users are not affected:

```shell
grep '^{' all.log | jq -r 'select((.route_name//"") | test("healthz") | not) | [.[":authority"], .response_code] | @tsv' | top 20
```

## 4. Act

**Scanner or bot.** There is nothing to fix: the 403s are the WAF doing its job, and the alert resolves when the scan stops. Silence the alert for the scan's duration if it keeps paging. To stop the requests reaching Envoy at all, block the client IP in front of the gateway, for example in the load balancer's security group or network ACL.

**False positive.** Follow "Tuning false positives" in `apps/coraza/README.md`: add an exclusion to `apps/coraza/envoyextensionpolicy.yaml`, scoped to the path and field that tripped the rule. That file's comments and the README's notes describe every existing exclusion and how each was scoped. If users are blocked right now and the exclusion will take time, switch `SecRuleEngine On` to `SecRuleEngine DetectionOnly` first. That stops all blocking, so switch it back when the exclusion is in.
