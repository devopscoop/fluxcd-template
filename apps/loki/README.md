# Loki

Grafana Loki as a log store, deployed in **SingleBinary** mode backed by
**S3-compatible object storage**. Logs are queried through the existing Grafana
in `kube-prometheus-stack` (a Loki datasource is provisioned there via
`grafana.additionalDataSources`).

Loki only *stores* logs — `apps/alloy` ships pod logs into it.

## Before deploying

Authentication to S3 is via **IRSA** (IAM Roles for Service Accounts) — no
static access keys, so there's nothing to encrypt here.

1. Create two S3 buckets: one for chunks and one for the ruler.
2. Create an IAM role with read/write to those buckets and a trust policy for
   this cluster's OIDC provider, scoped to the `loki` ServiceAccount in the
   `loki` namespace.
3. Fill in the `CHANGEME-*` placeholders in `values.yaml`:
   - `loki.storage.bucketNames` (chunks, ruler) and `loki.storage.s3.region`.
   - `serviceAccount.annotations` → `eks.amazonaws.com/role-arn` with the role
     ARN from step 2.

To use static access keys instead of IRSA (e.g. for a non-AWS S3 backend like
Rook-Ceph RGW or MinIO), see the commented-out alternatives in `values.yaml`
and `helm_secrets.yaml.decrypted`.

## Notes

- Retention is set to 31 days (`loki.limits_config.retention_period`) and
  enforced by the in-process compactor.
- The query/push endpoint is `http://loki-gateway.loki.svc.cluster.local`.
- To scale beyond ~tens of GB/day, switch `deploymentMode` to `SimpleScalable`
  and give `read`/`write`/`backend` non-zero replica counts.
